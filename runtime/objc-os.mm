/*
 * Copyright (c) 2007 Apple Inc.  All Rights Reserved.
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

/***********************************************************************
* objc-os.m
* OS portability layer.
**********************************************************************/

#include "objc-private.h"
#include "objc-loadmethod.h"

#if TARGET_OS_WIN32

#include "objc-runtime-old.h"
#include "objcrt.h"

const fork_unsafe_lock_t fork_unsafe_lock;

int monitor_init(monitor_t *c) 
{
    // fixme error checking
    HANDLE mutex = CreateMutex(NULL, TRUE, NULL);
    while (!c->mutex) {
        // fixme memory barrier here?
        if (0 == InterlockedCompareExchangePointer(&c->mutex, mutex, 0)) {
            // we win - finish construction
            c->waiters = CreateSemaphore(NULL, 0, 0x7fffffff, NULL);
            c->waitersDone = CreateEvent(NULL, FALSE, FALSE, NULL);
            InitializeCriticalSection(&c->waitCountLock);
            c->waitCount = 0;
            c->didBroadcast = 0;
            ReleaseMutex(c->mutex);    
            return 0;
        }
    }

    // someone else allocated the mutex and constructed the monitor
    ReleaseMutex(mutex);
    CloseHandle(mutex);
    return 0;
}

void mutex_init(mutex_t *m)
{
    while (!m->lock) {
        CRITICAL_SECTION *newlock = malloc(sizeof(CRITICAL_SECTION));
        InitializeCriticalSection(newlock);
        // fixme memory barrier here?
        if (0 == InterlockedCompareExchangePointer(&m->lock, newlock, 0)) {
            return;
        }
        // someone else installed their lock first
        DeleteCriticalSection(newlock);
        free(newlock);
    }
}


void recursive_mutex_init(recursive_mutex_t *m)
{
    // fixme error checking
    HANDLE newmutex = CreateMutex(NULL, FALSE, NULL);
    while (!m->mutex) {
        // fixme memory barrier here?
        if (0 == InterlockedCompareExchangePointer(&m->mutex, newmutex, 0)) {
            // we win
            return;
        }
    }
    
    // someone else installed their lock first
    CloseHandle(newmutex);
}


WINBOOL APIENTRY DllMain( HMODULE hModule,
                       DWORD  ul_reason_for_call,
                       LPVOID lpReserved
					 )
{
    switch (ul_reason_for_call) {
    case DLL_PROCESS_ATTACH:
        environ_init();
        tls_init();
        lock_init();
        sel_init(3500);  // old selector heuristic
        exception_init();
        break;

    case DLL_THREAD_ATTACH:
        break;

    case DLL_THREAD_DETACH:
    case DLL_PROCESS_DETACH:
        break;
    }
    return TRUE;
}

OBJC_EXPORT void *_objc_init_image(HMODULE image, const objc_sections *sects)
{
    header_info *hi = malloc(sizeof(header_info));
    size_t count, i;

    hi->mhdr = (const headerType *)image;
    hi->info = sects->iiStart;
    hi->allClassesRealized = NO;
    hi->modules = sects->modStart ? (Module *)((void **)sects->modStart+1) : 0;
    hi->moduleCount = (Module *)sects->modEnd - hi->modules;
    hi->protocols = sects->protoStart ? (struct old_protocol **)((void **)sects->protoStart+1) : 0;
    hi->protocolCount = (struct old_protocol **)sects->protoEnd - hi->protocols;
    hi->imageinfo = NULL;
    hi->imageinfoBytes = 0;
    // hi->imageinfo = sects->iiStart ? (uint8_t *)((void **)sects->iiStart+1) : 0;;
//     hi->imageinfoBytes = (uint8_t *)sects->iiEnd - hi->imageinfo;
    hi->selrefs = sects->selrefsStart ? (SEL *)((void **)sects->selrefsStart+1) : 0;
    hi->selrefCount = (SEL *)sects->selrefsEnd - hi->selrefs;
    hi->clsrefs = sects->clsrefsStart ? (Class *)((void **)sects->clsrefsStart+1) : 0;
    hi->clsrefCount = (Class *)sects->clsrefsEnd - hi->clsrefs;

    count = 0;
    for (i = 0; i < hi->moduleCount; i++) {
        if (hi->modules[i]) count++;
    }
    hi->mod_count = 0;
    hi->mod_ptr = 0;
    if (count > 0) {
        hi->mod_ptr = malloc(count * sizeof(struct objc_module));
        for (i = 0; i < hi->moduleCount; i++) {
            if (hi->modules[i]) memcpy(&hi->mod_ptr[hi->mod_count++], hi->modules[i], sizeof(struct objc_module));
        }
    }
    
    hi->moduleName = malloc(MAX_PATH * sizeof(TCHAR));
    GetModuleFileName((HMODULE)(hi->mhdr), hi->moduleName, MAX_PATH * sizeof(TCHAR));

    appendHeader(hi);

    if (PrintImages) {
        _objc_inform("IMAGES: loading image for %s%s%s%s\n", 
                     hi->fname, 
                     headerIsBundle(hi) ? " (bundle)" : "", 
                     hi->info->isReplacement() ? " (replacement)":"", 
                     hi->info->hasCategoryClassProperties() ? " (has class properties)":"");
    }

    // Count classes. Size various table based on the total.
    int total = 0;
    int unoptimizedTotal = 0;
    {
      if (_getObjc2ClassList(hi, &count)) {
        total += (int)count;
        if (!hi->getInSharedCache()) unoptimizedTotal += count;
      }
    }

    _read_images(&hi, 1, total, unoptimizedTotal);

    return hi;
}

OBJC_EXPORT void _objc_load_image(HMODULE image, header_info *hinfo)
{
    prepare_load_methods(hinfo);
    call_load_methods();
}

OBJC_EXPORT void _objc_unload_image(HMODULE image, header_info *hinfo)
{
    _objc_fatal("image unload not supported");
}


// TARGET_OS_WIN32
#elif TARGET_OS_MAC

#include "objc-file-old.h"
#include "objc-file.h"


/***********************************************************************
* libobjc must never run static destructors. 
* Cover libc's __cxa_atexit with our own definition that runs nothing.
* rdar://21734598  ER: Compiler option to suppress C++ static destructors
**********************************************************************/
extern "C" int __cxa_atexit();
extern "C" int __cxa_atexit() { return 0; }


/***********************************************************************
* bad_magic.
* Return YES if the header has invalid Mach-o magic.
**********************************************************************/
bool bad_magic(const headerType *mhdr)
{
    return (mhdr->magic != MH_MAGIC  &&  mhdr->magic != MH_MAGIC_64  &&  
            mhdr->magic != MH_CIGAM  &&  mhdr->magic != MH_CIGAM_64);
}



/**
 addHeader的作用不仅仅在于返回headerType对应的header_info结构体，其内部调用了appendHeader()将所有已加载的镜像的元素所对应的header_info串联成链表结构，链表首节点为FirstHeader、末尾节点为LastHeader。该链表在后面卸载镜像元素时需要用到。至此完成镜像数据收集工作
*/
static header_info * addHeader(const headerType *mhdr, const char *path, int &totalClasses, int &unoptimizedTotalClasses)
{
    header_info *hi;

    if (bad_magic(mhdr)) return NULL; // 校验magic，忽略

    bool inSharedCache = false;

    // Look for hinfo from the dyld shared cache.
    hi = preoptimizedHinfoForHeader(mhdr); // 预处理优化相关，忽略
    if (hi) {
        // Found an hinfo in the dyld shared cache.
        // Weed out duplicates.  清除重复项
        
        // 在 dyld shared cache 中查找到mhdr，不允许重复加载
        if (hi->isLoaded()) {
            return NULL;
        }

        inSharedCache = true;

        // Initialize fields not set by the shared cache
        // hi->next is set by appendHeader
        hi->setLoaded(true);

        if (PrintPreopt) {
            _objc_inform("PREOPTIMIZATION: honoring preoptimized header info at %p for %s", hi, hi->fname());
        }

#if !__OBJC2__
        _objc_fatal("shouldn't be here");
#endif
#if DEBUG
        // Verify image_info
        size_t info_size = 0;
        const objc_image_info *image_info = _getObjcImageInfo(mhdr,&info_size);
        assert(image_info == hi->info());
#endif
    }
    else 
    {
        // Didn't find an hinfo in the dyld shared cache.
        // 在 dyld shared cache 中未查找到mhdr

        // 1.不允许重复添加header_info到链表。getNext()用于获取下一个header_info节点
        // Weed out duplicates 清除重复项
        for (hi = FirstHeader; hi; hi = hi->getNext()) {
            /// 如果链表中已经有了该hi就返回NULL
            if (mhdr == hi->mhdr()) return NULL;
        }

        // Locate the __OBJC segment
        size_t info_size = 0;
        unsigned long seg_size;
        
        // 获取镜像信息
        const objc_image_info *image_info = _getObjcImageInfo(mhdr,&info_size);
    
        // 获取__OBJC数据段
        const uint8_t *objc_segment = getsegmentdata(mhdr,SEG_OBJC,&seg_size);
        
        // 2.若__OBJC数据段、镜像信息为空，则直接返回NULL
        if (!objc_segment  &&  !image_info) return NULL;

        // Allocate a header_info entry.
        // Note we also allocate space for a single header_info_rw in the
        // rw_data[] inside header_info.
        
        // 3.分配内存header_info结构体需要占用的内存空间，为header_info结构体占用字节数、header_info_rw 结构体的占用字节数之和，因为header_info的rw_data数组仅包含1个header_info_rw元素
        hi = (header_info *)calloc(sizeof(header_info) + sizeof(header_info_rw), 1);

        // Set up the new header_info entry.
         // 4.设置 header_info 中用于定位镜像头信息的 mhdr_offset
        hi->setmhdr(mhdr);
#if !__OBJC2__
        // mhdr must already be set
        hi->mod_count = 0;
        hi->mod_ptr = _getObjcModules(hi, &hi->mod_count);
#endif
        // Install a placeholder image_info if absent to simplify code elsewhere
        
        // 5. 设置 header_info 中用于定位镜像信息的 info_offset
        static const objc_image_info emptyInfo = {0, 0};
        hi->setinfo(image_info ?: &emptyInfo);
        // 6. 设置镜像isLoaded为YES，表示镜像已加载
        hi->setLoaded(true);
        // 7. 设置镜像allClassesRealized为NO，表示镜像中定义的类尚未开始class realizing
        hi->setAllClassesRealized(NO);
    }

#if __OBJC2__
    {
        // 8. 统计镜像中包含的类的总数
        size_t count = 0;
        if (_getObjc2ClassList(hi, &count)) {
            totalClasses += (int)count;
            if (!inSharedCache) unoptimizedTotalClasses += count; /// 没在共享缓存中就属于没优化
        }
    }
#endif
    
    // 9. 将构建的header_info添加到全局的已加载镜像链表，添加到链表末尾
    appendHeader(hi); /// Add a newly-constructed header_info to the list
    
    return hi;
}


/***********************************************************************
* linksToLibrary
* Returns true if the image links directly to a dylib whose install name 
* is exactly the given name.
**********************************************************************/
bool
linksToLibrary(const header_info *hi, const char *name)
{
    const struct dylib_command *cmd;
    unsigned long i;
    
    cmd = (const struct dylib_command *) (hi->mhdr() + 1);
    for (i = 0; i < hi->mhdr()->ncmds; i++) {
        if (cmd->cmd == LC_LOAD_DYLIB  ||  cmd->cmd == LC_LOAD_UPWARD_DYLIB  ||
            cmd->cmd == LC_LOAD_WEAK_DYLIB  ||  cmd->cmd == LC_REEXPORT_DYLIB)
        {
            const char *dylib = cmd->dylib.name.offset + (const char *)cmd;
            if (0 == strcmp(dylib, name)) return true;
        }
        cmd = (const struct dylib_command *)((char *)cmd + cmd->cmdsize);
    }

    return false;
}


#if SUPPORT_GC_COMPAT

/***********************************************************************
* shouldRejectGCApp
* Return YES if the executable requires GC.
**********************************************************************/
static bool shouldRejectGCApp(const header_info *hi)
{
    assert(hi->mhdr()->filetype == MH_EXECUTE);

    if (!hi->info()->supportsGC()) {
        // App does not use GC. Don't reject it.
        return NO;
    }
        
    // Exception: Trivial AppleScriptObjC apps can run without GC.
    // 1. executable defines no classes
    // 2. executable references NSBundle only
    // 3. executable links to AppleScriptObjC.framework
    // Note that objc_appRequiresGC() also knows about this.
    size_t classcount = 0;
    size_t refcount = 0;
#if __OBJC2__
    _getObjc2ClassList(hi, &classcount);
    _getObjc2ClassRefs(hi, &refcount);
#else
    if (hi->mod_count == 0  ||  (hi->mod_count == 1 && !hi->mod_ptr[0].symtab)) classcount = 0;
    else classcount = 1;
    _getObjcClassRefs(hi, &refcount);
#endif
    if (classcount == 0  &&  refcount == 1  &&  
        linksToLibrary(hi, "/System/Library/Frameworks"
                       "/AppleScriptObjC.framework/Versions/A"
                       "/AppleScriptObjC"))
    {
        // It's AppleScriptObjC. Don't reject it.
        return NO;
    } 
    else {
        // GC and not trivial AppleScriptObjC. Reject it.
        return YES;
    }
}


/***********************************************************************
* rejectGCImage
* Halt if an image requires GC.
* Testing of the main executable should use rejectGCApp() instead.
**********************************************************************/
static bool shouldRejectGCImage(const headerType *mhdr)
{
    assert(mhdr->filetype != MH_EXECUTE);

    objc_image_info *image_info;
    size_t size;
    
#if !__OBJC2__
    unsigned long seg_size;
    // 32-bit: __OBJC seg but no image_info means no GC support
    if (!getsegmentdata(mhdr, "__OBJC", &seg_size)) {
        // Not objc, therefore not GC. Don't reject it.
        return NO;
    }
    image_info = _getObjcImageInfo(mhdr, &size);
    if (!image_info) {
        // No image_info, therefore not GC. Don't reject it.
        return NO;
    }
#else
    // 64-bit: no image_info means no objc at all
    image_info = _getObjcImageInfo(mhdr, &size);
    if (!image_info) {
        // Not objc, therefore not GC. Don't reject it.
        return NO;
    }
#endif

    return image_info->requiresGC();
}

// SUPPORT_GC_COMPAT
#endif


/***********************************************************************
* map_images_nolock
* Process the given images which are being mapped in by dyld.
* All class registration and fixups are performed (or deferred pending
* discovery of missing superclasses etc), and +load methods are called.
* 所有类的注册和修复会在该函数中执行。+load方法将会被调用
*
* info[] is in bottom-up order i.e. libobjc will be earlier in the 
* array than any library that links to libobjc.
*
* Locking: loadMethodLock(old) or runtimeLock(new) acquired by map_images.
**********************************************************************/
#if __OBJC2__
#include "objc-file.h"
#else
#include "objc-file-old.h"
#endif

void 
map_images_nolock(unsigned mhCount, const char * const mhPaths[],
                  const struct mach_header * const mhdrs[])
{
    static bool firstTime = YES;
    header_info *hList[mhCount]; /// header_info对应mach-o文件header的结构体
    uint32_t hCount;
    size_t selrefCount = 0;

    // Perform first-time initialization if necessary.
    // This function is called before ordinary library initializers. 
    // fixme defer initialization until an objc-using image is found?
    if (firstTime) {
        /// 预优化环境初始化
        preopt_init();
    }

    if (PrintImages) { /// 由外部环境变量决定
        _objc_inform("IMAGES: processing %u newly-mapped images...\n", mhCount);
    }


    // Find all images with Objective-C metadata.
    hCount = 0; // 所有 包含Objective-C元素的镜像

    // Count classes. Size various table based on the total.
    int totalClasses = 0; // 类的总数
    int unoptimizedTotalClasses = 0; // 未优化的类的总数
    {
        // 遍历镜像中所有元素信息，逐一转换成header_info，并添加到hList
        uint32_t i = mhCount;
        while (i--) {
            
            /// mhdr对应mach_header_64类型
            const headerType *mhdr = (const headerType *)mhdrs[i]; /// mach-o header信息
            
            // （核心逻辑1）addHeader内部逻辑将headerType转化为header_info类型并添加到一张全局的链表中，返回header_info类型的转化结果
            //  通过addHeader(...)汇总镜像中的 Objective-C 元素，生成head_info的数组，作为下一步的输入
            auto hi = addHeader(mhdr, mhPaths[i], totalClasses, unoptimizedTotalClasses);
            if (!hi) {
                // no objc data in this entry
                continue;
            }
            
            if (mhdr->filetype == MH_EXECUTE) {
                // 一些可执行文件的初始化代码
                // Size some data structures based on main executable's size
#if __OBJC2__
                size_t count;
                _getObjc2SelectorRefs(hi, &count);
                selrefCount += count;
                _getObjc2MessageRefs(hi, &count);
                selrefCount += count;
#else
                _getObjcSelectorRefs(hi, &selrefCount);
#endif
                // 忽略GC兼容检查代码
#if SUPPORT_GC_COMPAT
                // Halt if this is a GC app.
                if (shouldRejectGCApp(hi)) {
                    _objc_fatal_with_reason
                        (OBJC_EXIT_REASON_GC_NOT_SUPPORTED, 
                         OS_REASON_FLAG_CONSISTENT_FAILURE, 
                         "Objective-C garbage collection " 
                         "is no longer supported.");
                }
#endif
            }
            
            hList[hCount++] = hi; /// header-info存放到hList数组中
            
            if (PrintImages) { /// 对应的环境变量 OBJC_PRINT_IMAGES
                _objc_inform("IMAGES: loading image for %s%s%s%s%s\n", 
                             hi->fname(),
                             mhdr->filetype == MH_BUNDLE ? " (bundle)" : "",
                             hi->info()->isReplacement() ? " (replacement)" : "",
                             hi->info()->hasCategoryClassProperties() ? " (has class properties)" : "",
                             hi->info()->optimizedByDyld()?" (preoptimized)":"");
            }
        }
    }

    // Perform one-time runtime initialization that must be deferred until 
    // the executable itself is found. This needs to be done before 
    // further initialization.  执行runtime一次初始化，必须推迟到找到可执行文件本身。这些操作需要在进一步初始化之前完成
    // (The executable may not be present in this infoList if the 
    // executable does not contain Objective-C code but Objective-C 
    // is dynamically loaded later.
    
    
    if (firstTime) {
        
        // 初始化一些最基本的选择器，如alloc、dealloc、initialize、load等等
        sel_init(selrefCount); // Initialize selector tables and register selectors used internally.
        
        // 初始化AutoreleasePool和SideTable
        arr_init();
        
// 忽略GC兼容检查代码
#if SUPPORT_GC_COMPAT
        // Reject any GC images linked to the main executable.
        // We already rejected the app itself above.
        // Images loaded after launch will be rejected by dyld.

        for (uint32_t i = 0; i < hCount; i++) {
            auto hi = hList[i];
            auto mh = hi->mhdr();
            if (mh->filetype != MH_EXECUTE  &&  shouldRejectGCImage(mh)) {
                _objc_fatal_with_reason
                    (OBJC_EXIT_REASON_GC_NOT_SUPPORTED, 
                     OS_REASON_FLAG_CONSISTENT_FAILURE, 
                     "%s requires Objective-C garbage collection "
                     "which is no longer supported.", hi->fname());
            }
        }
#endif

// 忽略针对MAC OS X平台的initialize的fork安全检查代码（Fixme: 不懂）
#if TARGET_OS_OSX
        // Disable +initialize fork safety if the app is too old (< 10.13).
        // Disable +initialize fork safety if the app has a
        //   __DATA,__objc_fork_ok section.

        if (dyld_get_program_sdk_version() < DYLD_MACOSX_VERSION_10_13) {
            DisableInitializeForkSafety = true;
            if (PrintInitializing) {
                _objc_inform("INITIALIZE: disabling +initialize fork "
                             "safety enforcement because the app is "
                             "too old (SDK version " SDK_FORMAT ")",
                             FORMAT_SDK(dyld_get_program_sdk_version()));
            }
        }

        for (uint32_t i = 0; i < hCount; i++) {
            auto hi = hList[i];
            auto mh = hi->mhdr();
            if (mh->filetype != MH_EXECUTE) continue;
            unsigned long size;
            if (getsectiondata(hi->mhdr(), "__DATA", "__objc_fork_ok", &size)) {
                DisableInitializeForkSafety = true;
                if (PrintInitializing) {
                    _objc_inform("INITIALIZE: disabling +initialize fork "
                                 "safety enforcement because the app has "
                                 "a __DATA,__objc_fork_ok section");
                }
            }
            break;  // assume only one MH_EXECUTE image
        }
#endif

    }

    if (hCount > 0) {
         // （核心逻辑2）加载二进制文件中的元素，包括类、分类、协议等等
        _read_images(hList, hCount, totalClasses, unoptimizedTotalClasses);
    }

    firstTime = NO;
}


/***********************************************************************
* unmap_image_nolock
* Process the given image which is about to be unmapped by dyld.
* mh is mach_header instead of headerType because that's what 
*   dyld_priv.h says even for 64-bit.
* 
* Locking: loadMethodLock(both) and runtimeLock(new) acquired by unmap_image.
**********************************************************************/
void 
unmap_image_nolock(const struct mach_header *mh)
{
    if (PrintImages) {
        _objc_inform("IMAGES: processing 1 newly-unmapped image...\n");
    }

    header_info *hi;
    
    // Find the runtime's header_info struct for the image
    for (hi = FirstHeader; hi != NULL; hi = hi->getNext()) {
        if (hi->mhdr() == (const headerType *)mh) {
            break;
        }
    }

    if (!hi) return;

    if (PrintImages) {
        _objc_inform("IMAGES: unloading image for %s%s%s\n", 
                     hi->fname(),
                     hi->mhdr()->filetype == MH_BUNDLE ? " (bundle)" : "",
                     hi->info()->isReplacement() ? " (replacement)" : "");
    }

    _unload_image(hi);

    // Remove header_info from header list
    removeHeader(hi);
    free(hi);
}


/***********************************************************************
* static_init
* Run C++ static constructor functions.
* libc calls _objc_init() before dyld would call our static constructors, 
* so we have to do it ourselves.
**********************************************************************/
static void static_init()
{
    size_t count;
    auto inits = getLibobjcInitializers(&_mh_dylib_header, &count);
    for (size_t i = 0; i < count; i++) {
        inits[i]();
    }
}


/***********************************************************************
* _objc_atfork_prepare
* _objc_atfork_parent
* _objc_atfork_child
* Allow ObjC to be used between fork() and exec().
* libc requires this because it has fork-safe functions that use os_objects.
*
* _objc_atfork_prepare() acquires all locks.
* _objc_atfork_parent() releases the locks again.
* _objc_atfork_child() forcibly resets the locks.
**********************************************************************/

// Declare lock ordering.
#if LOCKDEBUG
__attribute__((constructor))
static void defineLockOrder()
{
    // Every lock precedes crashlog_lock
    // on the assumption that fatal errors could be anywhere.
    lockdebug_lock_precedes_lock(&loadMethodLock, &crashlog_lock);
    lockdebug_lock_precedes_lock(&classInitLock, &crashlog_lock);
#if __OBJC2__
    lockdebug_lock_precedes_lock(&runtimeLock, &crashlog_lock);
    lockdebug_lock_precedes_lock(&DemangleCacheLock, &crashlog_lock);
#else
    lockdebug_lock_precedes_lock(&classLock, &crashlog_lock);
    lockdebug_lock_precedes_lock(&methodListLock, &crashlog_lock);
    lockdebug_lock_precedes_lock(&NXUniqueStringLock, &crashlog_lock);
    lockdebug_lock_precedes_lock(&impLock, &crashlog_lock);
#endif
    lockdebug_lock_precedes_lock(&selLock, &crashlog_lock);
    lockdebug_lock_precedes_lock(&cacheUpdateLock, &crashlog_lock);
    lockdebug_lock_precedes_lock(&objcMsgLogLock, &crashlog_lock);
    lockdebug_lock_precedes_lock(&AltHandlerDebugLock, &crashlog_lock);
    lockdebug_lock_precedes_lock(&AssociationsManagerLock, &crashlog_lock);
    SideTableLocksPrecedeLock(&crashlog_lock);
    PropertyLocks.precedeLock(&crashlog_lock);
    StructLocks.precedeLock(&crashlog_lock);
    CppObjectLocks.precedeLock(&crashlog_lock);

    // loadMethodLock precedes everything
    // because it is held while +load methods run
    lockdebug_lock_precedes_lock(&loadMethodLock, &classInitLock);
#if __OBJC2__
    lockdebug_lock_precedes_lock(&loadMethodLock, &runtimeLock);
    lockdebug_lock_precedes_lock(&loadMethodLock, &DemangleCacheLock);
#else
    lockdebug_lock_precedes_lock(&loadMethodLock, &methodListLock);
    lockdebug_lock_precedes_lock(&loadMethodLock, &classLock);
    lockdebug_lock_precedes_lock(&loadMethodLock, &NXUniqueStringLock);
    lockdebug_lock_precedes_lock(&loadMethodLock, &impLock);
#endif
    lockdebug_lock_precedes_lock(&loadMethodLock, &selLock);
    lockdebug_lock_precedes_lock(&loadMethodLock, &cacheUpdateLock);
    lockdebug_lock_precedes_lock(&loadMethodLock, &objcMsgLogLock);
    lockdebug_lock_precedes_lock(&loadMethodLock, &AltHandlerDebugLock);
    lockdebug_lock_precedes_lock(&loadMethodLock, &AssociationsManagerLock);
    SideTableLocksSucceedLock(&loadMethodLock);
    PropertyLocks.succeedLock(&loadMethodLock);
    StructLocks.succeedLock(&loadMethodLock);
    CppObjectLocks.succeedLock(&loadMethodLock);

    // PropertyLocks and CppObjectLocks and AssociationManagerLock 
    // precede everything because they are held while objc_retain() 
    // or C++ copy are called.
    // (StructLocks do not precede everything because it calls memmove only.)
    auto PropertyAndCppObjectAndAssocLocksPrecedeLock = [&](const void *lock) {
        PropertyLocks.precedeLock(lock);
        CppObjectLocks.precedeLock(lock);
        lockdebug_lock_precedes_lock(&AssociationsManagerLock, lock);
    };
#if __OBJC2__
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&runtimeLock);
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&DemangleCacheLock);
#else
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&methodListLock);
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&classLock);
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&NXUniqueStringLock);
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&impLock);
#endif
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&classInitLock);
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&selLock);
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&cacheUpdateLock);
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&objcMsgLogLock);
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&AltHandlerDebugLock);

    SideTableLocksSucceedLocks(PropertyLocks);
    SideTableLocksSucceedLocks(CppObjectLocks);
    SideTableLocksSucceedLock(&AssociationsManagerLock);

    PropertyLocks.precedeLock(&AssociationsManagerLock);
    CppObjectLocks.precedeLock(&AssociationsManagerLock);
    
#if __OBJC2__
    lockdebug_lock_precedes_lock(&classInitLock, &runtimeLock);
#endif

#if __OBJC2__
    // Runtime operations may occur inside SideTable locks
    // (such as storeWeak calling getMethodImplementation)
    SideTableLocksPrecedeLock(&runtimeLock);
    SideTableLocksPrecedeLock(&classInitLock);
    // Some operations may occur inside runtimeLock.
    lockdebug_lock_precedes_lock(&runtimeLock, &selLock);
    lockdebug_lock_precedes_lock(&runtimeLock, &cacheUpdateLock);
    lockdebug_lock_precedes_lock(&runtimeLock, &DemangleCacheLock);
#else
    // Runtime operations may occur inside SideTable locks
    // (such as storeWeak calling getMethodImplementation)
    SideTableLocksPrecedeLock(&methodListLock);
    SideTableLocksPrecedeLock(&classInitLock);
    // Method lookup and fixup.
    lockdebug_lock_precedes_lock(&methodListLock, &classLock);
    lockdebug_lock_precedes_lock(&methodListLock, &selLock);
    lockdebug_lock_precedes_lock(&methodListLock, &cacheUpdateLock);
    lockdebug_lock_precedes_lock(&methodListLock, &impLock);
    lockdebug_lock_precedes_lock(&classLock, &selLock);
    lockdebug_lock_precedes_lock(&classLock, &cacheUpdateLock);
#endif

    // Striped locks use address order internally.
    SideTableDefineLockOrder();
    PropertyLocks.defineLockOrder();
    StructLocks.defineLockOrder();
    CppObjectLocks.defineLockOrder();
}
// LOCKDEBUG
#endif

static bool ForkIsMultithreaded;
void _objc_atfork_prepare()
{
    // Save threaded-ness for the child's use.
    ForkIsMultithreaded = pthread_is_threaded_np();

    lockdebug_assert_no_locks_locked();
    lockdebug_setInForkPrepare(true);

    loadMethodLock.lock();
    PropertyLocks.lockAll();
    CppObjectLocks.lockAll();
    AssociationsManagerLock.lock();
    SideTableLockAll();
    classInitLock.enter();
#if __OBJC2__
    runtimeLock.lock();
    DemangleCacheLock.lock();
#else
    methodListLock.lock();
    classLock.lock();
    NXUniqueStringLock.lock();
    impLock.lock();
#endif
    selLock.lock();
    cacheUpdateLock.lock();
    objcMsgLogLock.lock();
    AltHandlerDebugLock.lock();
    StructLocks.lockAll();
    crashlog_lock.lock();

    lockdebug_assert_all_locks_locked();
    lockdebug_setInForkPrepare(false);
}

void _objc_atfork_parent()
{
    lockdebug_assert_all_locks_locked();

    CppObjectLocks.unlockAll();
    StructLocks.unlockAll();
    PropertyLocks.unlockAll();
    AssociationsManagerLock.unlock();
    AltHandlerDebugLock.unlock();
    objcMsgLogLock.unlock();
    crashlog_lock.unlock();
    loadMethodLock.unlock();
    cacheUpdateLock.unlock();
    selLock.unlock();
    SideTableUnlockAll();
#if __OBJC2__
    DemangleCacheLock.unlock();
    runtimeLock.unlock();
#else
    impLock.unlock();
    NXUniqueStringLock.unlock();
    methodListLock.unlock();
    classLock.unlock();
#endif
    classInitLock.leave();

    lockdebug_assert_no_locks_locked();
}

void _objc_atfork_child()
{
    // Turn on +initialize fork safety enforcement if applicable.
    if (ForkIsMultithreaded  &&  !DisableInitializeForkSafety) {
        MultithreadedForkChild = true;
    }

    lockdebug_assert_all_locks_locked();

    CppObjectLocks.forceResetAll();
    StructLocks.forceResetAll();
    PropertyLocks.forceResetAll();
    AssociationsManagerLock.forceReset();
    AltHandlerDebugLock.forceReset();
    objcMsgLogLock.forceReset();
    crashlog_lock.forceReset();
    loadMethodLock.forceReset();
    cacheUpdateLock.forceReset();
    selLock.forceReset();
    SideTableForceResetAll();
#if __OBJC2__
    DemangleCacheLock.forceReset();
    runtimeLock.forceReset();
#else
    impLock.forceReset();
    NXUniqueStringLock.forceReset();
    methodListLock.forceReset();
    classLock.forceReset();
#endif
    classInitLock.forceReset();

    lockdebug_assert_no_locks_locked();
}


/***********************************************************************
* _objc_init
* Bootstrap initialization. Registers our image notifier with dyld.
* Called by libSystem BEFORE library initialization time
**********************************************************************/

// 运行时环境的启动总入口
void _objc_init(void)
{
    // 重要：_objc_init全局只调用一次
    static bool initialized = false;
    if (initialized) return;
    initialized = true;
    
    // fixme defer initialization until an objc-using image is found?
    // 运行环境初始化系列操作
    environ_init();
    tls_init();
    static_init();
    lock_init();
    exception_init();

    /****************************************
     哪些名词指的是Mach-o:
     xecutable 可执行文件
     Dylib 动态库
     Bundle 无法被连接的动态库，只能通过dlopen()加载
     Image 指的是Executable，Dylib或者Bundle的一种，文中会多次使用Image这个名词。
     Framework 动态库(可以是静态库)和对应的头文件和资源文件的集合

     在 Clang 编译 Objective-C 源文件时，需要先将 Objective-C 代码转化为 C 语言代码，然后编译得到目标文件（object），最后将目标文件链接为二进制文件（binary）。二进制文件表现为应用或框架、类库等。操作系统通过dyld提供的 API 启动或加载二进制文件。大致过程是：首先通过open(...)函数打开二进制文件；然后通过mmap(...)内存映射函数，将二进制文件中的目标文件映射到内存空间，因此目标文件也可以称为镜像文件，镜像文件所映射的内存区域则为镜像（image）；最后进行镜像绑定、依赖初始化等其他操作。
     
     
     
     Objective-C 体系初始化:
     面向对象的 Objective-C 体系的总加载入口在objc-os.mm文件中的void _objc_init(void)。操作系统执行了_objc_init()后，才能开始加载 Objective-C 编写的应用。

     void _objc_init(void)用于初始化 runtime 环境，并注册三个回调 以监听dyld加载镜像的两个状态、以及卸载镜像动作。
     开头的三行代码说明该函数只被执行一次。操作系统调用dyld的 API 加载（dyld开源代码）二进制文件并完成内存映射后，一旦镜像切换到指定状态 或者 监听到镜像卸载动作，则会触发_objc_init中所注册的相应的回调函数：

        1. 镜像切换到dyld_image_state_bound（镜像完成绑定）时，触发map_images(...)回调函数，将镜像中定义的 Objective-C 元数据（类、分类、协议等等）加载到 runtime；

        2. 镜像加载切换到dyld_image_state_dependents_initialized（镜像的依赖库完成初始化）时，触发load_images (...)回调函数，执行镜像中的 Objective-C 元素初始化操作，主要是执行类和分类的load方法；

        3.监测到卸载镜像动作时，触发unmap_image (...)回调函数，将属于该镜像的元素从 runtime 系统记录的已加载 Objective-C 元素中移除。

     ****************************************/
    
    //
     // Note: only for use by objc runtime
     // Register handlers to be called when objc images are mapped, unmapped, and initialized.
     // Dyld will call back the "mapped" function with an array of images that contain an objc-image-info section.
     // Those images that are dylibs will have the ref-counts automatically bumped, so objc will no longer need to
     // call dlopen() on them to keep them from being unloaded.  During the call to _dyld_objc_notify_register(),
     // dyld will call the "mapped" function with already loaded objc images.  During any later dlopen() call,
     // dyld will also call the "mapped" function.  Dyld will call the "init" function when dyld would be called
     // initializers in that image.  This is when objc calls any +load methods in that image.
    
    
    // 监听镜像加载卸载，注册回调
    _dyld_objc_notify_register(&map_images, load_images, unmap_image);
    
    
    /**
     总结
        1.应用加载的本质是加载应用沙盒中的可执行文件（也是目标文件、镜像文件），镜像文件可以映射到内存空间生成镜像。
          镜像中包含了头信息、加载命令、数据区，镜像中定义的 Objective-C 元素的元信息主要保存在__DATA数据段、__CONST_DATA数据段中。
          例如__objc_classlist保存镜像中定义的所有类、__objc_catlist保存镜像中定义的所有分类；

        2.生成镜像后，触发map_images回调读取镜像中定义的 Objective-C 元素的元信息，
          主要包括发现类、发现协议、认识类、将分类中的方法添加到类、元类的class_rw_t的方法列表中；

        3. 完成镜像绑定后，触发load_images收集需要调用的类及分类的load方法，
          其优先级是静态加载的父类>静态加载的子类>静态加载的分类>动态加载的父类>动态加载的子类>动态加载的分类；
     */
}


/***********************************************************************
* _headerForAddress.
* addr can be a class or a category
**********************************************************************/
static const header_info *_headerForAddress(void *addr)
{
#if __OBJC2__
    const char *segnames[] = { "__DATA", "__DATA_CONST", "__DATA_DIRTY" };
#else
    const char *segnames[] = { "__OBJC" };
#endif
    header_info *hi;

    for (hi = FirstHeader; hi != NULL; hi = hi->getNext()) {
        for (size_t i = 0; i < sizeof(segnames)/sizeof(segnames[0]); i++) {
            unsigned long seg_size;            
            uint8_t *seg = getsegmentdata(hi->mhdr(), segnames[i], &seg_size);
            if (!seg) continue;
            
            // Is the class in this header?
            if ((uint8_t *)addr >= seg  &&  (uint8_t *)addr < seg + seg_size) {
                return hi;
            }
        }
    }

    // Not found
    return 0;
}


/***********************************************************************
* _headerForClass
* Return the image header containing this class, or NULL.
* Returns NULL on runtime-constructed classes, and the NSCF classes.
**********************************************************************/
const header_info *_headerForClass(Class cls)
{
    return _headerForAddress(cls);
}


/**********************************************************************
* secure_open
* Securely open a file from a world-writable directory (like /tmp)
* If the file does not exist, it will be atomically created with mode 0600
* If the file exists, it must be, and remain after opening: 
*   1. a regular file (in particular, not a symlink)
*   2. owned by euid
*   3. permissions 0600
*   4. link count == 1
* Returns a file descriptor or -1. Errno may or may not be set on error.
**********************************************************************/
int secure_open(const char *filename, int flags, uid_t euid)
{
    struct stat fs, ls;
    int fd = -1;
    bool truncate = NO;
    bool create = NO;

    if (flags & O_TRUNC) {
        // Don't truncate the file until after it is open and verified.
        truncate = YES;
        flags &= ~O_TRUNC;
    }
    if (flags & O_CREAT) {
        // Don't create except when we're ready for it
        create = YES;
        flags &= ~O_CREAT;
        flags &= ~O_EXCL;
    }

    if (lstat(filename, &ls) < 0) {
        if (errno == ENOENT  &&  create) {
            // No such file - create it
            fd = open(filename, flags | O_CREAT | O_EXCL, 0600);
            if (fd >= 0) {
                // File was created successfully.
                // New file does not need to be truncated.
                return fd;
            } else {
                // File creation failed.
                return -1;
            }
        } else {
            // lstat failed, or user doesn't want to create the file
            return -1;
        }
    } else {
        // lstat succeeded - verify attributes and open
        if (S_ISREG(ls.st_mode)  &&  // regular file?
            ls.st_nlink == 1  &&     // link count == 1?
            ls.st_uid == euid  &&    // owned by euid?
            (ls.st_mode & ALLPERMS) == (S_IRUSR | S_IWUSR))  // mode 0600?
        {
            // Attributes look ok - open it and check attributes again
            fd = open(filename, flags, 0000);
            if (fd >= 0) {
                // File is open - double-check attributes
                if (0 == fstat(fd, &fs)  &&  
                    fs.st_nlink == ls.st_nlink  &&  // link count == 1?
                    fs.st_uid == ls.st_uid  &&      // owned by euid?
                    fs.st_mode == ls.st_mode  &&    // regular file, 0600?
                    fs.st_ino == ls.st_ino  &&      // same inode as before?
                    fs.st_dev == ls.st_dev)         // same device as before?
                {
                    // File is open and OK
                    if (truncate) ftruncate(fd, 0);
                    return fd;
                } else {
                    // Opened file looks funny - close it
                    close(fd);
                    return -1;
                }
            } else {
                // File didn't open
                return -1;
            }
        } else {
            // Unopened file looks funny - don't open it
            return -1;
        }
    }
}


#if TARGET_OS_IPHONE

const char *__crashreporter_info__ = NULL;

const char *CRSetCrashLogMessage(const char *msg)
{
    __crashreporter_info__ = msg;
    return msg;
}
const char *CRGetCrashLogMessage(void)
{
    return __crashreporter_info__;
}

#endif

// TARGET_OS_MAC
#else


#error unknown OS


#endif
