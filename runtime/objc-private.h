/*
 * Copyright (c) 1999-2007 Apple Inc.  All Rights Reserved.
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
/*
 *    objc-private.h
 *    Copyright 1988-1996, NeXT Software, Inc.
 */

#ifndef _OBJC_PRIVATE_H_
#define _OBJC_PRIVATE_H_

#include "objc-config.h"

/* Isolate ourselves from the definitions of id and Class in the compiler 
 * and public headers.
 */

#ifdef _OBJC_OBJC_H_
#error include objc-private.h before other headers
#endif

#define OBJC_TYPES_DEFINED 1
#undef OBJC_OLD_DISPATCH_PROTOTYPES
#define OBJC_OLD_DISPATCH_PROTOTYPES 0

#include <cstddef>  // for nullptr_t
#include <stdint.h>
#include <assert.h>

struct objc_class;
struct objc_object;

typedef struct objc_class *Class;
typedef struct objc_object *id;

namespace {
    struct SideTable;
};

#include "isa.h"

/// isa_t的联合类型
union isa_t {
    /// 构造函数
    isa_t() { }
    isa_t(uintptr_t value) : bits(value) { }
    
    
    /**
     isa_t 中包含有cls，bits， struct三个变量，它们的内存空间是重叠的。在实际使用时，仅能够使用它们中的一种，你把它当做cls，就不能当bits访问，你把它当bits，就不能用cls来访问。
     
     由于uintptr_t bits 和 struct 都是占据64位内存，因此它们的内存空间是完全重叠的。而你将这块64位内存当做是uintptr_t bits 还是 struct，则完全是逻辑上的区分，在内存空间上，其实是一个东西。
     即uintptr_t bits 和 struct 是一个东西的两种表现形式。
     
     
     uintptr_t bits 和 struct 的关系可以看做，uintptr_t bits 向外提供了操作struct 的接口
     struct 本身则说明了uintptr_t bits 中各个二进制位的定义。
     */

    
    /// 未启用isa优化
    Class cls; /// objc_class *类型的指针 在64位的CPU架构中8个字节64bit
    /// 启用isa优化
    uintptr_t bits; /// unsigned long 在64位的CPU架构中占8个字节即64bit
    /**
     非指针类型isa实际是将 side table 中部分内存管理数据（包括部分内存引用计数、是否包含关联对象标记、是否被弱引用标记、是否已析构标记）转移到isa中，
     从而减少objc_object中内存管理相关操作的 side table 查询数量。
     objc_object中关于状态查询的方法，大多涉及到isa的位操作。方法数量有点多不一一列举，可以查看弱引用相关查询为例
     */
    
    
    
    /// 结构体:64bit。 对bits的每一位的说明
#if defined(ISA_BITFIELD)
    struct {
        ISA_BITFIELD;  // defined in isa.
        /**
         ISA_BITFIELD定义如下
         
         // extra_rc must be the MSB-most field (so it matches carry/overflow flags)
         // nonpointer must be the LSB (fixme or get rid of it)
         // shiftcls must occupy the same bits that a real class pointer would
         // bits + RC_ONE is equivalent to extra_rc + 1
         // RC_HALF is the high bit of extra_rc (i.e. half of its range)

         // future expansion:
         // uintptr_t fast_rr : 1;     // no r/r overrides
         // uintptr_t lock : 2;        // lock for atomic property, @synch
         // uintptr_t extraBytes : 1;  // allocated with extra bytes
         
         # if __arm64__
         #   define ISA_MASK        0x0000000ffffffff8ULL  由于获取isa_t中shiftcls记录的类的虚虚拟内存地址
         #   define ISA_MAGIC_MASK  0x000003f000000001ULL
         #   define ISA_MAGIC_VALUE 0x000001a000000001ULL
         #   define ISA_BITFIELD
               uintptr_t nonpointer        : 1;  是否开启isa优化
                                                 0表示isa为指针类型，存储类的地址；1表示isa为非指针类型。之所以使用最低位区分isa类型，是因为当isa为Class时，其本质是指向objc_class结构体首地址的指针，由于objc_class必定按WORD对齐，即地址必定是8的整数倍，因此指针类型的isa的末尾3位必定全为0
         
         
               uintptr_t has_assoc         : 1;  是否有关联对象
         
         
               uintptr_t has_cxx_dtor      : 1;  标记对象是否存在cxx语系的析构函数。使用指针类型isa的对象，该标记保存在 side table 中
                                                 
         
         
               uintptr_t shiftcls          : 33  保存类的虚拟内存地址，标记对象的类型（核心数据）
         
               uintptr_t magic             : 6;  用于非指针类型的isa校验，arm64架构下这6位为固定值0x1a；
         
               uintptr_t weakly_referenced : 1;  标记对象是否被弱引用。使用指针类型isa的对象，该标记保存在 side table 中
         
               uintptr_t deallocating      : 1;  标记对象是否已执行析构。使用指针类型isa的对象，该标记保存在 side table 中
         
               uintptr_t has_sidetable_rc  : 1;  标记是否联合 side table 保存该对象的引用计数
         
               uintptr_t extra_rc          : 19  值为引用计数-1
                                                 其实在绝大多数情况下，仅用优化的isa_t来记录对象的引用计数就足够了。
                                                 只有在19位的extra_rc盛放不了那么大的引用计数时，才会借助SideTable出马。
         #   define RC_ONE   (1ULL<<45)
         #   define RC_HALF  (1ULL<<18)
         */
    };
#endif
};

/**
 对象的数据结构是objc_object结构体。objc_object仅包含一个isa_t类型的isa指针，和<objc/runtime>定义的objc_object有所不同，后者的isa指针是Class（指向objc_class结构体）。
 这是因为新版本 runtime 支持非指针类型isa结构，非指针类型isa不再是指向Class的指针而是64位二进制位域，仅使用其中一部分位域保存对象的类的地址，
 其他位赋予特殊意义主要用于协助对象内存管理。
 
 objc_object包含的方法主要有以下几类：

 .isa操作相关，isa指向对象类型，在控制对象构建、对象成员变量访问、对象消息响应，对象内存管理方面有十分关键的作用
 .关联对象（associated object）相关；
 .对象弱引用相关，对象释放后需要通知弱引用自动置nil，因此对象需要知晓所有弱引用的地址；
 .引用计数相关，支持对象的引用计数（reference count）管理；
 .dealloc相关，对象析构相关，主要是释放对关联对象的引用；
 .side table 相关，side table 是 runtime 管理对象内存的核心数据结构，包含对象内存引用计数信息、对象的弱引用信息等关键数据（TODO：后续在独立文章中介绍）；
 .支持非指针类型isa相关；

 */

struct objc_object {
private:
    isa_t isa;
    
    /**
     objc_object结构体只有一个指针类型的isa成员，也就是说一个objc_object仅占用了8个字节内存，但并不说明对象仅占8个字节内存空间。
     当调用类的alloc或allocWithZone方法构建对象时，runtime会分配类的instanceSize大小的连续内存空间用于保存对象。
     在该内存块的前8个字节写入类的地址，其余空间用于保存其他成员变量。
     最后构建方法返回的id实际上是指向该内存块的首地址的指针。
     */

public:

    // ISA() assumes this is NOT a tagged pointer object
    // 获取对象类型，建立在对象不是tagged pointer的假设上
    Class ISA();

    // getIsa() allows this to be a tagged pointer object
    // 获取对象类型，对象可以是tagged pointer
    Class getIsa();

    // initIsa() should be used to init the isa of new objects only.
    // If this object already has an isa, use changeIsa() for correctness.
    // initInstanceIsa(): objects with no custom RR/AWZ
    // initClassIsa(): class objects
    // initProtocolIsa(): protocol objects
    // initIsa(): other objects
    
    // 初始化isa
    void initIsa(Class cls /*nonpointer=false*/);
    void initClassIsa(Class cls /*nonpointer=maybe*/);
    void initProtocolIsa(Class cls /*nonpointer=maybe*/);
    void initInstanceIsa(Class cls, bool hasCxxDtor);

    // changeIsa() should be used to change the isa of existing objects.
    // If this is a new object, use initIsa() for performance.
    
    // 设置isa指向新的类型
    Class changeIsa(Class newCls);

    // 对象isa是否为非指针类型
    bool hasNonpointerIsa();
    // TaggedPointer相关，忽略
    bool isTaggedPointer();
    bool isBasicTaggedPointer();
    bool isExtTaggedPointer();
    
    // 对象是否是类
    bool isClass();

    // object may have associated objects?
    // 对象关联对象相关
    bool hasAssociatedObjects();
    void setHasAssociatedObjects();

    // object may be weakly referenced?
    // 对象弱引用相关
    bool isWeaklyReferenced();
    void setWeaklyReferenced_nolock();

    // object may have -.cxx_destruct implementation?
    //对象是否包含 .cxx 构造/析构函数
    bool hasCxxDtor();

    // Optimized calls to retain/release methods
    // 引用计数相关
    id retain();
    void release();
    id autorelease();

    // Implementations of retain/release methods
    // 引用计数相关的实现
    id rootRetain();
    bool rootRelease();
    id rootAutorelease();
    bool rootTryRetain();
    bool rootReleaseShouldDealloc();
    uintptr_t rootRetainCount();

    // Implementation of dealloc methods
    // dealloc的实现
    bool rootIsDeallocating();
    void clearDeallocating();
    void rootDealloc();

private:
    void initIsa(Class newCls, bool nonpointer, bool hasCxxDtor);

    // Slow paths for inline control
    id rootAutorelease2();
    bool overrelease_error();

    // 支持非指针类型isa
#if SUPPORT_NONPOINTER_ISA
    // Unified retain count manipulation for nonpointer isa
    id rootRetain(bool tryRetain, bool handleOverflow);
    bool rootRelease(bool performDealloc, bool handleUnderflow);
    id rootRetain_overflow(bool tryRetain);
    bool rootRelease_underflow(bool performDealloc);

    void clearDeallocating_slow();

    // Side table retain count overflow for nonpointer isa  Side table保留非指针isa的计数溢出
    void sidetable_lock();
    void sidetable_unlock();

    void sidetable_moveExtraRC_nolock(size_t extra_rc, bool isDeallocating, bool weaklyReferenced);
    bool sidetable_addExtraRC_nolock(size_t delta_rc);
    size_t sidetable_subExtraRC_nolock(size_t delta_rc);
    size_t sidetable_getExtraRC_nolock();
#endif

    // Side-table 相关操作
    // Side-table-only retain count 只使用Side table 计数
    bool sidetable_isDeallocating();
    void sidetable_clearDeallocating();

    bool sidetable_isWeaklyReferenced();
    void sidetable_setWeaklyReferenced_nolock();

    id sidetable_retain();
    id sidetable_retain_slow(SideTable& table);

    uintptr_t sidetable_release(bool performDealloc = true);
    uintptr_t sidetable_release_slow(SideTable& table, bool performDealloc = true);

    bool sidetable_tryRetain();

    uintptr_t sidetable_retainCount();
#if DEBUG
    bool sidetable_present();
#endif
};


#if __OBJC2__
typedef struct method_t *Method;
typedef struct ivar_t *Ivar;
typedef struct category_t *Category;
typedef struct property_t *objc_property_t;
#else
typedef struct old_method *Method;
typedef struct old_ivar *Ivar;
typedef struct old_category *Category;
typedef struct old_property *objc_property_t;
#endif

// Public headers

#include "objc.h"
#include "runtime.h"
#include "objc-os.h"
#include "objc-abi.h"
#include "objc-api.h"
#include "objc-config.h"
#include "objc-internal.h"
#include "maptable.h"
#include "hashtable2.h"

/* Do not include message.h here. */
/* #include "message.h" */

#define __APPLE_API_PRIVATE
#include "objc-gdb.h"
#undef __APPLE_API_PRIVATE


// Private headers

#include "objc-ptrauth.h"

#if __OBJC2__
#include "objc-runtime-new.h"
#else
#include "objc-runtime-old.h"
#endif

#include "objc-references.h"
#include "objc-initialize.h"
#include "objc-loadmethod.h"


#if SUPPORT_PREOPT  &&  __cplusplus
#include <objc-shared-cache.h>
using objc_selopt_t = const objc_opt::objc_selopt_t;
#else
struct objc_selopt_t;
#endif


#define STRINGIFY(x) #x
#define STRINGIFY2(x) STRINGIFY(x)

__BEGIN_DECLS

struct header_info;

// Split out the rw data from header info.  For now put it in a huge array
// that more than exceeds the space needed.  In future we'll just allocate
// this in the shared cache builder.

// 用于记录镜像以及镜像中的 Objective-C 元素的状态，该成员的数据是可读写的。
typedef struct header_info_rw {

    // 公开的API
    bool getLoaded() const {
        return isLoaded;
    }

    void setLoaded(bool v) {
        isLoaded = v ? 1: 0;
    }

    bool getAllClassesRealized() const {
        return allClassesRealized;
    }

    void setAllClassesRealized(bool v) {
        allClassesRealized = v ? 1: 0;
    }

    header_info *getNext() const {
        return (header_info *)(next << 2);
    }

    void setNext(header_info *v) {
        next = ((uintptr_t)v) >> 2;
    }

private:
#ifdef __LP64__
    uintptr_t isLoaded              : 1;
    uintptr_t allClassesRealized    : 1;
    uintptr_t next                  : 62;
#else
    uintptr_t isLoaded              : 1;    // 最低位isLoaded标记镜像是否已加载；
    uintptr_t allClassesRealized    : 1;    // 次低位allClassesRealized标记镜像中所有的 Objective-C 类是否已完成 class realizing；
    uintptr_t next                  : 30;   // 用于保存下一个header_info节点的地址，由于地址的最低 3 位必为0因此实际上仅需保存最低 3 位之外的位即可，又因为header_info_rw仅用了最低 2 位作为特殊标记位，因此指定当前header_info* curHeader指向下一个节点header_info* nextHeader时，仅需设置((header_info_rw*)&curHeader->rw_data[0])->next = nextHeader >> 2。
#endif
} header_info_rw;

struct header_info_rw* getPreoptimizedHeaderRW(const struct header_info *const hdr);

/// 用于快速定位镜像中的头信息（mach_header_64结构体）、镜像信息。镜像信息用于标记镜像的属性，以objc_image_info结构体格式保存于 镜像文件的__DATA数据段的__objc_imageinfo data section，镜像信息在构建镜像文件时生成



typedef struct header_info {
private:
    // Note, this is no longer a pointer, but instead an offset to a pointer
    // from this location.
    // 保存镜像中的头信息mach_header_64相对当前header_info的内存地址偏移
    intptr_t mhdr_offset;

    // Note, this is no longer a pointer, but instead an offset to a pointer
    // from this location.
    // 保存镜像中的镜像信息相对当前header_info的内存地址偏移
    intptr_t info_offset;

    // Do not add fields without editing ObjCModernAbstraction.hpp
public:
    
    // 公开的API
    header_info_rw *getHeaderInfoRW() {
        header_info_rw *preopt =
            isPreoptimized() ? getPreoptimizedHeaderRW(this) : nil;
        if (preopt) return preopt;
        else return &rw_data[0];
    }

    const headerType *mhdr() const {
        return (const headerType *)(((intptr_t)&mhdr_offset) + mhdr_offset);
    }

    void setmhdr(const headerType *mhdr) {
        mhdr_offset = (intptr_t)mhdr - (intptr_t)&mhdr_offset;
    }
  
    /// 镜像信息用于标记镜像的属性，以objc_image_info结构体格式保存于 镜像文件的__DATA数据段的__objc_imageinfo data section，镜像信息在构建镜像文件时生成
    const objc_image_info *info() const {
        return (const objc_image_info *)(((intptr_t)&info_offset) + info_offset);
    }

    void setinfo(const objc_image_info *info) {
        info_offset = (intptr_t)info - (intptr_t)&info_offset;
    }

    bool isLoaded() {
        return getHeaderInfoRW()->getLoaded();
    }

    void setLoaded(bool v) {
        getHeaderInfoRW()->setLoaded(v);
    }

    bool areAllClassesRealized() {
        return getHeaderInfoRW()->getAllClassesRealized();
    }

    void setAllClassesRealized(bool v) {
        getHeaderInfoRW()->setAllClassesRealized(v);
    }

    header_info *getNext() {
        return getHeaderInfoRW()->getNext();
    }

    void setNext(header_info *v) {
        getHeaderInfoRW()->setNext(v);
    }

    bool isBundle() {
        return mhdr()->filetype == MH_BUNDLE;
    }

    const char *fname() const {
        return dyld_image_path_containing_address(mhdr());
    }

    bool isPreoptimized() const;

#if !__OBJC2__
    struct old_protocol **proto_refs;
    struct objc_module *mod_ptr;
    size_t              mod_count;
# if TARGET_OS_WIN32
    struct objc_module **modules;
    size_t moduleCount;
    struct old_protocol **protocols;
    size_t protocolCount;
    void *imageinfo;
    size_t imageinfoBytes;
    SEL *selrefs;
    size_t selrefCount;
    struct objc_class **clsrefs;
    size_t clsrefCount;    
    TCHAR *moduleName;
# endif
#endif

private:
    // Images in the shared cache will have an empty array here while those
    // allocated at run time will allocate a single entry.
    // 用于记录镜像以及镜像中的 Objective-C 元素的状态，该成员的数据是可读写的。
    // 虽然定义为数组，但是包含的元素基本为1个，不会超过1个。
    header_info_rw rw_data[];
} header_info;

extern header_info *FirstHeader;
extern header_info *LastHeader;
extern int HeaderCount;

extern void appendHeader(header_info *hi);
extern void removeHeader(header_info *hi);

extern objc_image_info *_getObjcImageInfo(const headerType *head, size_t *size);
extern bool _hasObjcContents(const header_info *hi);


// Mach-O segment and section names are 16 bytes and may be un-terminated.

static inline bool segnameEquals(const char *lhs, const char *rhs) {
    return 0 == strncmp(lhs, rhs, 16);
}

static inline bool segnameStartsWith(const char *segname, const char *prefix) {
    return 0 == strncmp(segname, prefix, strlen(prefix));
}

static inline bool sectnameEquals(const char *lhs, const char *rhs) {
    return segnameEquals(lhs, rhs);
}

static inline bool sectnameStartsWith(const char *sectname, const char *prefix){
    return segnameStartsWith(sectname, prefix);
}


/* selectors */
extern void sel_init(size_t selrefCount);
extern SEL sel_registerNameNoLock(const char *str, bool copy);

extern SEL SEL_load;
extern SEL SEL_initialize;
extern SEL SEL_resolveClassMethod;
extern SEL SEL_resolveInstanceMethod;
extern SEL SEL_cxx_construct;
extern SEL SEL_cxx_destruct;
extern SEL SEL_retain;
extern SEL SEL_release;
extern SEL SEL_autorelease;
extern SEL SEL_retainCount;
extern SEL SEL_alloc;
extern SEL SEL_allocWithZone;
extern SEL SEL_dealloc;
extern SEL SEL_copy;
extern SEL SEL_new;
extern SEL SEL_forwardInvocation;
extern SEL SEL_tryRetain;
extern SEL SEL_isDeallocating;
extern SEL SEL_retainWeakReference;
extern SEL SEL_allowsWeakReference;

/* preoptimization */
extern void preopt_init(void);
extern void disableSharedCacheOptimizations(void);
extern bool isPreoptimized(void);
extern bool noMissingWeakSuperclasses(void);
extern header_info *preoptimizedHinfoForHeader(const headerType *mhdr);

extern objc_selopt_t *preoptimizedSelectors(void);

extern Protocol *getPreoptimizedProtocol(const char *name);

extern unsigned getPreoptimizedClassUnreasonableCount();
extern Class getPreoptimizedClass(const char *name);
extern Class* copyPreoptimizedClasses(const char *name, int *outCount);

extern bool sharedRegionContains(const void *ptr);

extern Class _calloc_class(size_t size);

/* method lookup */
extern IMP lookUpImpOrNil(Class, SEL, id obj, bool initialize, bool cache, bool resolver);
extern IMP lookUpImpOrForward(Class, SEL, id obj, bool initialize, bool cache, bool resolver);

extern IMP lookupMethodInClassAndLoadCache(Class cls, SEL sel);
extern bool class_respondsToSelector_inst(Class cls, SEL sel, id inst);

extern bool objcMsgLogEnabled;
extern bool logMessageSend(bool isClassMethod,
                    const char *objectsClass,
                    const char *implementingClass,
                    SEL selector);

/* message dispatcher */
extern IMP _class_lookupMethodAndLoadCache3(id, SEL, Class);

#if !OBJC_OLD_DISPATCH_PROTOTYPES
extern void _objc_msgForward_impcache(void);
#else
extern id _objc_msgForward_impcache(id, SEL, ...);
#endif

/* errors */
extern void __objc_error(id, const char *, ...) __attribute__((format (printf, 2, 3), noreturn));
extern void _objc_inform(const char *fmt, ...) __attribute__((format (printf, 1, 2)));
extern void _objc_inform_on_crash(const char *fmt, ...) __attribute__((format (printf, 1, 2)));
extern void _objc_inform_now_and_on_crash(const char *fmt, ...) __attribute__((format (printf, 1, 2)));
extern void _objc_inform_deprecated(const char *oldname, const char *newname) __attribute__((noinline));
extern void inform_duplicate(const char *name, Class oldCls, Class cls);

/* magic */
extern Class _objc_getFreedObjectClass (void);

/* map table additions */
extern void *NXMapKeyCopyingInsert(NXMapTable *table, const void *key, const void *value);
extern void *NXMapKeyFreeingRemove(NXMapTable *table, const void *key);

/* hash table additions */
extern unsigned _NXHashCapacity(NXHashTable *table);
extern void _NXHashRehashToCapacity(NXHashTable *table, unsigned newCapacity);

/* property attribute parsing */
extern const char *copyPropertyAttributeString(const objc_property_attribute_t *attrs, unsigned int count);
extern objc_property_attribute_t *copyPropertyAttributeList(const char *attrs, unsigned int *outCount);
extern char *copyPropertyAttributeValue(const char *attrs, const char *name);

/* locking */
extern void lock_init(void);

class monitor_locker_t : nocopy_t {
    monitor_t& lock;
  public:
    monitor_locker_t(monitor_t& newLock) : lock(newLock) { lock.enter(); }
    ~monitor_locker_t() { lock.leave(); }
};

class recursive_mutex_locker_t : nocopy_t {
    recursive_mutex_t& lock;
  public:
    recursive_mutex_locker_t(recursive_mutex_t& newLock) 
        : lock(newLock) { lock.lock(); }
    ~recursive_mutex_locker_t() { lock.unlock(); }
};


/* Exceptions */
struct alt_handler_list;
extern void exception_init(void);
extern void _destroyAltHandlerList(struct alt_handler_list *list);

/* Class change notifications (gdb only for now) */
#define OBJC_CLASS_ADDED (1<<0)
#define OBJC_CLASS_REMOVED (1<<1)
#define OBJC_CLASS_IVARS_CHANGED (1<<2)
#define OBJC_CLASS_METHODS_CHANGED (1<<3)
extern void gdb_objc_class_changed(Class cls, unsigned long changes, const char *classname)
    __attribute__((noinline));


// Settings from environment variables
#define OPTION(var, env, help) extern bool var;
#include "objc-env.h"
#undef OPTION

extern void environ_init(void);

extern void logReplacedMethod(const char *className, SEL s, bool isMeta, const char *catName, IMP oldImp, IMP newImp);


// objc per-thread storage
typedef struct {
    struct _objc_initializing_classes *initializingClasses; // for +initialize
    struct SyncCache *syncCache;  // for @synchronize
    struct alt_handler_list *handlerList;  // for exception alt handlers
    char *printableNames[4];  // temporary demangled names for logging

    // If you add new fields here, don't forget to update 
    // _objc_pthread_destroyspecific()

} _objc_pthread_data;

extern _objc_pthread_data *_objc_fetch_pthread_data(bool create);
extern void tls_init(void);

// encoding.h
extern unsigned int encoding_getNumberOfArguments(const char *typedesc);
extern unsigned int encoding_getSizeOfArguments(const char *typedesc);
extern unsigned int encoding_getArgumentInfo(const char *typedesc, unsigned int arg, const char **type, int *offset);
extern void encoding_getReturnType(const char *t, char *dst, size_t dst_len);
extern char * encoding_copyReturnType(const char *t);
extern void encoding_getArgumentType(const char *t, unsigned int index, char *dst, size_t dst_len);
extern char *encoding_copyArgumentType(const char *t, unsigned int index);

// sync.h
extern void _destroySyncCache(struct SyncCache *cache);

// arr
extern void arr_init(void);
extern id objc_autoreleaseReturnValue(id obj);

// block trampolines
extern IMP _imp_implementationWithBlockNoCopy(id block);

/**
 Runtime 中用layout_bitmap结构体表示压缩前的ivarLayout，保存的是一个二进制数，
 二进制数每一位标记类的成员变量空间（instanceStart为起始instanceSize大小的内存空间）中，
 对应位置的 WORD 是否存储了id类型成员变量。

 例如，二进制数0101表示成员第二个、第四个成员变量是id类型。layout_bitmap包含以下成员：
 */
// layout.h
typedef struct {
    uint8_t *bits; // 用uint8_t指针bits指向二进制数首地址；
    size_t bitCount; // 二进制数未必完全占满bitsAllocated大小的内存空间，因此用bitCount记录，内存空间中的有效位数；
    size_t bitsAllocated; // 表示用于保存该二进制数而分配的内存空间大小，单位bit，由于按字节读取，因此bitsAllocated必定是8的倍数；
    bool weak;  // 标记是否用于描述weakIvarLayout；
} layout_bitmap;

extern layout_bitmap layout_bitmap_create(const unsigned char *layout_string, size_t layoutStringInstanceSize, size_t instanceSize, bool weak);
extern layout_bitmap layout_bitmap_create_empty(size_t instanceSize, bool weak);
extern void layout_bitmap_free(layout_bitmap bits);
extern const unsigned char *layout_string_create(layout_bitmap bits);
extern void layout_bitmap_set_ivar(layout_bitmap bits, const char *type, size_t offset);
extern void layout_bitmap_grow(layout_bitmap *bits, size_t newCount);
extern void layout_bitmap_slide(layout_bitmap *bits, size_t oldPos, size_t newPos);
extern void layout_bitmap_slide_anywhere(layout_bitmap *bits, size_t oldPos, size_t newPos);
extern bool layout_bitmap_splat(layout_bitmap dst, layout_bitmap src, 
                                size_t oldSrcInstanceSize);
extern bool layout_bitmap_or(layout_bitmap dst, layout_bitmap src, const char *msg);
extern bool layout_bitmap_clear(layout_bitmap dst, layout_bitmap src, const char *msg);
extern void layout_bitmap_print(layout_bitmap bits);


// fixme runtime
extern bool MultithreadedForkChild;
extern id objc_noop_imp(id self, SEL _cmd);
extern Class look_up_class(const char *aClassName, bool includeUnconnected, bool includeClassHandler);
extern "C" void map_images(unsigned count, const char * const paths[],
                           const struct mach_header * const mhdrs[]);
extern void map_images_nolock(unsigned count, const char * const paths[],
                              const struct mach_header * const mhdrs[]);
extern void load_images(const char *path, const struct mach_header *mh);
extern void unmap_image(const char *path, const struct mach_header *mh);
extern void unmap_image_nolock(const struct mach_header *mh);
extern void _read_images(header_info **hList, uint32_t hCount, int totalClasses, int unoptimizedTotalClass);
extern void _unload_image(header_info *hi);

extern const header_info *_headerForClass(Class cls);

extern Class _class_remap(Class cls);
extern Class _class_getNonMetaClass(Class cls, id obj);
extern Ivar _class_getVariable(Class cls, const char *name);

extern unsigned _class_createInstancesFromZone(Class cls, size_t extraBytes, void *zone, id *results, unsigned num_requested);
extern id _objc_constructOrFree(id bytes, Class cls);

extern const char *_category_getName(Category cat);
extern const char *_category_getClassName(Category cat);
extern Class _category_getClass(Category cat);
extern IMP _category_getLoadMethod(Category cat);

extern id object_cxxConstructFromClass(id obj, Class cls);
extern void object_cxxDestruct(id obj);

extern void _class_resolveMethod(Class cls, SEL sel, id inst);

extern void fixupCopiedIvars(id newObject, id oldObject);
extern Class _class_getClassForIvar(Class cls, Ivar ivar);


#define OBJC_WARN_DEPRECATED \
    do { \
        static int warned = 0; \
        if (!warned) { \
            warned = 1; \
            _objc_inform_deprecated(__FUNCTION__, NULL); \
        } \
    } while (0) \

__END_DECLS


#ifndef STATIC_ASSERT
#   define STATIC_ASSERT(x) _STATIC_ASSERT2(x, __LINE__)
#   define _STATIC_ASSERT2(x, line) _STATIC_ASSERT3(x, line)
#   define _STATIC_ASSERT3(x, line)                                     \
        typedef struct {                                                \
            int _static_assert[(x) ? 0 : -1];                           \
        } _static_assert_ ## line __attribute__((unavailable)) 
#endif

#define countof(arr) (sizeof(arr) / sizeof((arr)[0]))


static __inline uint32_t _objc_strhash(const char *s) {
    uint32_t hash = 0;
    for (;;) {
    int a = *s++;
    if (0 == a) break;
    hash += (hash << 8) + a;
    }
    return hash;
}

#if __cplusplus

template <typename T>
static inline T log2u(T x) {
    return (x<2) ? 0 : log2u(x>>1)+1;
}

template <typename T>
static inline T exp2u(T x) {
    return (1 << x);
}

template <typename T>
static T exp2m1u(T x) { 
    return (1 << x) - 1; 
}

#endif

// Misalignment-safe integer types
__attribute__((aligned(1))) typedef uintptr_t unaligned_uintptr_t;
__attribute__((aligned(1))) typedef  intptr_t unaligned_intptr_t;
__attribute__((aligned(1))) typedef  uint64_t unaligned_uint64_t;
__attribute__((aligned(1))) typedef   int64_t unaligned_int64_t;
__attribute__((aligned(1))) typedef  uint32_t unaligned_uint32_t;
__attribute__((aligned(1))) typedef   int32_t unaligned_int32_t;
__attribute__((aligned(1))) typedef  uint16_t unaligned_uint16_t;
__attribute__((aligned(1))) typedef   int16_t unaligned_int16_t;


// Global operator new and delete. We must not use any app overrides.
// This ALSO REQUIRES each of these be in libobjc's unexported symbol list.
#if __cplusplus
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Winline-new-delete"
#include <new>
inline void* operator new(std::size_t size) throw (std::bad_alloc) { return malloc(size); }
inline void* operator new[](std::size_t size) throw (std::bad_alloc) { return malloc(size); }
inline void* operator new(std::size_t size, const std::nothrow_t&) throw() { return malloc(size); }
inline void* operator new[](std::size_t size, const std::nothrow_t&) throw() { return malloc(size); }
inline void operator delete(void* p) throw() { free(p); }
inline void operator delete[](void* p) throw() { free(p); }
inline void operator delete(void* p, const std::nothrow_t&) throw() { free(p); }
inline void operator delete[](void* p, const std::nothrow_t&) throw() { free(p); }
#pragma clang diagnostic pop
#endif


class TimeLogger {
    uint64_t mStart;
    bool mRecord;
 public:
    TimeLogger(bool record = true) 
     : mStart(nanoseconds())
     , mRecord(record) 
    { }

    void log(const char *msg) {
        if (mRecord) {
            uint64_t end = nanoseconds();
            _objc_inform("%.2f ms: %s", (end - mStart) / 1000000.0, msg);
            mStart = nanoseconds();
        }
    }
};

/**
 什么是Cache Line
 Cache Line可以简单的理解为CPU Cache中的最小缓存单位。目前主流的CPU Cache的Cache Line大小都是64Bytes。
 http://cenalulu.github.io/linux/all-about-cpu-cache/
 */
enum { CacheLineSize = 64 };

// StripedMap<T> is a map of void* -> T, sized appropriately 
// for cache-friendly lock striping. 
// For example, this may be used as StripedMap<spinlock_t>
// or as StripedMap<SomeStruct> where SomeStruct stores a spin lock.

// StripedMap<T> 是一个模板类，根据传递的实际参数决定其中 array 成员存储的元素类型。
// 能通过对象的地址，运算出 Hash 值，通过该 hash 值找到对应的 value 。

template<typename T>
class StripedMap {
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    enum { StripeCount = 8 }; /// ios中共有8个SideTable
#else
    enum { StripeCount = 64 };
#endif

    struct PaddedT {
        T value alignas(CacheLineSize); /// 按照64对齐，即泛型value长度64位  T泛型： SideTable
        ///alignas什么是对齐?   举例说明，某个int类型的对象，要求其存储地址的特征是4的整倍数
    };

    PaddedT array[StripeCount]; ///在iOS中array是一个长度为8的数组，T类型强制为64位对齐。
    
    ///主要还是调用了reinterpret_cast将传入的对象地址进行类型转换的，并通过一定算法计算出指针的index，最后的%StripeCount保证保证了index不会越界
    static unsigned int indexForPointer(const void *p) {
        // 将p的值以二进制的方式解释为uintptr_t（unsigned long）并赋值给addr
        uintptr_t addr = reinterpret_cast<uintptr_t>(p);
        // 哈希函数: 这里 %StripeCount 保证了所有的对象对应的SideTable均在这个8/64长度数组中。
        return ((addr >> 4) ^ (addr >> 9)) % StripeCount;
    }

 public:
    /// 操作符重载
    T& operator[] (const void *p) { 
        return array[indexForPointer(p)].value; /// array中存储的是PaddedT结构其中定义了一个T泛型的变量value
    }
    /**
     通过 SideTable& table = SideTables()[this]; 从SideTables中获取this对象的SideTable
     
     代码中将一个对象传入，由于重载了运算符所以实际的[this]会进入的到这个类中的重载方法array[indexForPointer(p)]里。
     然后通过indexForPointer方法得到的进行强制类型转换，最终得到这个这个hash地址在array中的index。通过index得到的是
     这个hash表中的键值对，最后调用获取value方法得到相应的SideTable（注意这里不是SideTables）
     */
    
    
    const T& operator[] (const void *p) const { 
        return const_cast<StripedMap<T>>(this)[p]; 
    }

    // Shortcuts for StripedMaps of locks.
    // 锁操作
    void lockAll() {
        for (unsigned int i = 0; i < StripeCount; i++) {
            array[i].value.lock();
        }
    }

    void unlockAll() {
        for (unsigned int i = 0; i < StripeCount; i++) {
            array[i].value.unlock();
        }
    }

    void forceResetAll() {
        for (unsigned int i = 0; i < StripeCount; i++) {
            array[i].value.forceReset();
        }
    }

    void defineLockOrder() {
        for (unsigned int i = 1; i < StripeCount; i++) {
            lockdebug_lock_precedes_lock(&array[i-1].value, &array[i].value);
        }
    }

    void precedeLock(const void *newlock) {
        // assumes defineLockOrder is also called
        lockdebug_lock_precedes_lock(&array[StripeCount-1].value, newlock);
    }

    void succeedLock(const void *oldlock) {
        // assumes defineLockOrder is also called
        lockdebug_lock_precedes_lock(oldlock, &array[0].value);
    }

    const void *getLock(int i) {
        if (i < StripeCount) return &array[i].value;
        else return nil;
    }
    
#if DEBUG
    StripedMap() {
        // Verify alignment expectations.
        uintptr_t base = (uintptr_t)&array[0].value;
        uintptr_t delta = (uintptr_t)&array[1].value - base;
        assert(delta % CacheLineSize == 0);
        assert(base % CacheLineSize == 0);
    }
#else
    constexpr StripedMap() {}
#endif
};


// DisguisedPtr<T> acts like pointer type T*, except the 
// stored value is disguised to hide it from tools like `leaks`.
// nil is disguised as itself so zero-filled memory works as expected, 
// which means 0x80..00 is also disguised as itself but we don't care.
// Note that weak_entry_t knows about this encoding.

// DisguisedPtr <T>的行为类似于指针类型T *，除了储值被伪装成对诸如“泄漏”之类的工具隐藏。
// nil本身是伪装的，因此零填充内存可以按预期工作，
// 表示0x80..00本身也被伪装，但我们不在乎。
// 注意，weak_entry_t知道这种编码。

// DisguisedPtr类的定义如下。它对一个指针伪装处理，保存时装箱，调用时拆箱。可不纠结于为什么要将指针伪装，只需要知道DisguisedPtr<T>功能上等价于T*即可。
// DisguisedPtr<T>通过运算使指针隐藏于系统工具（如LEAK工具），同时保持指针的能力，其作用是通过计算把保存的T的指针隐藏起来，实现指针到整数的全射
template <typename T>
class DisguisedPtr {
    uintptr_t value;

    static uintptr_t disguise(T* ptr) { //指针隐藏
        return -(uintptr_t)ptr;
    }

    static T* undisguise(uintptr_t val) { //指针显露
        return (T*)-val;
    }

 public:
    DisguisedPtr() { }
    DisguisedPtr(T* ptr) 
        : value(disguise(ptr)) { }
    DisguisedPtr(const DisguisedPtr<T>& ptr) 
        : value(ptr.value) { }

    DisguisedPtr<T>& operator = (T* rhs) {
        value = disguise(rhs);
        return *this;
    }
    DisguisedPtr<T>& operator = (const DisguisedPtr<T>& rhs) {
        value = rhs.value;
        return *this;
    }

    operator T* () const {
        return undisguise(value);
    }
    T* operator -> () const { 
        return undisguise(value);
    }
    T& operator * () const { 
        return *undisguise(value);
    }
    T& operator [] (size_t i) const {
        return undisguise(value)[i];
    }

    // pointer arithmetic operators omitted 
    // because we don't currently use them anywhere
};

// fixme type id is weird and not identical to objc_object*
static inline bool operator == (DisguisedPtr<objc_object> lhs, id rhs) {
    return lhs == (objc_object *)rhs;
}
static inline bool operator != (DisguisedPtr<objc_object> lhs, id rhs) {
    return lhs != (objc_object *)rhs;
}


// Storage for a thread-safe chained hook function.
// get() returns the value for calling.
// set() installs a new function and returns the old one for chaining.
// More precisely, set() writes the old value to a variable supplied by
// the caller. get() and set() use appropriate barriers so that the
// old value is safely written to the variable before the new value is
// called to use it.
//
// T1: store to old variable; store-release to hook variable
// T2: load-acquire from hook variable; call it; called hook loads old variable

template <typename Fn>
class ChainedHookFunction {
    std::atomic<Fn> hook{nil};

public:
    ChainedHookFunction(Fn f) : hook{f} { };

    Fn get() {
        return hook.load(std::memory_order_acquire);
    }

    void set(Fn newValue, Fn *oldVariable)
    {
        Fn oldValue = hook.load(std::memory_order_relaxed);
        do {
            *oldVariable = oldValue;
        } while (!hook.compare_exchange_weak(oldValue, newValue,
                                             std::memory_order_release,
                                             std::memory_order_relaxed));
    }
};


// Pointer hash function.
// This is not a terrific hash, but it is fast 
// and not outrageously flawed for our purposes.

// Based on principles from http://locklessinc.com/articles/fast_hash/
// and evaluation ideas from http://floodyberry.com/noncryptohashzoo/
#if __LP64__
static inline uint32_t ptr_hash(uint64_t key)
{
    key ^= key >> 4;
    key *= 0x8a970be7488fda55;
    key ^= __builtin_bswap64(key);
    return (uint32_t)key;
}
#else
static inline uint32_t ptr_hash(uint32_t key)
{
    key ^= key >> 4;
    key *= 0x5052acdb;
    key ^= __builtin_bswap32(key);
    return key;
}
#endif

/*
  Higher-quality hash function. This is measurably slower in some workloads.
#if __LP64__
 uint32_t ptr_hash(uint64_t key)
{
    key -= __builtin_bswap64(key);
    key *= 0x8a970be7488fda55;
    key ^= __builtin_bswap64(key);
    key *= 0x8a970be7488fda55;
    key ^= __builtin_bswap64(key);
    return (uint32_t)key;
}
#else
static uint32_t ptr_hash(uint32_t key)
{
    key -= __builtin_bswap32(key);
    key *= 0x5052acdb;
    key ^= __builtin_bswap32(key);
    key *= 0x5052acdb;
    key ^= __builtin_bswap32(key);
    return key;
}
#endif
*/



// Lock declarations
#include "objc-locks.h"

// Inlined parts of objc_object's implementation
#include "objc-object.h"

#endif /* _OBJC_PRIVATE_H_ */

