/*
 * Copyright (c) 2010-2011 Apple Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */

#ifndef _OBJC_WEAK_H_
#define _OBJC_WEAK_H_

#include <objc/objc.h>
#include "objc-config.h"

__BEGIN_DECLS

/*
The weak table is a hash table governed by a single spin lock.
An allocated blob of memory, most often an object, but under GC any such 
allocation, may have its address stored in a __weak marked storage location 
through use of compiler generated write-barriers or hand coded uses of the 
register weak primitive. Associated with the registration can be a callback 
block for the case when one of the allocated chunks of memory is reclaimed. 
The table is hashed on the address of the allocated memory.  When __weak 
marked memory changes its reference, we count on the fact that we can still 
see its previous reference.

So, in the hash table, indexed by the weakly referenced item, is a list of 
all locations where this address is currently being stored.
 
For ARC, we also keep track of whether an arbitrary object is being 
deallocated by briefly placing it in the table just prior to invoking 
dealloc, and removing it via objc_clear_deallocating just prior to memory 
reclamation.

*/

// The address of a __weak variable.
// These pointers are stored disguised so memory analysis tools
// don't see lots of interior pointers from the weak table into objects.
// __weak变量的地址。
//这些指针是伪装的，因此内存分析工具
//从弱表到对象看不到许多内部指针。
typedef DisguisedPtr<objc_object *> weak_referrer_t; /// 等价objc_object ** weak_referrer_t  记录__weak 变量地址

#if __LP64__
#define PTR_MINUS_2 62
#else
#define PTR_MINUS_2 30
#endif

/**
 * The internal structure stored in the weak references table. 
 * It maintains and stores
 * a hash set of weak references pointing to an object.
 * If out_of_line_ness != REFERRERS_OUT_OF_LINE then the set
 * is instead a small inline array.
 * weak_entry_t是弱引用表中存储的内部结构。
 * 它维护和存储指向对象的弱引用的哈希集。
 * 如果out_of_line_ness！= REFERRERS_OUT_OF_LINE，则设置是一个小的内联数组。
 */
#define WEAK_INLINE_COUNT 4

// out_of_line_ness field overlaps（重叠） with the low two bits of inline_referrers[1].
// inline_referrers[1] is a DisguisedPtr of a pointer-aligned address.
// The low two bits of a pointer-aligned DisguisedPtr will always be 0b00
// (disguised nil or 0x80..00) or 0b11 (any other address).
// Therefore out_of_line_ness == 0b10 is used to mark the out-of-line state.

// out_of_line_ness字段与inline_referrers [1]的低两位重叠。
// inline_referrers [1]是指针对齐地址的DisguisedPtr。
// 指针对齐的DisguisedPtr的低两位始终为0b00 (0x 16进制  0b二进制)
//（伪装为nil或0x80..00）或0b11（任何其他地址）。
// 因此，out_of_line_ness == 0b10用于标记out-of-line状态

#define REFERRERS_OUT_OF_LINE 2
/// 数量是小于WEAK_INLINE_COUNT时,使用普通数组，大于时使用hash表（每个桶只有一个元素的hash表，比较简单）
struct weak_entry_t {
    // DisguisedPtr类的定义如下。它对一个指针伪装处理，保存时装箱，调用时拆箱。可不纠结于为什么要将指针伪装，只需要知道DisguisedPtr<T>功能上等价于T*即可。
    DisguisedPtr<objc_object> referent; /// referent：对象的引用，指向 被弱引用的对象；
    union {
        struct { /// 32字节
            /// weak_referrer_t  __weak变量地址。等价objc_object **weak_referrer_t *referrers 记录__weak变量地址的指针(数组地址，也是个hash表)
            weak_referrer_t *referrers; // 指针占8个字节
            // 位域：代表结构体中元素占用的位数
            uintptr_t        out_of_line_ness : 2;  // 占用8个字节中的最低2位
            uintptr_t        num_refs : PTR_MINUS_2; // 占用8个字节中剩下的62位。记录引用数量
            uintptr_t        mask;      // unsigned long 占8个字节 值为  referrers数组大小 - 1
            uintptr_t        max_hash_displacement; // 8个字节 记录hash最大冲突数
            // 初始化在append_referrer函数中查看
        };
        struct { /// 32字节
            // out_of_line_ness field is low bits of inline_referrers[1]
            // out_of_line_ness 这个字段的域是inline_referrers[1]低字节位
            weak_referrer_t  inline_referrers[WEAK_INLINE_COUNT]; /// inline_referrers[4] 记录__weak变量地址的数组
        };
    };

    bool out_of_line() {
        return (out_of_line_ness == REFERRERS_OUT_OF_LINE);
    }

    weak_entry_t& operator=(const weak_entry_t& other) {
        memcpy(this, &other, sizeof(other));
        return *this;
    }

    weak_entry_t(objc_object *newReferent, objc_object **newReferrer)
        : referent(newReferent)
    {
        inline_referrers[0] = newReferrer;
        for (int i = 1; i < WEAK_INLINE_COUNT; i++) {
            inline_referrers[i] = nil;
        }
    }
};

/**
 * The global weak references table. Stores object ids as keys,
 * and weak_entry_t structs as their values.
 */
struct weak_table_t {
    /// 每个被弱引用对象，必然有一个weak_entry_t与之对应，weak_entry_t保存了该对象的地址 以及所有 弱引用了该对象 的引用的地址
    
    weak_entry_t *weak_entries; /// weak_entries指向weak_entry_t结构体的数组，该数组保存哈希表的所有元素，一个元素对应 一个对象weak_entry_t地址；
    size_t    num_entries; /// num_entries是哈希表中保存的weak_entry_t元素的个数；
    uintptr_t mask; /// 记录哈希表的长度 mask + 1 == 哈希表的长度
    uintptr_t max_hash_displacement;
    /// 因为使用的线性探测来解决冲突。记录hash冲突的数量，这样在搜索时利用max_hash_displacement可以跳过比必要的搜索以提高搜索效率
    /// 具体请查看weak_entry_insert函数和
};

/// Adds an (object, weak pointer) pair to the weak table.
id weak_register_no_lock(weak_table_t *weak_table, id referent, 
                         id *referrer, bool crashIfDeallocating);

/// Removes an (object, weak pointer) pair from the weak table.
void weak_unregister_no_lock(weak_table_t *weak_table, id referent, id *referrer);

#if DEBUG
/// Returns true if an object is weakly referenced somewhere.
bool weak_is_registered_no_lock(weak_table_t *weak_table, id referent);
#endif

/// Called on object destruction. Sets all remaining weak pointers to nil.
void weak_clear_no_lock(weak_table_t *weak_table, id referent);

__END_DECLS

#endif /* _OBJC_WEAK_H_ */
