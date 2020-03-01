/*
 * Copyright (c) 2010-2012 Apple Inc. All rights reserved.
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

#include "objc-private.h"
#include "NSObject.h"

#include "objc-weak.h"
#include "llvm-DenseMap.h"
#include "NSObject.h"

#include <malloc/malloc.h>
#include <stdint.h>
#include <stdbool.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <libkern/OSAtomic.h>
#include <Block.h>
#include <map>
#include <execinfo.h>

@interface NSInvocation
- (SEL)selector;
@end


/***********************************************************************
* Weak ivar support
**********************************************************************/

static id defaultBadAllocHandler(Class cls)
{
    _objc_fatal("attempt to allocate object of class '%s' failed", 
                cls->nameForLogging());
}

static id(*badAllocHandler)(Class) = &defaultBadAllocHandler;

static id callBadAllocHandler(Class cls)
{
    // fixme add re-entrancy protection in case allocation fails inside handler
    return (*badAllocHandler)(cls);
}

void _objc_setBadAllocHandler(id(*newHandler)(Class))
{
    badAllocHandler = newHandler;
}


namespace {

// The order of these bits is important.
#define SIDE_TABLE_WEAKLY_REFERENCED (1UL<<0)
#define SIDE_TABLE_DEALLOCATING      (1UL<<1)  // MSB-ward of weak bit
#define SIDE_TABLE_RC_ONE            (1UL<<2)  // MSB-ward of deallocating bit
#define SIDE_TABLE_RC_PINNED         (1UL<<(WORD_BITS-1))
// SIDE_TABLE_RC_PINNED是将 SideTable 中的对象的引用计数的64位数据的最高位作为对象引用计数上溢出的标记，是MSB，引用计数上溢出时，对象的retain、release操作不会改变引用计数位域的值。


#define SIDE_TABLE_RC_SHIFT 2
#define SIDE_TABLE_FLAG_MASK (SIDE_TABLE_RC_ONE-1)

// RefcountMap disguises its pointers because we 
// don't want the table to act as a root for `leaks`.
///DenseMap存储了对象指针与引用计数的键值对，运行时一共维护8或64个SideTable，对应一共有8或64个DenseMap。
///SideTable通过一个自旋锁控制对DenseMap集合的访问。所以对象如何在这8或64个SideTable之间（DenseMap之间）分布存储是提高系统并发效率的关键
typedef objc::DenseMap<DisguisedPtr<objc_object>,size_t,true> RefcountMap;




// Template parameters.
enum HaveOld { DontHaveOld = false, DoHaveOld = true };
enum HaveNew { DontHaveNew = false, DoHaveNew = true };

/// 根据SideTables的结构我们知道全局共有8或64张SideTable。一张SideTable会管理多个对象，而并非一个。
struct SideTable {
    spinlock_t slock; /// 自旋锁:实际类型为os_unfair_lock. 防止多线程访问SideTable冲突
    
    /**
       将RefcountMap简单的的理解为是一个map，key是DisguisedPtr<objc_object>，value是对象的引用计数。
       这也是objc::DenseMap<DisguisedPtr<objc_object>,size_t,true> RefcountMap的含义
       即模板类型分别对应：key,DisguisedPtr类型。value，size_t类型。是否清除为vlaue==0的数据，true
     
       value是size_t（64位系统中占用64位）来保存引用计数，
       其中1位用来存储固定标志位，在溢出的时候使用，一位表示正在释放中，一位表示是否有弱引用，其余位表示实际的引用计数
     
       value的每位代表的含义
       63                    62                 2          1                          0
       SIDE_TABLE_RC_PINNED  ....................        SIDE_TABLE_DEALLOCATING    SIDE_TABLE_WEAKLY_REFERENCED
     
     
       RefcountMap refcnts 是一个C++的对象，内部包含了一个迭代器
         
       其中以DisguisedPtr<objc_object> 对象指针为key，size_t 为value保存对象引用计数
         
       将key、value通过std::pair打包以后，放入迭代器中，所以取出值之后，.first代表key，.second代表value
     */
    RefcountMap refcnts; /// 存放引用计数的hash表
    
    weak_table_t weak_table; /// 存放弱引用的hash表

    SideTable() { /// 构造函数
        memset(&weak_table, 0, sizeof(weak_table)); /// 初始化weak_table
        /// C 库函数 void *memset(void *str, int c, size_t n) 复制字符 c（一个无符号字符）到参数 str 所指向的字符串的前 n 个字符。
    }

    ~SideTable() { /// 析构函数
        _objc_fatal("Do not delete SideTable.");
    }

    void lock() { slock.lock(); }
    void unlock() { slock.unlock(); }
    void forceReset() { slock.forceReset(); }

    // Address-ordered lock discipline for a pair of side tables.
    /// 两个关于锁操作的静态模板函数
    template<HaveOld, HaveNew>
    static void lockTwo(SideTable *lock1, SideTable *lock2);
    
    template<HaveOld, HaveNew>
    static void unlockTwo(SideTable *lock1, SideTable *lock2);
    
    
    /**
     1. spinlock_t 自旋锁在runtime源码中经常看到，当自旋锁被一个线程获得时，他不能被其他线程获得。和互斥锁不同的是，它不会从函数直接返回，让线程sleep，而是让其处于active状态。
     由于自旋不释放CPU，因而持有自选锁的线程应尽快释放锁,好的一面的看，这样减少了上下文的切换速度。也因此它的使用场景应该是那种占用时间较短抢占情况。

     我们注意到这里 slock 属性是放置每个SideTable下的，这种细粒度的锁到底有什么意义？
     我们知道，一般代码加锁是为了保障读写安全，结合实际，如果整个SideTables只用一个锁去做处理，也就意味着，一旦表中的一个SideTable在被其他线程操作，那么其他线程将无法对其他SideTable进行处理，可想而知这种实现方式的效率是比较低的。而如果我们转换思想，降低锁的粒度，让他分配到每个SideTable中时，即使表中有SideTable正在被读取或者写入，但是不会影响到表中其他的元素。同时也保证了线程读写安全。在一定程度上给数据读写提供提供了相当高的伸缩性，每个锁的在理想情况下共同分担竞争请求。
     这种处理方式也就是所谓拆分锁。
     */
};


template<>
void SideTable::lockTwo<DoHaveOld, DoHaveNew>
    (SideTable *lock1, SideTable *lock2)
{
    spinlock_t::lockTwo(&lock1->slock, &lock2->slock);
}

template<>
void SideTable::lockTwo<DoHaveOld, DontHaveNew>
    (SideTable *lock1, SideTable *)
{
    lock1->lock();
}

template<>
void SideTable::lockTwo<DontHaveOld, DoHaveNew>
    (SideTable *, SideTable *lock2)
{
    lock2->lock();
}

template<>
void SideTable::unlockTwo<DoHaveOld, DoHaveNew>
    (SideTable *lock1, SideTable *lock2)
{
    spinlock_t::unlockTwo(&lock1->slock, &lock2->slock);
}

template<>
void SideTable::unlockTwo<DoHaveOld, DontHaveNew>
    (SideTable *lock1, SideTable *)
{
    lock1->unlock();
}

template<>
void SideTable::unlockTwo<DontHaveOld, DoHaveNew>
    (SideTable *, SideTable *lock2)
{
    lock2->unlock();
}


// We cannot use a C++ static initializer to initialize SideTables because
// libc calls us before our C++ initializers run. We also don't want a global 
// pointer to this struct because of the extra indirection.
// Do it the hard way.
/**
    我们不能用C++静态初始化方法去初始化SideTables，
    因为C++初始化方法运行之前libc就会调用我们；我们同样不想用一个全局的指针去指向SideTables，
    因为需要额外的代价。但是没办法我们只能这样。
 
libc 比 C++ static initializer 先调用到 SideTables，所以不能用 C++ static initializer 去调用 SideTableInit ，所以才用 SideTableBuf 来初始化。
 */


/// SideTableBuf是一个外部不可见的静态内存区块，其类型为StripedMap<SideTable>。它是内存管理的基础，其它的功能与特性都是基于这个插槽而展开的
/// SideTableBuf是一个静态内存区域，new StripedMap<SideTable>在其上创建了对象，巧妙的避开了初始化顺序问题
alignas(StripedMap<SideTable>) static uint8_t
    SideTableBuf[sizeof(StripedMap<SideTable>)]; /// 静态内存区域
///

static void SideTableInit() {
    new (SideTableBuf) StripedMap<SideTable>(); /// new StripedMap<SideTable>在SideTableBuf上创建了对象
}

/**
    我们看到SideTables本质上StripedMap类型。其中包含的元素为SideTable类型
    这里的reinterpret_cast关键字，我们可以理解为强制类型转换，也就是将SideTableBuf转换为
    StripedMap类型，其中包含的元素为SideTale类型。
 
 
 !important:
 
 Side Tables() 结构是什么？

 在他的结构下面挂了很多 Side Table 数据结构，这些数据结构在不同的架构上面是有不同个数的，比如在非嵌入式系统当中，Side Table 这个表一共有 64 个，在这里解释一下，Side Tables() 实际上是一个哈希表，可以通过一个对象指针来具体找到它对应的引用计数表或者说弱引用表在哪一张具体的 Side Table 当中

 
 如说只有一张 SideTable ，那么在内存中分配的所有对象的引用计数或者说弱引用存储都放到一张大表当中，这个时候如果说要操作某一个对象的引用计数值进行修改，比如说加一减一的操作，由于所有的对象可能是在不同的线程当中去分配创建的，包括调用他们的 retain，release等方法也可能是在不同线程当中操作的，那么这个时候再对这张表进行操作的时候，需要进行加锁处理才能保证对数据的访问安全，在这个过程当中就存在了效率问题，如果现在已经有一个对象在操作这张表，那么下一个对象就要等前一个对象操作完后把锁释放之后它才能操作这张表
 
 
 系统为了解决效率问题引用了分离锁的技术方案
 
 可以把内存对象所对应的引用技术表可以分拆成多个部分，比如说把它分拆成8个，分拆成8个需要对这8个表分别加锁
 比如说某一个对象A在第一张表里面，另一个对象B在另一张表中，那么当A和B同时进行引用计数操作的时候可以并发操作，但是如果按照一张表的情况下他们就需要顺序操作
 
 
 怎样实现快速分流？

 快速分流指的是通过一个对象的指针如何快速的定位到它属于哪张 side Table 表？
 side Tables 的本质是一张哈希表，这张哈希表当中可能有64张具体的 side Table ，然后存储不同对象的引用计数表和弱引用表
 
 */



static StripedMap<SideTable>& SideTables() { /// 返回指向StripedMap<SideTable>的隐式指针
    
    return *reinterpret_cast<StripedMap<SideTable>*>(SideTableBuf); /// 将SideTableBuf转为StripedMap<SideTable>*
        
    /** C++知识点
        1.使用了 C++ 标准转换运算符 reinterpret_cast ，其表达方式为：reinterpret_cast <new_type> (expression)
        用来处理无关类型之间的转换。该关键字会产生一个新值，并保证与原参数（expression）拥有完全相同的比特位。
        reinterpret_cast 运算符并不会改变括号中运算对象的值，而是对该对象从位模式上进行重新解释 https://zhuanlan.zhihu.com/p/33040213
         
        2.引用就是个弱化的指针
         引用变量是一个别名，也就是说，它是某个已存在变量的另一个名字。一旦把引用初始化为某个变量，就可以使用该引用名称或变量名称来指向变量。
         https://www.runoob.com/cplusplus/cpp-references.html
         通过使用引用来替代指针，会使 C++ 程序更容易阅读和维护。C++ 函数可以返回一个引用，方式与返回一个指针类似。
         当函数返回一个引用时，则返回一个指向返回值的隐式指针
         https://www.runoob.com/cplusplus/returning-values-by-reference.html
    */
}

// anonymous namespace
};

void SideTableLockAll() {
    SideTables().lockAll();
}

void SideTableUnlockAll() {
    SideTables().unlockAll();
}

void SideTableForceResetAll() {
    SideTables().forceResetAll();
}

void SideTableDefineLockOrder() {
    SideTables().defineLockOrder();
}

void SideTableLocksPrecedeLock(const void *newlock) {
    SideTables().precedeLock(newlock);
}

void SideTableLocksSucceedLock(const void *oldlock) {
    SideTables().succeedLock(oldlock);
}

void SideTableLocksPrecedeLocks(StripedMap<spinlock_t>& newlocks) {
    int i = 0;
    const void *newlock;
    while ((newlock = newlocks.getLock(i++))) {
        SideTables().precedeLock(newlock);
    }
}

void SideTableLocksSucceedLocks(StripedMap<spinlock_t>& oldlocks) {
    int i = 0;
    const void *oldlock;
    while ((oldlock = oldlocks.getLock(i++))) {
        SideTables().succeedLock(oldlock);
    }
}

//
// The -fobjc-arc flag causes the compiler to issue calls to objc_{retain/release/autorelease/retain_block}
//

id objc_retainBlock(id x) {
    return (id)_Block_copy(x);
}

//
// The following SHOULD be called by the compiler directly, but the request hasn't been made yet :-)
//

BOOL objc_should_deallocate(id object) {
    return YES;
}

id
objc_retain_autorelease(id obj)
{
    return objc_autorelease(objc_retain(obj));
}

/// 与引用计数相关
void
objc_storeStrong(id *location, id obj)
{
    id prev = *location;
    if (obj == prev) {
        return;
    }
    objc_retain(obj); /// 引用计数+1
    *location = obj;
    objc_release(prev); /// 引用计数-1
}


// Update a weak variable.
// If HaveOld is true, the variable has an existing value 
//   that needs to be cleaned up. This value might be nil.
// If HaveNew is true, there is a new value that needs to be 
//   assigned into the variable. This value might be nil.
// If CrashIfDeallocating is true, the process is halted（停止） if newObj is
//   deallocating or newObj's class does not support weak references. 
//   If CrashIfDeallocating is false, nil is stored instead.

// HaveOld:     true - 变量有值
//             false - 需要被及时清理，当前值可能为 nil
// HaveNew:     true - 需要被分配的新值，当前值可能为 nil
//             false - 不需要分配新值
// CrashIfDeallocating: true - 说明 newObj 已经释放或者 newObj 不支持弱引用，该过程需要暂停
//             false - 用 nil 替代存储

enum CrashIfDeallocating {
    DontCrashIfDeallocating = false, DoCrashIfDeallocating = true
};


///C++的模板函数 语法解释：https://blog.csdn.net/qq_35637562/article/details/55194097

/**
 HaveOld：是否有旧值；
 HaveNew：是否指定新值；
 CrashIfDeallocating：若为true，传入的newObj不支持weak类型或野指针时程序将中断运行；若为false，传入的newObj不支持weak类型或野指针时置新值为nil；
 location：weak指针旧值地址（类型 objc_object **）；
 newObj：weak指针新值（类型 objc_object *）；
 */
template <HaveOld haveOld, HaveNew haveNew,
          CrashIfDeallocating crashIfDeallocating>
static id 
storeWeak(id *location, objc_object *newObj)
{
    // 该过程用来更新弱引用指针的指向
    
    assert(haveOld  ||  haveNew); // assert断言，assert(表达式)，表达式为真，什么也不做，表达式为假则crash。
    if (!haveNew) assert(newObj == nil);
    
    // 初始化 previouslyInitializedClass 指针
    Class previouslyInitializedClass = nil;
    
    // 声明两个 SideTable
    // ① 新旧散列创建
    id oldObj;
    SideTable *oldTable;
    SideTable *newTable;

    // Acquire locks for old and new values.
    // Order by lock address to prevent lock ordering problems. 
    // Retry if the old value changes underneath us.
    
    // 获得新值和旧值的锁存位置（用地址作为唯一标示）
    // 通过地址来建立索引标志，防止桶重复
    // 下面指向的操作会改变旧值
 retry:
    if (haveOld) {
        // 更改指针，获得以 oldObj 为索引所存储的值地址
        oldObj = *location;
        oldTable = &SideTables()[oldObj]; /// SideTables全局静态hash表: StripedMap<SideTable>类型
    } else {
        oldTable = nil;
    }
    if (haveNew) {
        // 更改新值指针，获得以 newObj 为索引所存储的值地址
        /// 怎么样获取的SideTable:
        newTable = &SideTables()[newObj];
    } else {
        newTable = nil;
    }
    
    // 加锁操作，防止多线程中竞争冲突
    SideTable::lockTwo<haveOld, haveNew>(oldTable, newTable);

    // 避免线程冲突重处理
    // location 应该与 oldObj 保持一致，如果不同，说明当前的 location 已经处理过 oldObj 可是又被其他线程所修改
    if (haveOld  &&  *location != oldObj) {
        SideTable::unlockTwo<haveOld, haveNew>(oldTable, newTable);
        goto retry;
    }

    // Prevent a deadlock between the weak reference machinery
    // and the +initialize machinery by ensuring that no 
    // weakly-referenced object has an un-+initialized isa.
    
    // 防止弱引用间死锁
    // 并且通过 +initialize 初始化构造器保证所有弱引用的 isa 非空指向
    if (haveNew  &&  newObj) {
        
        // 获得新对象的 isa 指针
        Class cls = newObj->getIsa();
        // 判断 isa 非空且已经初始化
        if (cls != previouslyInitializedClass  &&  
            !((objc_class *)cls)->isInitialized()) 
        {
            // 解锁
            SideTable::unlockTwo<haveOld, haveNew>(oldTable, newTable);
            
            // 对其 isa 指针进行初始化
            _class_initialize(_class_getNonMetaClass(cls, (id)newObj));

            // If this class is finished with +initialize then we're good.
            // If this class is still running +initialize on this thread 
            // (i.e. +initialize called storeWeak on an instance of itself)
            // then we may proceed but it will appear initializing and 
            // not yet initialized to the check above.
            // Instead set previouslyInitializedClass to recognize it on retry.
            
            // 如果该类已经完成执行 +initialize 方法是最理想情况
            // 如果该类 +initialize 在线程中
            // 例如 +initialize 正在调用 storeWeak 方法
            // 需要手动对其增加保护策略，并设置 previouslyInitializedClass 指针进行标记
            previouslyInitializedClass = cls;
            
            // 重新尝试
            goto retry;
        }
    }

    // Clean up old value, if any.
    // ② 清除旧值
    if (haveOld) {
        /// 阅读代码时先看 weak_register_no_lock部分在看weak_unregister_no_lock。
        /// weak_register_no_lock是从无到有的过程涉及的信息较多
        weak_unregister_no_lock(&oldTable->weak_table, oldObj, location);
    }

    // Assign new value, if any.
    // ③ 分配新值
    if (haveNew) {
        newObj = (objc_object *)
            weak_register_no_lock(&newTable->weak_table, (id)newObj, location, 
                                  crashIfDeallocating);
        // weak_register_no_lock returns nil if weak store should be rejected
        // 如果弱引用被释放 weak_register_no_lock 方法返回 nil

        // Set is-weakly-referenced bit in refcount table.
        if (newObj  &&  !newObj->isTaggedPointer()) {
            /// 完成弱引用注册后，新对象newObj需要调用setWeaklyReferenced_nolock(...)方法标记对象被弱引用
            /// 因为对象在析构时，若对象被弱引用，则需要将这些弱引用全部置nil
            newObj->setWeaklyReferenced_nolock();
        }

        // Do not set *location anywhere else. That would introduce a race.
        // 之前不要设置 location 对象，这里需要更改指针指向
        *location = (id)newObj;
    }
    else {
        // No new value. The storage is not changed.
        // 没有新值，则无需更改
    }
    
    SideTable::unlockTwo<haveOld, haveNew>(oldTable, newTable);

    return (id)newObj;
}


/** 
 * This function stores a new value into a __weak variable. It would
 * be used anywhere a __weak variable is the target of an assignment.
 * 
 * @param location The address of the weak pointer itself
 * @param newObj The new object this weak ptr should now point to
 * 
 * @return \e newObj
 */
id
objc_storeWeak(id *location, id newObj)
{
    return storeWeak<DoHaveOld, DoHaveNew, DoCrashIfDeallocating>
        (location, (objc_object *)newObj);
}


/** 
 * This function stores a new value into a __weak variable. 
 * If the new object is deallocating or the new object's class 
 * does not support weak references, stores nil instead.
 * 
 * @param location The address of the weak pointer itself
 * @param newObj The new object this weak ptr should now point to
 * 
 * @return The value stored (either the new object or nil)
 */
id
objc_storeWeakOrNil(id *location, id newObj)
{
    return storeWeak<DoHaveOld, DoHaveNew, DontCrashIfDeallocating>
        (location, (objc_object *)newObj);
}


/** 
 * Initialize a fresh weak pointer to some object location. 
 * It would be used for code like: 
 *
 * (The nil case) 
 * __weak id weakPtr;
 * (The non-nil case) 
 * NSObject *o = ...;
 * __weak id weakPtr = o;
 * 
 * This function IS NOT thread-safe with respect to concurrent 
 * modifications to the weak variable. (Concurrent weak clear is safe.)
 *
 * @param location Address of __weak ptr. 
 * @param newObj Object ptr. 
 */
id
objc_initWeak(id *location, id newObj)
{
    // 查看对象实例是否有效
    // 无效对象直接导致指针释放
    if (!newObj) {
        *location = nil;
        return nil;
    }
    
    // 这里传递了三个 bool 数值
    // 使用 template 进行常量参数传递是为了优化性能  C++的模板语法: 模板中可以携带参数,此处应该就是模板中携带参数
    return storeWeak<DontHaveOld, DoHaveNew, DoCrashIfDeallocating>
        (location, (objc_object*)newObj);
}

id
objc_initWeakOrNil(id *location, id newObj)
{
    if (!newObj) {
        *location = nil;
        return nil;
    }

    return storeWeak<DontHaveOld, DoHaveNew, DontCrashIfDeallocating>
        (location, (objc_object*)newObj);
}


/** 
 * Destroys the relationship between a weak pointer
 * and the object it is referencing in the internal weak
 * table. If the weak pointer is not referencing anything, 
 * there is no need to edit the weak table. 
 *
 * This function IS NOT thread-safe with respect to concurrent 
 * modifications to the weak variable. (Concurrent weak clear is safe.)
 * 
 * @param location The weak pointer address. 
 */
void
objc_destroyWeak(id *location)
{
    (void)storeWeak<DoHaveOld, DontHaveNew, DontCrashIfDeallocating>
        (location, nil);
}


/*
  Once upon a time we eagerly cleared *location if we saw the object 
  was deallocating. This confuses code like NSPointerFunctions which 
  tries to pre-flight the raw storage and assumes if the storage is 
  zero then the weak system is done interfering. That is false: the 
  weak system is still going to check and clear the storage later. 
  This can cause objc_weak_error complaints and crashes.
  So we now don't touch the storage until deallocation completes.
*/

id
objc_loadWeakRetained(id *location)
{
    id obj;
    id result;
    Class cls;

    SideTable *table;
    
 retry:
    // fixme std::atomic this load
    obj = *location;
    if (!obj) return nil;
    if (obj->isTaggedPointer()) return obj;
    
    table = &SideTables()[obj];
    
    table->lock();
    if (*location != obj) {
        table->unlock();
        goto retry;
    }
    
    result = obj;

    cls = obj->ISA();
    if (! cls->hasCustomRR()) {
        // Fast case. We know +initialize is complete because
        // default-RR can never be set before then.
        assert(cls->isInitialized());
        if (! obj->rootTryRetain()) {
            result = nil;
        }
    }
    else {
        // Slow case. We must check for +initialize and call it outside
        // the lock if necessary in order to avoid deadlocks.
        if (cls->isInitialized() || _thisThreadIsInitializingClass(cls)) {
            BOOL (*tryRetain)(id, SEL) = (BOOL(*)(id, SEL))
                class_getMethodImplementation(cls, SEL_retainWeakReference);
            if ((IMP)tryRetain == _objc_msgForward) {
                result = nil;
            }
            else if (! (*tryRetain)(obj, SEL_retainWeakReference)) {
                result = nil;
            }
        }
        else {
            table->unlock();
            _class_initialize(cls);
            goto retry;
        }
    }
        
    table->unlock();
    return result;
}

/** 
 * This loads the object referenced by a weak pointer and returns it, after
 * retaining and autoreleasing the object to ensure that it stays alive
 * long enough for the caller to use it. This function would be used
 * anywhere a __weak variable is used in an expression.
 * 
 * @param location The weak pointer address
 * 
 * @return The object pointed to by \e location, or \c nil if \e location is \c nil.
 */
id
objc_loadWeak(id *location)
{
    if (!*location) return nil;
    return objc_autorelease(objc_loadWeakRetained(location));
}


/** 
 * This function copies a weak pointer from one location to another,
 * when the destination doesn't already contain a weak pointer. It
 * would be used for code like:
 *
 *  __weak id src = ...;
 *  __weak id dst = src;
 * 
 * This function IS NOT thread-safe with respect to concurrent 
 * modifications to the destination variable. (Concurrent weak clear is safe.)
 *
 * @param dst The destination variable.
 * @param src The source variable.
 */
void
objc_copyWeak(id *dst, id *src)
{
    id obj = objc_loadWeakRetained(src);
    objc_initWeak(dst, obj);
    objc_release(obj);
}

/** 
 * Move a weak pointer from one location to another.
 * Before the move, the destination must be uninitialized.
 * After the move, the source is nil.
 *
 * This function IS NOT thread-safe with respect to concurrent 
 * modifications to either weak variable. (Concurrent weak clear is safe.)
 *
 */
void
objc_moveWeak(id *dst, id *src)
{
    objc_copyWeak(dst, src);
    objc_destroyWeak(src);
    *src = nil;
}


/***********************************************************************
   Autorelease pool implementation

   A thread's autorelease pool is a stack of pointers.
   线程的自动释放池是个指针栈
   Each pointer is either an object to release, or POOL_BOUNDARY which is 
     an autorelease pool boundary.
   每个指针要么指向要释放的对象，要么指向POOL_BOUNDARY（自动释放池的边界）
   A pool token is a pointer to the POOL_BOUNDARY for that pool. When 
     the pool is popped, every object hotter than the sentinel(哨兵) is released.
   一个池的token是指向该池子的POOL_BOUNDARY的指针。当池子出栈,每个比这个哨兵(token)hotter的对象会被释放
   The stack is divided into a doubly-linked list of pages. Pages are added 
     and deleted as necessary.
   该栈是由是pages组成双向链表结构.pages会被根据需要添加或删除
   Thread-local storage points to the hot page, where newly autoreleased 
     objects are stored.
   线程存储指向hotPage的指针，先创建的自动释放的对象存储在此。
**********************************************************************/

// Set this to 1 to mprotect() autorelease pool contents
#define PROTECT_AUTORELEASEPOOL 0

// Set this to 1 to validate the entire autorelease pool header all the time
// (i.e. use check() instead of fastcheck() everywhere)
#define CHECK_AUTORELEASEPOOL (DEBUG)

BREAKPOINT_FUNCTION(void objc_autoreleaseNoPool(id obj));
BREAKPOINT_FUNCTION(void objc_autoreleasePoolInvalid(const void *token));

namespace {

struct magic_t {
    static const uint32_t M0 = 0xA1A1A1A1;
#   define M1 "AUTORELEASE!"
    static const size_t M1_len = 12;
    uint32_t m[4]; /// 4 * 4 = 16个字节
    
    magic_t() {
        assert(M1_len == strlen(M1));
        assert(M1_len == 3 * sizeof(m[1]));

        m[0] = M0;
        strncpy((char *)&m[1], M1, M1_len);
    }

    ~magic_t() {
        m[0] = m[1] = m[2] = m[3] = 0;
    }

    bool check() const {
        return (m[0] == M0 && 0 == strncmp((char *)&m[1], M1, M1_len));
    }

    bool fastcheck() const {
#if CHECK_AUTORELEASEPOOL
        return check();
#else
        return (m[0] == M0);
#endif
    }

#   undef M1
};
    
/***
 
 此处指看了关于AutoreleasePoolPage的源码,AutoreleasePoolPage与RunLoop也有密切的关系,这部分内容需要看RunLoop的源码
 
 Autorelease pool 与 RunLoop 也有非常紧密的关系。App 启动后再主线程 RunLoop 会注册两个 Observer
 第一个 Observer 监听 Entry 事件，其回调会调用objc_autoreleasePoolPush()函数创建自动释放池；
 第二个Observer监听两个事件，监听到BeforeWaiting（即将进入休眠）时调用objc_autoreleasePoolPop()函数释放旧的 autorelease pool
 并调用objc_autoreleasePoolPush()函数建立新的 autorelease pool ；
 监听到 Exit 事件时，调用objc_autoreleasePoolPop(void *ctxt)函数释放 autorelease pool （顺便一提：调用pop传入的ctxt参数实际上是调用push新建 autorelease pool 时返回的POOL_BOUNDARY的地址）。
 
 注意:
 1.runloop自动创建自动释放池
 2.手动创建 @autoreleasepool{ \\添加需要自动释放的对象  }
 
 ***/


class AutoreleasePoolPage 
{
    // EMPTY_POOL_PLACEHOLDER is stored in TLS when exactly one pool is 
    // pushed and it has never contained any objects. This saves memory 
    // when the top level (i.e. libdispatch) pushes and pops pools but 
    // never uses them.
    /// 当仅推入一个池且从未包含任何对象时，EMPTY_POOL_PLACEHOLDER就会存储在TLS中。当顶层（即libdispatch）推送并弹出池但从不使用它们时，这样可以节省内存。
#   define EMPTY_POOL_PLACEHOLDER ((id*)1)

#   define POOL_BOUNDARY nil  /// 边界
    static pthread_key_t const key = AUTORELEASE_POOL_KEY;
    static uint8_t const SCRIBBLE = 0xA3;  // 0xA3A3A3A3 after releasing
    static size_t const SIZE = 
#if PROTECT_AUTORELEASEPOOL
        PAGE_MAX_SIZE;  // must be multiple of vm page size
#else
        PAGE_MAX_SIZE;  // size and alignment, power of 2
#endif
    static size_t const COUNT = SIZE / sizeof(id);

    magic_t const magic; ///16字节  校验
    id *next; ///8 指向AutoreleasePoolPage中下一个可分配的地址
    pthread_t const thread; /// 8
    AutoreleasePoolPage * const parent; /// 8 指向当前节点的上一个AutoreleasePoolPage节点，若parent为null则表示该节点为双向链表的开始节点
    AutoreleasePoolPage *child; /// 8 下一个AutoreleasePoolPage节点
    uint32_t const depth; /// 4 当前AutoreleasePoolPage节点在链表中的位置
    uint32_t hiwat; /// 4 校验

    // SIZE-sizeof(*this) bytes of contents follow
    
    /**
     AutoreleasePoolPage重载了new运算符，指定构建AutoreleasePoolPage实例分配定长的4096字节内存空间
     #define I386_PGBYTES            4096
     #define PAGE_SIZE               I386_PGBYTES
     #define PAGE_MAX_SIZE           PAGE_SIZE
     
     */
    
    /// 重载new运算符
    static void * operator new(size_t size) {
        return malloc_zone_memalign(malloc_default_zone(), SIZE, SIZE);
    }
    /// 重载delete运算符
    static void operator delete(void * p) {
        return free(p);
    }

    inline void protect() {
#if PROTECT_AUTORELEASEPOOL
        mprotect(this, SIZE, PROT_READ);
        check();
#endif
    }

    inline void unprotect() {
#if PROTECT_AUTORELEASEPOOL
        check();
        mprotect(this, SIZE, PROT_READ | PROT_WRITE);
#endif
    }
    /// C++ 构造函数初始化列表：构造函数初始化列表以一个冒号开始，接着是以逗号分隔的数据成员列表，每个数据成员后面跟一个放在括号中的初始化式
    AutoreleasePoolPage(AutoreleasePoolPage *newParent) 
        : magic(), next(begin()), thread(pthread_self()),
          parent(newParent), child(nil), 
          depth(parent ? 1+parent->depth : 0), 
          hiwat(parent ? parent->hiwat : 0)
    { 
        if (parent) {
            parent->check();
            assert(!parent->child);
            parent->unprotect();
            parent->child = this;
            parent->protect();
        }
        protect();
    }

    ~AutoreleasePoolPage() 
    {
        check();
        unprotect();
        assert(empty());

        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage
        assert(!child);
    }


    void busted(bool die = true) 
    {
        magic_t right;
        (die ? _objc_fatal : _objc_inform)
            ("autorelease pool page %p corrupted\n"
             "  magic     0x%08x 0x%08x 0x%08x 0x%08x\n"
             "  should be 0x%08x 0x%08x 0x%08x 0x%08x\n"
             "  pthread   %p\n"
             "  should be %p\n", 
             this, 
             magic.m[0], magic.m[1], magic.m[2], magic.m[3], 
             right.m[0], right.m[1], right.m[2], right.m[3], 
             this->thread, pthread_self());
    }

    void check(bool die = true) 
    {
        if (!magic.check() || !pthread_equal(thread, pthread_self())) {
            busted(die); /// busted破灭
        }
    }

    void fastcheck(bool die = true) 
    {
#if CHECK_AUTORELEASEPOOL
        check(die);
#else
        if (! magic.fastcheck()) {
            busted(die);
        }
#endif
    }


    id * begin() {
        /// 获取开始存放autorelrese对象的地址
        return (id *) ((uint8_t *)this+sizeof(*this));
    }

    id * end() {
        /// 一个的Page的结尾
        return (id *) ((uint8_t *)this+SIZE);
    }

    bool empty() {
        /// 没有存放autorelrese对象
        return next == begin();
    }

    bool full() {
        /// 该Page满了
        return next == end();
    }

    bool lessThanHalfFull() {
        /// 是否少于一半
        return (next - begin() < (end() - begin()) / 2);
    }

    id *add(id obj)
    {
        assert(!full());
        unprotect();
        id *ret = next;  // faster than `return next-1` because of aliasing
        *next++ = obj; /// next指向下一个存储位置
        protect();
        return ret;
    }

    void releaseAll() 
    {
        releaseUntil(begin());/// 释放到链表的头结点
    }

    void releaseUntil(id *stop) 
    {
        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage
        //不是递归的：我们不想炸毁堆栈
        //如果一个线程累积了大量的垃圾
        
        while (this->next != stop) {
            // Restart from hotPage() every time, in case -release 
            // autoreleased more objects
            AutoreleasePoolPage *page = hotPage();

            // fixme I think this `while` can be `if`, but I can't prove it
            while (page->empty()) {
                page = page->parent;
                setHotPage(page);
            }

            page->unprotect();
            
            /// 从Page的next指针上一个位置开始释放直到next指向stop
            id obj = *--page->next;
            memset((void*)page->next, SCRIBBLE, sizeof(*page->next));
            page->protect();

            if (obj != POOL_BOUNDARY) {
                objc_release(obj);
            }
        }

        setHotPage(this);

#if DEBUG
        // we expect any children to be completely empty
        for (AutoreleasePoolPage *page = child; page; page = page->child) {
            assert(page->empty());
        }
#endif
    }

    /// 把当前page的所有child链重置为nil
    void kill() 
    {
        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage
        AutoreleasePoolPage *page = this;
        while (page->child) page = page->child;

        AutoreleasePoolPage *deathptr;
        do {
            deathptr = page;
            page = page->parent;
            if (page) {
                page->unprotect();
                page->child = nil;
                page->protect();
            }
            delete deathptr;
        } while (deathptr != this);
    }

    static void tls_dealloc(void *p) 
    {
        if (p == (void*)EMPTY_POOL_PLACEHOLDER) {
            // No objects or pool pages to clean up here.
            return;
        }

        // reinstate TLS value while we work
        setHotPage((AutoreleasePoolPage *)p);

        if (AutoreleasePoolPage *page = coldPage()) {
            if (!page->empty()) pop(page->begin());  // pop all of the pools
            if (DebugMissingPools || DebugPoolAllocation) {
                // pop() killed the pages already
            } else {
                page->kill();  // free all of the pages
            }
        }
        
        // clear TLS value so TLS destruction doesn't loop
        setHotPage(nil);
    }

    static AutoreleasePoolPage *pageForPointer(const void *p) 
    {
        return pageForPointer((uintptr_t)p);
    }

    /// 根据地址查找AutoreleasePoolPage
    static AutoreleasePoolPage *pageForPointer(uintptr_t p) 
    {
        AutoreleasePoolPage *result;
        /// 获取偏移量,SIZE为4096个字节每个AutoreleasePoolPage的大小为4096
        uintptr_t offset = p % SIZE;

        assert(offset >= sizeof(AutoreleasePoolPage));
        
        /// 获取该AutoreleasePoolPage的地址（按照4096对齐,所以AutoreleasePoolPage地址一定是4096的倍数）
        result = (AutoreleasePoolPage *)(p - offset);
        result->fastcheck();

        return result;
    }


    static inline bool haveEmptyPoolPlaceholder()
    {
        id *tls = (id *)tls_get_direct(key);
        return (tls == EMPTY_POOL_PLACEHOLDER);
    }

    static inline id* setEmptyPoolPlaceholder()
    {
        assert(tls_get_direct(key) == nil);
        tls_set_direct(key, (void *)EMPTY_POOL_PLACEHOLDER);
        return EMPTY_POOL_PLACEHOLDER;
    }

    /// hotPage 保存 autorelease pool 当前所分配到的AutoreleasePoolPage；
    
    static inline AutoreleasePoolPage *hotPage() 
    {
        /**
         tls_get_direct()、tls_set_direct()函数分别通过pthread_getspecific()、pthread_setspecific()函数，使用Key-Value方式访问线程的私有空间。
         显然 hotPage 是与线程关联的，在不同的线程上调用AutoreleasePoolPage类的hotPage()静态方法返回的是不同的AutoreleasePoolPage实例。
         代码中的key是AutoreleasePoolPage的一个const静态变量。
         
         英文为Thread Local Storage [1]  ，缩写为TLS。为什么要有TLS？原因在于，全局变量与函数内定义的静态变量，是各个线程都可以访问的共享变量。
         如果需要在一个线程内部的各个函数调用都能访问、但其它线程不能访问的变量（被称为static memory local to a thread 线程局部静态变量），就需要新的机制来实现。这就是TLS。
         */
        AutoreleasePoolPage *result = (AutoreleasePoolPage *)
            tls_get_direct(key);
        if ((id *)result == EMPTY_POOL_PLACEHOLDER) return nil;
        if (result) result->fastcheck();
        return result;
    }

    static inline void setHotPage(AutoreleasePoolPage *page) 
    {
        if (page) page->fastcheck();
        tls_set_direct(key, (void *)page);
    }

    /// coldPage 是从 hotPage 开始沿parent指针链回溯找到的第一个分配的AutoreleasePoolPage。
    static inline AutoreleasePoolPage *coldPage() /// 链表的首page
    {
        AutoreleasePoolPage *result = hotPage();
        if (result) {
            while (result->parent) {
                result = result->parent;
                result->fastcheck();
            }
        }
        return result;
    }


    /// 添加对象到自动释放池
    static inline id *autoreleaseFast(id obj)
    {
        AutoreleasePoolPage *page = hotPage(); /// 获取当前page
        if (page && !page->full()) { /// 没满就直接添加
            return page->add(obj);
        } else if (page) { /// Page满了
            return autoreleaseFullPage(obj, page);
        } else { /// 没有Page
            return autoreleaseNoPage(obj);
        }
    }

    static __attribute__((noinline))
    id *autoreleaseFullPage(id obj, AutoreleasePoolPage *page)
    {
        // The hot page is full. 
        // Step to the next non-full page, adding a new page if necessary.
        // Then add the object to that page.
        assert(page == hotPage());
        assert(page->full()  ||  DebugPoolAllocation);
        /// 获取下一个page,如果都满了就创建新page
        do {
            if (page->child) page = page->child;
            else page = new AutoreleasePoolPage(page);
        } while (page->full());

        setHotPage(page); /// 设置为hotPage
        return page->add(obj);
    }

    static __attribute__((noinline))
    id *autoreleaseNoPage(id obj)
    {
        // "No page" could mean no pool has been pushed
        // or an empty placeholder pool has been pushed and has no contents yet
        assert(!hotPage());

        bool pushExtraBoundary = false;
        if (haveEmptyPoolPlaceholder()) {
            // We are pushing a second pool over the empty placeholder pool
            // or pushing the first object into the empty placeholder pool.
            // Before doing that, push a pool boundary on behalf of the pool 
            // that is currently represented by the empty placeholder.
            pushExtraBoundary = true;
        }
        else if (obj != POOL_BOUNDARY  &&  DebugMissingPools) { /// 注意: POOL_BOUNDARY值是nil
            // We are pushing an object with no pool in place, 
            // and no-pool debugging was requested by environment.
            _objc_inform("MISSING POOLS: (%p) Object %p of class %s "
                         "autoreleased with no pool in place - "
                         "just leaking - break on "
                         "objc_autoreleaseNoPool() to debug", 
                         pthread_self(), (void*)obj, object_getClassName(obj));
            
            objc_autoreleaseNoPool(obj);
            return nil;
        }
        else if (obj == POOL_BOUNDARY  &&  !DebugPoolAllocation) {
            // We are pushing a pool with no pool in place,
            // and alloc-per-pool debugging was not requested.
            // Install and return the empty pool placeholder.
            return setEmptyPoolPlaceholder();
        }

        // We are pushing an object or a non-placeholder'd pool.

        // Install the first page.
        
        /// 创建链表中的第一个Page,并设置为hotpage
        AutoreleasePoolPage *page = new AutoreleasePoolPage(nil);
        setHotPage(page);
        
        // Push a boundary on behalf of the previously-placeholder'd pool.
        if (pushExtraBoundary) {
            page->add(POOL_BOUNDARY); /// 添加哨兵对象POOL_BOUNDARY（nil）
        }
        
        // Push the requested object or pool.
        return page->add(obj); /// 添加需要自动释放的对象
    }


    static __attribute__((noinline))
    id *autoreleaseNewPage(id obj)
    {
        AutoreleasePoolPage *page = hotPage();
        if (page) return autoreleaseFullPage(obj, page);
        else return autoreleaseNoPage(obj);
    }

    /// AutoreleasePoolPage类的public方法
public:
    static inline id autorelease(id obj) /// 添加到pool中
    {
        assert(obj);
        assert(!obj->isTaggedPointer());
        id *dest __unused = autoreleaseFast(obj);
        assert(!dest  ||  dest == EMPTY_POOL_PLACEHOLDER  ||  *dest == obj);
        return obj;
    }


    static inline void *push() 
    {
        id *dest;
        if (DebugPoolAllocation) { /// 调试相关忽略
            // Each autorelease pool starts on a new pool page.
            dest = autoreleaseNewPage(POOL_BOUNDARY);
        } else {
            dest = autoreleaseFast(POOL_BOUNDARY);
            /// push一个POOL_BOUNDARY（哨兵对象，page中存放这个哨兵对象的地址，哨兵对象指向nil）
            /// 在pop时,会传入这个POOL_BOUNDARY参数，然后从前到后直到遇到POOL_BOUNDARY时停止释放假如释放池的对象
        }
        assert(dest == EMPTY_POOL_PLACEHOLDER || *dest == POOL_BOUNDARY);
        return dest;
    }

    static void badPop(void *token)
    {
        // Error. For bincompat purposes this is not 
        // fatal in executables built with old SDKs.

        if (DebugPoolAllocation || sdkIsAtLeast(10_12, 10_0, 10_0, 3_0, 2_0)) {
            // OBJC_DEBUG_POOL_ALLOCATION or new SDK. Bad pop is fatal.
            _objc_fatal
                ("Invalid or prematurely-freed autorelease pool %p.", token);
        }

        // Old SDK. Bad pop is warned once.
        static bool complained = false;
        if (!complained) {
            complained = true;
            _objc_inform_now_and_on_crash
                ("Invalid or prematurely-freed autorelease pool %p. "
                 "Set a breakpoint on objc_autoreleasePoolInvalid to debug. "
                 "Proceeding anyway because the app is old "
                 "(SDK version " SDK_FORMAT "). Memory errors are likely.",
                     token, FORMAT_SDK(sdkVersion()));
        }
        objc_autoreleasePoolInvalid(token);
    }
    
    /// 该token是一个POOL_BOUNDARY,每次push时都会在pool中添加一个POOL_BOUNDARY.
    /// 一对pop\push操作是使用同一个POOL_BOUNDARY
    static inline void pop(void *token)
    {
        AutoreleasePoolPage *page;
        id *stop;

        if (token == (void*)EMPTY_POOL_PLACEHOLDER) {
            // Popping the top-level placeholder pool.
            if (hotPage()) {
                // Pool was used. Pop its contents normally.
                // Pool pages remain allocated for re-use as usual.
                pop(coldPage()->begin());
            } else {
                // Pool was never used. Clear the placeholder.
                setHotPage(nil);
            }
            return;
        }

        page = pageForPointer(token); /// 获取token所在的Page
        stop = (id *)token;
        
        
// MARK: 没看懂啊！！！
        if (*stop != POOL_BOUNDARY) {
            if (stop == page->begin()  &&  !page->parent) {
                // Start of coldest page may correctly not be POOL_BOUNDARY:
                // 1. top-level pool is popped, leaving the cold page in place
                // 2. an object is autoreleased with no pool
            } else {
                // Error. For bincompat purposes this is not 
                // fatal in executables built with old SDKs.
                return badPop(token);
            }
        }

        if (PrintPoolHiwat) printHiwat(); /// 调试相关忽略

        page->releaseUntil(stop); /// 释放对象直到stop这个哨兵的位置

        // memory: delete empty children
        if (DebugPoolAllocation  &&  page->empty()) {
            // special case: delete everything during page-per-pool debugging
            AutoreleasePoolPage *parent = page->parent;
            page->kill();
            setHotPage(parent);
        } else if (DebugMissingPools  &&  page->empty()  &&  !page->parent) {
            // special case: delete everything for pop(top) 
            // when debugging missing autorelease pools
            page->kill();
            setHotPage(nil);
        } 
        else if (page->child) {
            // hysteresis: keep one empty child if page is more than half full
            /// 当前page只留下一个child链
            /// 因为现在链表中的存储autorelease对象的page只有当前的这个page了,剩下的pagek可以移除，
            /// 为了提高效率，避免频繁的创建新的page,这里根据情况保留1-2个空的page
            if (page->lessThanHalfFull()) {
                page->child->kill();
            }
            else if (page->child->child) {
                page->child->child->kill();
            }
        }
    }

    static void init()
    {
        int r __unused = pthread_key_init_np(AutoreleasePoolPage::key, 
                                             AutoreleasePoolPage::tls_dealloc);
        assert(r == 0);
    }

    void print() 
    {
        _objc_inform("[%p]  ................  PAGE %s %s %s", this, 
                     full() ? "(full)" : "", 
                     this == hotPage() ? "(hot)" : "", 
                     this == coldPage() ? "(cold)" : "");
        check(false);
        for (id *p = begin(); p < next; p++) {
            if (*p == POOL_BOUNDARY) {
                _objc_inform("[%p]  ################  POOL %p", p, p);
            } else {
                _objc_inform("[%p]  %#16lx  %s", 
                             p, (unsigned long)*p, object_getClassName(*p));
            }
        }
    }

    static void printAll()
    {        
        _objc_inform("##############");
        _objc_inform("AUTORELEASE POOLS for thread %p", pthread_self());

        AutoreleasePoolPage *page;
        ptrdiff_t objects = 0;
        for (page = coldPage(); page; page = page->child) {
            objects += page->next - page->begin();
        }
        _objc_inform("%llu releases pending.", (unsigned long long)objects);

        if (haveEmptyPoolPlaceholder()) {
            _objc_inform("[%p]  ................  PAGE (placeholder)", 
                         EMPTY_POOL_PLACEHOLDER);
            _objc_inform("[%p]  ################  POOL (placeholder)", 
                         EMPTY_POOL_PLACEHOLDER);
        }
        else {
            for (page = coldPage(); page; page = page->child) {
                page->print();
            }
        }

        _objc_inform("##############");
    }

    static void printHiwat()
    {
        // Check and propagate high water mark
        // Ignore high water marks under 256 to suppress noise.
        AutoreleasePoolPage *p = hotPage();
        uint32_t mark = p->depth*COUNT + (uint32_t)(p->next - p->begin());
        if (mark > p->hiwat  &&  mark > 256) {
            for( ; p; p = p->parent) {
                p->unprotect();
                p->hiwat = mark;
                p->protect();
            }
            
            _objc_inform("POOL HIGHWATER: new high water mark of %u "
                         "pending releases for thread %p:", 
                         mark, pthread_self());
            
            void *stack[128];
            int count = backtrace(stack, sizeof(stack)/sizeof(stack[0]));
            char **sym = backtrace_symbols(stack, count);
            for (int i = 0; i < count; i++) {
                _objc_inform("POOL HIGHWATER:     %s", sym[i]);
            }
            free(sym);
        }
    }

#undef POOL_BOUNDARY
};

// anonymous namespace
};


/***********************************************************************
* Slow paths for inline control
**********************************************************************/

#if SUPPORT_NONPOINTER_ISA

NEVER_INLINE id 
objc_object::rootRetain_overflow(bool tryRetain)
{
    return rootRetain(tryRetain, true);
}


NEVER_INLINE bool 
objc_object::rootRelease_underflow(bool performDealloc)
{
    return rootRelease(performDealloc, true);
}


// Slow path of clearDeallocating() 
// for objects with nonpointer isa
// that were ever weakly referenced 
// or whose retain count ever overflowed to the side table.
NEVER_INLINE void
objc_object::clearDeallocating_slow()
{
    assert(isa.nonpointer  &&  (isa.weakly_referenced || isa.has_sidetable_rc));

    SideTable& table = SideTables()[this];
    table.lock();
    if (isa.weakly_referenced) {
        weak_clear_no_lock(&table.weak_table, (id)this);
    }
    if (isa.has_sidetable_rc) {
        table.refcnts.erase(this);
    }
    table.unlock();
}

#endif

__attribute__((noinline,used))
id 
objc_object::rootAutorelease2()
{
    assert(!isTaggedPointer());
    return AutoreleasePoolPage::autorelease((id)this);
}


BREAKPOINT_FUNCTION(
    void objc_overrelease_during_dealloc_error(void)
);


NEVER_INLINE
bool 
objc_object::overrelease_error()
{
    _objc_inform_now_and_on_crash("%s object %p overreleased while already deallocating; break on objc_overrelease_during_dealloc_error to debug", object_getClassName((id)this), this);
    objc_overrelease_during_dealloc_error();
    return false;  // allow rootRelease() to tail-call this
}


/***********************************************************************
* Retain count operations for side table.
**********************************************************************/


#if DEBUG
// Used to assert that an object is not present in the side table.
bool
objc_object::sidetable_present()
{
    bool result = false;
    SideTable& table = SideTables()[this];

    table.lock();

    RefcountMap::iterator it = table.refcnts.find(this);
    if (it != table.refcnts.end()) result = true;

    if (weak_is_registered_no_lock(&table.weak_table, (id)this)) result = true;

    table.unlock();

    return result;
}
#endif

#if SUPPORT_NONPOINTER_ISA

void 
objc_object::sidetable_lock()
{
    SideTable& table = SideTables()[this];
    table.lock();
}

void 
objc_object::sidetable_unlock()
{
    SideTable& table = SideTables()[this];
    table.unlock();
}


// Move the entire retain count to the side table, 
// as well as isDeallocating and weaklyReferenced.
void 
objc_object::sidetable_moveExtraRC_nolock(size_t extra_rc, 
                                          bool isDeallocating, 
                                          bool weaklyReferenced)
{
    assert(!isa.nonpointer);        // should already be changed to raw pointer
    SideTable& table = SideTables()[this];

    size_t& refcntStorage = table.refcnts[this];
    size_t oldRefcnt = refcntStorage;
    // not deallocating - that was in the isa
    assert((oldRefcnt & SIDE_TABLE_DEALLOCATING) == 0);  
    assert((oldRefcnt & SIDE_TABLE_WEAKLY_REFERENCED) == 0);  

    uintptr_t carry;
    size_t refcnt = addc(oldRefcnt, extra_rc << SIDE_TABLE_RC_SHIFT, 0, &carry);
    if (carry) refcnt = SIDE_TABLE_RC_PINNED;
    if (isDeallocating) refcnt |= SIDE_TABLE_DEALLOCATING;
    if (weaklyReferenced) refcnt |= SIDE_TABLE_WEAKLY_REFERENCED;

    refcntStorage = refcnt;
}


// Move some retain counts to the side table from the isa field.
// Returns true if the object is now pinned.
bool 
objc_object::sidetable_addExtraRC_nolock(size_t delta_rc)
{
    assert(isa.nonpointer);
    SideTable& table = SideTables()[this];
    
    /**
     在DenseMapBase类中重载了[]运算符,通过key可以获取到value。
     将key、value通过std::pair打包以后，放入迭代器中，所以取出值之后，.first代表key，.second代表value
     
       ValueT &operator[](const KeyT &Key) {
         return FindAndConstruct(Key).second;
       }
     */
    /// 获取存放引用计数的value值 这里重载了运算符[],可以发现最终获取的是value(.second)的值
    size_t& refcntStorage = table.refcnts[this];
  
    size_t oldRefcnt = refcntStorage;
    // isa-side bits should not be set here
    assert((oldRefcnt & SIDE_TABLE_DEALLOCATING) == 0);
    assert((oldRefcnt & SIDE_TABLE_WEAKLY_REFERENCED) == 0);

    /// 63                    62 .. 计数部分 .. 2          1                          0
    /// SIDE_TABLE_RC_PINNED  ....................        SIDE_TABLE_DEALLOCATING    SIDE_TABLE_WEAKLY_REFERENCED
    /// value中最高位为1说明sidetable也存放不下了
    if (oldRefcnt & SIDE_TABLE_RC_PINNED) return true;

    uintptr_t carry;
    size_t newRefcnt = 
        addc(oldRefcnt, delta_rc << SIDE_TABLE_RC_SHIFT, 0, &carry); /// 更新引用计数
    if (carry) { /// 溢出了
        /// 标记为溢出
        refcntStorage =
            SIDE_TABLE_RC_PINNED | (oldRefcnt & SIDE_TABLE_FLAG_MASK);
        return true;
    }
    else { /// 没有溢出则将新的引用计数更新
        refcntStorage = newRefcnt;
        return false;
    }
}


// Move some retain counts from the side table to the isa field.
// Returns the actual count subtracted, which may be less than the request.
size_t 
objc_object::sidetable_subExtraRC_nolock(size_t delta_rc)
{
    assert(isa.nonpointer);
    SideTable& table = SideTables()[this];

    RefcountMap::iterator it = table.refcnts.find(this);
    if (it == table.refcnts.end()  ||  it->second == 0) { /// 没有找到或者计数为0
        // Side table retain count is zero. Can't borrow.
        return 0;
    }
    size_t oldRefcnt = it->second; /// 获取存放计数的value值

    // isa-side bits should not be set here 不能在此设置标记
    assert((oldRefcnt & SIDE_TABLE_DEALLOCATING) == 0);
    assert((oldRefcnt & SIDE_TABLE_WEAKLY_REFERENCED) == 0);

    size_t newRefcnt = oldRefcnt - (delta_rc << SIDE_TABLE_RC_SHIFT); /// 因为oldRefcnt的0、1位存放的是其他标志信息不参与计数
    assert(oldRefcnt > newRefcnt);  // shouldn't underflow 不能下溢
    it->second = newRefcnt;
    return delta_rc;
}


size_t 
objc_object::sidetable_getExtraRC_nolock()
{
    assert(isa.nonpointer);
    SideTable& table = SideTables()[this];
    RefcountMap::iterator it = table.refcnts.find(this);
    if (it == table.refcnts.end()) return 0; /// Side table retain count is zero
    else return it->second >> SIDE_TABLE_RC_SHIFT; /// it->second的0、1位不参与计数。所以需要左移两位获取sidetable中的计数数量
}


// SUPPORT_NONPOINTER_ISA
#endif


id
objc_object::sidetable_retain()
{
#if SUPPORT_NONPOINTER_ISA
    assert(!isa.nonpointer);
#endif
    SideTable& table = SideTables()[this];
    
    table.lock();
    /**
     在DenseMapBase类中重载了[]运算符,通过key可以获取到value。
     将key、value通过std::pair打包以后，放入迭代器中，所以取出值之后，.first代表key，.second代表value
     
       ValueT &operator[](const KeyT &Key) {
         return FindAndConstruct(Key).second;
       }
     */
    /// 获取存放引用计数的value值 这里重载了运算符[],可以发现最终获取的是value(.second)的值
    size_t& refcntStorage = table.refcnts[this];
    
    
    /**
         #define SIDE_TABLE_WEAKLY_REFERENCED (1UL<<0)
         #define SIDE_TABLE_DEALLOCATING      (1UL<<1)  // MSB-ward of weak bit
         #define SIDE_TABLE_RC_ONE            (1UL<<2)  // MSB-ward of deallocating bit
         #define SIDE_TABLE_RC_PINNED         (1UL<<(WORD_BITS-1))
         
         63                    62 .. 计数部分 .. 2          1                          0
         SIDE_TABLE_RC_PINNED  ....................        SIDE_TABLE_DEALLOCATING    SIDE_TABLE_WEAKLY_REFERENCED
         value中最高位为1说明sidetable也存放不下了
    */
    if (! (refcntStorage & SIDE_TABLE_RC_PINNED)) { /// 可以存储这个数
        refcntStorage += SIDE_TABLE_RC_ONE; /// 引用计数+1,引用计数的值从第二位开始存储的,第0位和第1位有其他定义
    }
    table.unlock();

    return (id)this;
}


bool
objc_object::sidetable_tryRetain()
{
#if SUPPORT_NONPOINTER_ISA
    assert(!isa.nonpointer);
#endif
    
    SideTable& table = SideTables()[this];

    // NO SPINLOCK HERE
    // _objc_rootTryRetain() is called exclusively by _objc_loadWeak(), 
    // which already acquired the lock on our behalf.
    // 这里不加锁的原因:_objc_rootTryRetain()明确的被_objc_loadWeak()调用,_objc_loadWeak()中已经加锁了

    // fixme can't do this efficiently with os_lock_handoff_s
    // if (table.slock == 0) {
    //     _objc_fatal("Do not call -_tryRetain.");
    // }

    bool result = true;
    RefcountMap::iterator it = table.refcnts.find(this);
    if (it == table.refcnts.end()) { /// Side table中引用计数为0
        table.refcnts[this] = SIDE_TABLE_RC_ONE;
    } else if (it->second & SIDE_TABLE_DEALLOCATING) {
        result = false;
    } else if (! (it->second & SIDE_TABLE_RC_PINNED)) {
        it->second += SIDE_TABLE_RC_ONE;
    }
    
    return result;
}


uintptr_t
objc_object::sidetable_retainCount()
{
    SideTable& table = SideTables()[this];

    size_t refcnt_result = 1;
    
    table.lock();
    RefcountMap::iterator it = table.refcnts.find(this);
    if (it != table.refcnts.end()) {
        // this is valid for SIDE_TABLE_RC_PINNED too
        refcnt_result += it->second >> SIDE_TABLE_RC_SHIFT; /// side table中的retain count
    }
    table.unlock();
    return refcnt_result;
}


bool 
objc_object::sidetable_isDeallocating()
{
    SideTable& table = SideTables()[this];

    // NO SPINLOCK HERE
    // _objc_rootIsDeallocating() is called exclusively by _objc_storeWeak(), 
    // which already acquired the lock on our behalf.


    // fixme can't do this efficiently with os_lock_handoff_s
    // if (table.slock == 0) {
    //     _objc_fatal("Do not call -_isDeallocating.");
    // }

    RefcountMap::iterator it = table.refcnts.find(this);
    return (it != table.refcnts.end()) && (it->second & SIDE_TABLE_DEALLOCATING);
}


bool 
objc_object::sidetable_isWeaklyReferenced()
{
    bool result = false;

    SideTable& table = SideTables()[this];
    table.lock();

    RefcountMap::iterator it = table.refcnts.find(this);
    if (it != table.refcnts.end()) {
        result = it->second & SIDE_TABLE_WEAKLY_REFERENCED;
    }

    table.unlock();

    return result;
}


void 
objc_object::sidetable_setWeaklyReferenced_nolock()
{
#if SUPPORT_NONPOINTER_ISA
    assert(!isa.nonpointer);
#endif

    SideTable& table = SideTables()[this];

    table.refcnts[this] |= SIDE_TABLE_WEAKLY_REFERENCED;
}


// rdar://20206767
// return uintptr_t instead of bool so that the various raw-isa 
// -release paths all return zero in eax
uintptr_t
objc_object::sidetable_release(bool performDealloc)
{
#if SUPPORT_NONPOINTER_ISA
    assert(!isa.nonpointer);
#endif
    /// 未优化的isa指针。即所有的引用计数都存储在sidetable中
    
    SideTable& table = SideTables()[this];

    bool do_dealloc = false;

    table.lock();
    /*****
     该RefcountMap::iterator it = table.refcnts.find(this);方法内部执行逻辑
     
     1.
     iterator find(const KeyT &Val) {
        BucketT *TheBucket;
        if (LookupBucketFor(Val, TheBucket)) /// 找Val对应的桶
          return iterator(TheBucket, getBucketsEnd(), true); /// 返回迭代器，其中组装了找到的桶
        return end(); /// 没有Val对相应的桶,返回end()的迭代器
      }
    
      LookupBucketFor(Val, TheBucket)函数的说明:
     /// LookupBucketFor - Lookup the appropriate bucket for Val, returning it in
     /// FoundBucket.  If the bucket contains the key and a value, this returns
     /// true, otherwise it returns a bucket with an empty marker or tombstone
     /// or zero value and returns false.
     */
    
    RefcountMap::iterator it = table.refcnts.find(this);
    if (it == table.refcnts.end()) { /// 没有找到对应的引用计数
        do_dealloc = true;
        table.refcnts[this] = SIDE_TABLE_DEALLOCATING; /// 设置SIDE_TABLE_DEALLOCATING标记为1 其他位全置为0
    } else if (it->second < SIDE_TABLE_DEALLOCATING) { /// 判断引用计数是否为0
        /// 如果小于SIDE_TABLE_DEALLOCATING,只有00000001(有弱引用)或者00000000,两种情况下,引用计数都为0,所以需要将do_dealloc置为0
        /// SIDE_TABLE_WEAKLY_REFERENCED may be set. Don't change it.
        do_dealloc = true;
        it->second |= SIDE_TABLE_DEALLOCATING;          /// 设置SIDE_TABLE_DEALLOCATING标记为1 SIDE_TABLE_WEAKLY_REFERENCED标记不变
    } else if (! (it->second & SIDE_TABLE_RC_PINNED)) {
        it->second -= SIDE_TABLE_RC_ONE;   /// 计数-1
    }
    table.unlock();
    if (do_dealloc  &&  performDealloc) {
        /// 向对象发送dealloc消息
        ((void(*)(objc_object *, SEL))objc_msgSend)(this, SEL_dealloc);
    }
    return do_dealloc;
}


void 
objc_object::sidetable_clearDeallocating()
{
    SideTable& table = SideTables()[this];

    // clear any weak table items
    // clear extra retain count and deallocating bit
    // (fixme warn or abort if extra retain count == 0 ?)
    table.lock();
    RefcountMap::iterator it = table.refcnts.find(this);
    if (it != table.refcnts.end()) {
        if (it->second & SIDE_TABLE_WEAKLY_REFERENCED) {
            weak_clear_no_lock(&table.weak_table, (id)this);
        }
        table.refcnts.erase(it);
    }
    table.unlock();
}


/***********************************************************************
* Optimized retain/release/autorelease entrypoints
**********************************************************************/


#if __OBJC2__

__attribute__((aligned(16)))
id 
objc_retain(id obj)
{
    if (!obj) return obj;
    if (obj->isTaggedPointer()) return obj; /// 是否是taggedPointer
    return obj->retain(); /// 计数器+1
}


__attribute__((aligned(16)))
void 
objc_release(id obj)
{
    if (!obj) return;
    if (obj->isTaggedPointer()) return;
    return obj->release(); /// 计数器-1、析构
}


__attribute__((aligned(16)))
id
objc_autorelease(id obj)
{
    if (!obj) return obj;
    if (obj->isTaggedPointer()) return obj;
    return obj->autorelease(); /// 将obj添加到autoreleasePool
}


// OBJC2
#else
// not OBJC2


id objc_retain(id obj) { return [obj retain]; }
void objc_release(id obj) { [obj release]; }
id objc_autorelease(id obj) { return [obj autorelease]; }


#endif


/***********************************************************************
* Basic operations for root class implementations a.k.a. _objc_root*()
**********************************************************************/

bool
_objc_rootTryRetain(id obj) 
{
    assert(obj);

    return obj->rootTryRetain();
}

bool
_objc_rootIsDeallocating(id obj) 
{
    assert(obj);

    return obj->rootIsDeallocating();
}


void 
objc_clear_deallocating(id obj) 
{
    assert(obj);

    if (obj->isTaggedPointer()) return;
    obj->clearDeallocating();
}


bool
_objc_rootReleaseWasZero(id obj)
{
    assert(obj);

    return obj->rootReleaseShouldDealloc();
}


id
_objc_rootAutorelease(id obj)
{
    assert(obj);
    return obj->rootAutorelease();
}

uintptr_t
_objc_rootRetainCount(id obj)
{
    assert(obj);

    return obj->rootRetainCount();
}


id
_objc_rootRetain(id obj)
{
    assert(obj);

    return obj->rootRetain();
}

void
_objc_rootRelease(id obj)
{
    assert(obj);

    obj->rootRelease();
}


id
_objc_rootAllocWithZone(Class cls, malloc_zone_t *zone)
{
    id obj;

#if __OBJC2__
    // allocWithZone under __OBJC2__ ignores the zone parameter
    (void)zone;
    obj = class_createInstance(cls, 0);
#else
    if (!zone) {
        obj = class_createInstance(cls, 0);
    }
    else {
        obj = class_createInstanceFromZone(cls, 0, zone);
    }
#endif

    if (slowpath(!obj)) obj = callBadAllocHandler(cls);
    return obj;
}


// Call [cls alloc] or [cls allocWithZone:nil], with appropriate 
// shortcutting optimizations.
static ALWAYS_INLINE id
callAlloc(Class cls, bool checkNil, bool allocWithZone=false)
{
    if (slowpath(checkNil && !cls)) return nil;

#if __OBJC2__      /// OC 2.0
    
    if (fastpath(!cls->ISA()->hasCustomAWZ())) { // 类是否有自定义的alloc\allocWithZone
        // No alloc/allocWithZone implementation. Go straight to the allocator.
        // fixme store hasCustomAWZ in the non-meta class and 
        // add it to canAllocFast's summary
        
        /// canAllocFast()返回false, 该分支进不来
        if (fastpath(cls->canAllocFast())) {
            // No ctors, raw isa, etc. Go straight to the metal.
            bool dtor = cls->hasCxxDtor();
            id obj = (id)calloc(1, cls->bits.fastInstanceSize()); //分配内存
            if (slowpath(!obj)) return callBadAllocHandler(cls);
            obj->initInstanceIsa(cls, dtor);  //初始化isa指针
            
            return obj;
        }
        else { /// 我们通过alloc创建的对象一般走该分支
            // Has ctor or raw isa or something. Use the slower path.
            id obj = class_createInstance(cls, 0); /// 内部最终调用calloc分配内存
            if (slowpath(!obj)) return callBadAllocHandler(cls);
            return obj;
        }
    }
#endif

    // No shortcuts available.
    // 如果allocWithZone使用 allocWithZone分配内存
    if (allocWithZone) return [cls allocWithZone:nil];
    
    // 继续调用alloc
    return [cls alloc];
    
    /**
     通过calloc函数和 cls->bits.fastInstanceSize()分配的内存的。calloc函数是分配加初始化一起进行的。
     C语言跟内存申请相关的函数主要有 alloca、calloc、malloc、realloc等.
     1）alloca是向栈申请内存,因此无需释放.
     2）malloc分配的内存是位于堆中的,并且没有初始化内存的内容,因此基本上malloc之后,调用函数memset来初始化这部分的内存空间.
     3）calloc则将初始化这部分的内存,设置为0.
     4）realloc则对malloc申请的内存进行大小的调整.
     
     malloc() 函数和calloc()函数的主要区别是前者不能初始化所分配的内存空间，而后者能
     malloc调用形式为(类型*)malloc(size)：在内存的动态存储区中分配一块长度为“size”字节的连续区域，返回该区域的首地址。
     calloc调用形式为(类型*)calloc(n，size)：在内存的动态存储区中分配n块长度为“size”字节的连续区域，返回首地址。
     且calloc() 函数会将所分配的内存空间中的每一位都初始化为零
     
     realloc调用形式为(类型*)realloc(*ptr，size)：将ptr内存大小增大到size。
     free的调用形式为free(void*ptr)：释放ptr所指向的一块内存空间。
     */
}


// Base class implementation of +alloc. cls is not nil.
// Calls [cls allocWithZone:nil].
id
_objc_rootAlloc(Class cls)
{
    return callAlloc(cls, false/*checkNil*/, true/*allocWithZone*/);
}

// Calls [cls alloc].
id
objc_alloc(Class cls)
{
    return callAlloc(cls, true/*checkNil*/, false/*allocWithZone*/);
}

// Calls [cls allocWithZone:nil].
id 
objc_allocWithZone(Class cls)
{
    return callAlloc(cls, true/*checkNil*/, true/*allocWithZone*/);
}


void
_objc_rootDealloc(id obj)
{
    assert(obj);

    obj->rootDealloc();
}

void
_objc_rootFinalize(id obj __unused)
{
    assert(obj);
    _objc_fatal("_objc_rootFinalize called with garbage collection off");
}


id
_objc_rootInit(id obj)
{
    // In practice, it will be hard to rely on this function.
    // Many classes do not properly chain -init calls.
    return obj;
}


malloc_zone_t *
_objc_rootZone(id obj)
{
    (void)obj;
#if __OBJC2__
    // allocWithZone under __OBJC2__ ignores the zone parameter
    return malloc_default_zone();
#else
    malloc_zone_t *rval = malloc_zone_from_ptr(obj);
    return rval ? rval : malloc_default_zone();
#endif
}

uintptr_t
_objc_rootHash(id obj)
{
    return (uintptr_t)obj;
}

void *
objc_autoreleasePoolPush(void)
{
    return AutoreleasePoolPage::push();
}

void
objc_autoreleasePoolPop(void *ctxt)
{
    AutoreleasePoolPage::pop(ctxt);
}


void *
_objc_autoreleasePoolPush(void)
{
    return objc_autoreleasePoolPush();
}

void
_objc_autoreleasePoolPop(void *ctxt)
{
    objc_autoreleasePoolPop(ctxt);
}

void 
_objc_autoreleasePoolPrint(void)
{
    AutoreleasePoolPage::printAll();
}


// Same as objc_release but suitable for tail-calling 
// if you need the value back and don't want to push a frame before this point.
__attribute__((noinline))
static id 
objc_releaseAndReturn(id obj)
{
    objc_release(obj);
    return obj;
}

// Same as objc_retainAutorelease but suitable for tail-calling 
// if you don't want to push a frame before this point.
__attribute__((noinline))
static id 
objc_retainAutoreleaseAndReturn(id obj)
{
    return objc_retainAutorelease(obj);
}


// Prepare a value at +1 for return through a +0 autoreleasing convention.
id 
objc_autoreleaseReturnValue(id obj)
{
    if (prepareOptimizedReturn(ReturnAtPlus1)) return obj;

    return objc_autorelease(obj);
}

// Prepare a value at +0 for return through a +0 autoreleasing convention.
id 
objc_retainAutoreleaseReturnValue(id obj)
{
    if (prepareOptimizedReturn(ReturnAtPlus0)) return obj;

    // not objc_autoreleaseReturnValue(objc_retain(obj)) 
    // because we don't need another optimization attempt
    return objc_retainAutoreleaseAndReturn(obj);
}

// Accept a value returned through a +0 autoreleasing convention for use at +1.
id
objc_retainAutoreleasedReturnValue(id obj)
{
    if (acceptOptimizedReturn() == ReturnAtPlus1) return obj;

    return objc_retain(obj);
}

// Accept a value returned through a +0 autoreleasing convention for use at +0.
id
objc_unsafeClaimAutoreleasedReturnValue(id obj)
{
    if (acceptOptimizedReturn() == ReturnAtPlus0) return obj;

    return objc_releaseAndReturn(obj);
}

id
objc_retainAutorelease(id obj)
{
    return objc_autorelease(objc_retain(obj));
}

void
_objc_deallocOnMainThreadHelper(void *context)
{
    id obj = (id)context;
    [obj dealloc];
}

// convert objc_objectptr_t to id, callee must take ownership.
id objc_retainedObject(objc_objectptr_t pointer) { return (id)pointer; }

// convert objc_objectptr_t to id, without ownership transfer.
id objc_unretainedObject(objc_objectptr_t pointer) { return (id)pointer; }

// convert id to objc_objectptr_t, no ownership transfer.
objc_objectptr_t objc_unretainedPointer(id object) { return object; }


void arr_init(void) 
{
    AutoreleasePoolPage::init();
    SideTableInit();
}


#if SUPPORT_TAGGED_POINTERS

// Placeholder for old debuggers. When they inspect an 
// extended tagged pointer object they will see this isa.

@interface __NSUnrecognizedTaggedPointer : NSObject
@end

@implementation __NSUnrecognizedTaggedPointer
+(void) load { } 
-(id) retain { return self; }
-(oneway void) release { }
-(id) autorelease { return self; }
@end

#endif


@implementation NSObject

+ (void)load {
}

+ (void)initialize {
}

+ (id)self {
    return (id)self;
}

- (id)self {
    return self;
}

+ (Class)class {
    return self;
}

- (Class)class {
    return object_getClass(self);
}

+ (Class)superclass {
    return self->superclass;
}

- (Class)superclass {
    return [self class]->superclass;
}

+ (BOOL)isMemberOfClass:(Class)cls {
    return object_getClass((id)self) == cls;
}

- (BOOL)isMemberOfClass:(Class)cls {
    return [self class] == cls;
}

+ (BOOL)isKindOfClass:(Class)cls {
    for (Class tcls = object_getClass((id)self); tcls; tcls = tcls->superclass) {
        if (tcls == cls) return YES;
    }
    return NO;
}

- (BOOL)isKindOfClass:(Class)cls {
    for (Class tcls = [self class]; tcls; tcls = tcls->superclass) {
        if (tcls == cls) return YES;
    }
    return NO;
}

+ (BOOL)isSubclassOfClass:(Class)cls {
    for (Class tcls = self; tcls; tcls = tcls->superclass) {
        if (tcls == cls) return YES;
    }
    return NO;
}

+ (BOOL)isAncestorOfObject:(NSObject *)obj {
    for (Class tcls = [obj class]; tcls; tcls = tcls->superclass) {
        if (tcls == self) return YES;
    }
    return NO;
}

+ (BOOL)instancesRespondToSelector:(SEL)sel {
    if (!sel) return NO;
    return class_respondsToSelector(self, sel);
}

+ (BOOL)respondsToSelector:(SEL)sel {
    if (!sel) return NO;
    return class_respondsToSelector_inst(object_getClass(self), sel, self);
}

- (BOOL)respondsToSelector:(SEL)sel {
    if (!sel) return NO;
    return class_respondsToSelector_inst([self class], sel, self);
}

+ (BOOL)conformsToProtocol:(Protocol *)protocol {
    if (!protocol) return NO;
    for (Class tcls = self; tcls; tcls = tcls->superclass) {
        if (class_conformsToProtocol(tcls, protocol)) return YES;
    }
    return NO;
}

- (BOOL)conformsToProtocol:(Protocol *)protocol {
    if (!protocol) return NO;
    for (Class tcls = [self class]; tcls; tcls = tcls->superclass) {
        if (class_conformsToProtocol(tcls, protocol)) return YES;
    }
    return NO;
}

+ (NSUInteger)hash {
    return _objc_rootHash(self);
}

- (NSUInteger)hash {
    return _objc_rootHash(self);
}

+ (BOOL)isEqual:(id)obj {
    return obj == (id)self;
}

- (BOOL)isEqual:(id)obj {
    return obj == self;
}


+ (BOOL)isFault {
    return NO;
}

- (BOOL)isFault {
    return NO;
}

+ (BOOL)isProxy {
    return NO;
}

- (BOOL)isProxy {
    return NO;
}


+ (IMP)instanceMethodForSelector:(SEL)sel {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return class_getMethodImplementation(self, sel);
}

+ (IMP)methodForSelector:(SEL)sel {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return object_getMethodImplementation((id)self, sel);
}

- (IMP)methodForSelector:(SEL)sel {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return object_getMethodImplementation(self, sel);
}

+ (BOOL)resolveClassMethod:(SEL)sel {
    return NO;
}

+ (BOOL)resolveInstanceMethod:(SEL)sel {
    return NO;
}

// Replaced by CF (throws an NSException)
+ (void)doesNotRecognizeSelector:(SEL)sel {
    _objc_fatal("+[%s %s]: unrecognized selector sent to instance %p", 
                class_getName(self), sel_getName(sel), self);
}

// Replaced by CF (throws an NSException)
- (void)doesNotRecognizeSelector:(SEL)sel {
    _objc_fatal("-[%s %s]: unrecognized selector sent to instance %p", 
                object_getClassName(self), sel_getName(sel), self);
}


+ (id)performSelector:(SEL)sel {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL))objc_msgSend)((id)self, sel);
}

+ (id)performSelector:(SEL)sel withObject:(id)obj {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL, id))objc_msgSend)((id)self, sel, obj);
}

+ (id)performSelector:(SEL)sel withObject:(id)obj1 withObject:(id)obj2 {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL, id, id))objc_msgSend)((id)self, sel, obj1, obj2);
}

- (id)performSelector:(SEL)sel {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL))objc_msgSend)(self, sel);
}

- (id)performSelector:(SEL)sel withObject:(id)obj {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL, id))objc_msgSend)(self, sel, obj);
}

- (id)performSelector:(SEL)sel withObject:(id)obj1 withObject:(id)obj2 {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL, id, id))objc_msgSend)(self, sel, obj1, obj2);
}


// Replaced by CF (returns an NSMethodSignature)
+ (NSMethodSignature *)instanceMethodSignatureForSelector:(SEL)sel {
    _objc_fatal("+[NSObject instanceMethodSignatureForSelector:] "
                "not available without CoreFoundation");
}

// Replaced by CF (returns an NSMethodSignature)
+ (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    _objc_fatal("+[NSObject methodSignatureForSelector:] "
                "not available without CoreFoundation");
}

// Replaced by CF (returns an NSMethodSignature)
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    _objc_fatal("-[NSObject methodSignatureForSelector:] "
                "not available without CoreFoundation");
}

+ (void)forwardInvocation:(NSInvocation *)invocation {
    [self doesNotRecognizeSelector:(invocation ? [invocation selector] : 0)];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    [self doesNotRecognizeSelector:(invocation ? [invocation selector] : 0)];
}

+ (id)forwardingTargetForSelector:(SEL)sel {
    return nil;
}

- (id)forwardingTargetForSelector:(SEL)sel {
    return nil;
}


// Replaced by CF (returns an NSString)
+ (NSString *)description {
    return nil;
}

// Replaced by CF (returns an NSString)
- (NSString *)description {
    return nil;
}

+ (NSString *)debugDescription {
    return [self description];
}

- (NSString *)debugDescription {
    return [self description];
}


+ (id)new {
    return [callAlloc(self, false/*checkNil*/) init];
}

+ (id)retain {
    return (id)self;
}

// Replaced by ObjectAlloc
- (id)retain {
    return ((id)self)->rootRetain();
}


+ (BOOL)_tryRetain {
    return YES;
}

// Replaced by ObjectAlloc
- (BOOL)_tryRetain {
    return ((id)self)->rootTryRetain();
}

+ (BOOL)_isDeallocating {
    return NO;
}

- (BOOL)_isDeallocating {
    return ((id)self)->rootIsDeallocating();
}

+ (BOOL)allowsWeakReference { 
    return YES; 
}

+ (BOOL)retainWeakReference { 
    return YES; 
}

- (BOOL)allowsWeakReference { 
    return ! [self _isDeallocating]; 
}

- (BOOL)retainWeakReference { 
    return [self _tryRetain]; 
}

+ (oneway void)release {
}

// Replaced by ObjectAlloc
- (oneway void)release {
    ((id)self)->rootRelease();
}

+ (id)autorelease {
    return (id)self;
}

// Replaced by ObjectAlloc
- (id)autorelease {
    return ((id)self)->rootAutorelease();
}

+ (NSUInteger)retainCount {
    return ULONG_MAX;
}

- (NSUInteger)retainCount {
    return ((id)self)->rootRetainCount();
}

+ (id)alloc {
    return _objc_rootAlloc(self);
}

// Replaced by ObjectAlloc
+ (id)allocWithZone:(struct _NSZone *)zone {
    return _objc_rootAllocWithZone(self, (malloc_zone_t *)zone);
}

// Replaced by CF (throws an NSException)
+ (id)init {
    return (id)self;
}

- (id)init {
    return _objc_rootInit(self);
}

// Replaced by CF (throws an NSException)
+ (void)dealloc {
}


// Replaced by NSZombies
- (void)dealloc {
    _objc_rootDealloc(self);
}

// Previously used by GC. Now a placeholder for binary compatibility.
- (void) finalize {
}

+ (struct _NSZone *)zone {
    return (struct _NSZone *)_objc_rootZone(self);
}

- (struct _NSZone *)zone {
    return (struct _NSZone *)_objc_rootZone(self);
}

+ (id)copy {
    return (id)self;
}

+ (id)copyWithZone:(struct _NSZone *)zone {
    return (id)self;
}

- (id)copy {
    return [(id)self copyWithZone:nil];
}

+ (id)mutableCopy {
    return (id)self;
}

+ (id)mutableCopyWithZone:(struct _NSZone *)zone {
    return (id)self;
}

- (id)mutableCopy {
    return [(id)self mutableCopyWithZone:nil];
}

@end


