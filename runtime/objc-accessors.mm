/*
 * Copyright (c) 2006-2008 Apple Inc.  All Rights Reserved.
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

#include <string.h>
#include <stddef.h>

#include <libkern/OSAtomic.h>

#include "objc-private.h"
#include "runtime.h"

// stub interface declarations to make compiler happy.

@interface __NSCopyable
- (id)copyWithZone:(void *)zone;
@end

@interface __NSMutableCopyable
- (id)mutableCopyWithZone:(void *)zone;
@end

StripedMap<spinlock_t> PropertyLocks;
StripedMap<spinlock_t> StructLocks;
StripedMap<spinlock_t> CppObjectLocks;

#define MUTABLE_COPY 2

id objc_getProperty(id self, SEL _cmd, ptrdiff_t offset, BOOL atomic) {
    if (offset == 0) {
        return object_getClass(self);
    }

    /**
     调用objc_getProperty(...)获取对象的属性值，实际上只是按一定的方式访问了属性对应的成员变量空间。
     若属性为atomic则会在获取属性值的代码两头添加spinlock_t的加锁解锁代码，这也是atomic和nonatomic的区别所在。
     
     
     注意：spinlock_t的本质是os_lock_handoff_s锁，关于这个锁网上找不到什么资料，推测是个互斥锁。注意spinlock_t并不是OSSpinLock。OSSpinLock已知存在性能问题，已经被弃用。
     
     
     获取属性值对copy类型没有做相关处理，也就是说----copy属性的getter返回的也是属性指向对象本身，copy属性的getter并不包含拷贝操作。
     */
    
    // Retain release world
    id *slot = (id*) ((char*)self + offset);
    if (!atomic) return *slot;
        
    // Atomic retain release world
    spinlock_t& slotlock = PropertyLocks[slot];
    slotlock.lock();
    id value = objc_retain(*slot); // 引用计数+1
    slotlock.unlock();
    
    // for performance, we (safely) issue the autorelease OUTSIDE of the spinlock.
    return objc_autoreleaseReturnValue(value); // 添加到自动释放池
}


static inline void reallySetProperty(id self, SEL _cmd, id newValue, ptrdiff_t offset, bool atomic, bool copy, bool mutableCopy) __attribute__((always_inline));

static inline void reallySetProperty(id self, SEL _cmd, id newValue, ptrdiff_t offset, bool atomic, bool copy, bool mutableCopy)
{
    if (offset == 0) {
        object_setClass(self, newValue);
        return;
    }

    id oldValue;
    id *slot = (id*) ((char*)self + offset); /// 获取旧值地址

    if (copy) {
        newValue = [newValue copyWithZone:nil];  /// 对新值执行copy
    } else if (mutableCopy) {
        newValue = [newValue mutableCopyWithZone:nil]; /// 对新值执行mutableCopy
    } else {
        if (*slot == newValue) return;  /// 如果新值和旧值一样返回
        newValue = objc_retain(newValue); /// retain新值
    }

    if (!atomic) { /// noatomic 不需要加锁
        oldValue = *slot;
        *slot = newValue;
    } else { /// atomic 加锁处理
        spinlock_t& slotlock = PropertyLocks[slot];
        slotlock.lock();
        oldValue = *slot;  // 保存旧值 一会释放
        *slot = newValue;  // 将该地址内容设置为新值
        slotlock.unlock();
    }

    objc_release(oldValue); // release 旧值
    
    /// 注意：存取属性值的实现是直接调用属性的getter、setter的对应的方法的SEL触发的，属性与方法的关联细节则没有公布源代码。

}

/**
 调用objc_setProperty(...)设置对象的属性值，同样是是按一定的方式访问属性对应的成员变量空间。
 同样，若属性为atomic则会在设置属性值的代码两头添加spinlock_t的加锁解锁代码。
 若属性为copy时，则将传入 setter 的参数指向的对象 拷贝到对应的成员变量空间。

 作者：Luminix
 链接：https://juejin.im/post/5da491d95188252f051e24e1
 来源：掘金
 
 */
void objc_setProperty(id self, SEL _cmd, ptrdiff_t offset, id newValue, BOOL atomic, signed char shouldCopy) 
{
    bool copy = (shouldCopy && shouldCopy != MUTABLE_COPY);
    bool mutableCopy = (shouldCopy == MUTABLE_COPY);
    reallySetProperty(self, _cmd, newValue, offset, atomic, copy, mutableCopy);
}

void objc_setProperty_atomic(id self, SEL _cmd, id newValue, ptrdiff_t offset)
{
    reallySetProperty(self, _cmd, newValue, offset, true, false, false);
}

void objc_setProperty_nonatomic(id self, SEL _cmd, id newValue, ptrdiff_t offset)
{
    reallySetProperty(self, _cmd, newValue, offset, false, false, false);
}


void objc_setProperty_atomic_copy(id self, SEL _cmd, id newValue, ptrdiff_t offset)
{
    reallySetProperty(self, _cmd, newValue, offset, true, true, false);
}

void objc_setProperty_nonatomic_copy(id self, SEL _cmd, id newValue, ptrdiff_t offset)
{
    reallySetProperty(self, _cmd, newValue, offset, false, true, false);
}


// This entry point was designed wrong.  When used as a getter, src needs to be locked so that
// if simultaneously used for a setter then there would be contention on src.
// So we need two locks - one of which will be contended.
void objc_copyStruct(void *dest, const void *src, ptrdiff_t size, BOOL atomic, BOOL hasStrong __unused) {
    spinlock_t *srcLock = nil;
    spinlock_t *dstLock = nil;
    if (atomic) {
        srcLock = &StructLocks[src];
        dstLock = &StructLocks[dest];
        spinlock_t::lockTwo(srcLock, dstLock);
    }

    memmove(dest, src, size);

    if (atomic) {
        spinlock_t::unlockTwo(srcLock, dstLock);
    }
}

void objc_copyCppObjectAtomic(void *dest, const void *src, void (*copyHelper) (void *dest, const void *source)) {
    spinlock_t *srcLock = &CppObjectLocks[src];
    spinlock_t *dstLock = &CppObjectLocks[dest];
    spinlock_t::lockTwo(srcLock, dstLock);

    // let C++ code perform the actual copy.
    copyHelper(dest, src);
    
    spinlock_t::unlockTwo(srcLock, dstLock);
}
