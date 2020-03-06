/*
 * Copyright (c) 2004-2006 Apple Inc.  All Rights Reserved.
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
* objc-loadmethod.m
* Support for +load methods.
**********************************************************************/

#include "objc-loadmethod.h"
#include "objc-private.h"

typedef void(*load_method_t)(id, SEL);

struct loadable_class {
    Class cls;  // may be nil
    IMP method;
};

struct loadable_category {
    Category cat;  // may be nil
    IMP method;
};


// List of classes that need +load called (pending superclass +load)
// This list always has superclasses first because of the way it is constructed

// 数组容器，记录包含load方法的所有类的信息
static struct loadable_class *loadable_classes = nil;
//数组内存中存在冗余空间，用loadable_classes_used实际保存的单元数量
static int loadable_classes_used = 0;
//数组内存中存在冗余空间，因此用loadable_classes_allocated记录分配的单元数量
static int loadable_classes_allocated = 0;

// List of categories that need +load called (pending parent class +load)
// 数组容器，记录包含load方法的所有分类的信息
static struct loadable_category *loadable_categories = nil;
static int loadable_categories_used = 0;
static int loadable_categories_allocated = 0;


/***********************************************************************
* add_class_to_loadable_list
* Class cls has just become connected. Schedule it for +load if
* it implements a +load method.
**********************************************************************/
void add_class_to_loadable_list(Class cls)
{
    IMP method;

    loadMethodLock.assertLocked();

    method = cls->getLoadMethod();
    if (!method) return;  // Don't bother if cls has no +load method
    
    if (PrintLoading) {
        _objc_inform("LOAD: class '%s' scheduled for +load", 
                     cls->nameForLogging());
    }
    /**
     loadable_classes_used记录loadable_classes实际保存的loadable_class结构体数量
     loadable_classes_allocated记录为数组分配的用于保存loadable_class结构体的内存单元数量
     */
    
    // loadable_classes数组扩容，因此loadable_classes数组中是存在冗余空间的，这是loadable_classes_allocated存在原因
    if (loadable_classes_used == loadable_classes_allocated) {
        loadable_classes_allocated = loadable_classes_allocated*2 + 16;
        loadable_classes = (struct loadable_class *)
            realloc(loadable_classes,
                              loadable_classes_allocated *
                              sizeof(struct loadable_class));
    }
    
    loadable_classes[loadable_classes_used].cls = cls;
    loadable_classes[loadable_classes_used].method = method;
    loadable_classes_used++;
}


/***********************************************************************
* add_category_to_loadable_list
* Category cat's parent class exists and the category has been attached
* to its class. Schedule this category for +load after its parent class
* becomes connected and has its own +load method called.
**********************************************************************/

// ------- 将分类类添加到loadable_categories数组 ------- //
void add_category_to_loadable_list(Category cat)
{
    IMP method;

    loadMethodLock.assertLocked();

    method = _category_getLoadMethod(cat);

    // Don't bother if cat has no +load method
    if (!method) return;

    if (PrintLoading) {
        _objc_inform("LOAD: category '%s(%s)' scheduled for +load", 
                     _category_getClassName(cat), _category_getName(cat));
    }
    
    // loadable_categories数组扩容
    if (loadable_categories_used == loadable_categories_allocated) {
        loadable_categories_allocated = loadable_categories_allocated*2 + 16;
        loadable_categories = (struct loadable_category *)
            realloc(loadable_categories,
                              loadable_categories_allocated *
                              sizeof(struct loadable_category));
    }

    loadable_categories[loadable_categories_used].cat = cat;
    loadable_categories[loadable_categories_used].method = method;
    loadable_categories_used++;
}


/***********************************************************************
* remove_class_from_loadable_list
* Class cls may have been loadable before, but it is now no longer 
* loadable (because its image is being unmapped). 
**********************************************************************/
void remove_class_from_loadable_list(Class cls)
{
    loadMethodLock.assertLocked();

    if (loadable_classes) {
        int i;
        for (i = 0; i < loadable_classes_used; i++) {
            if (loadable_classes[i].cls == cls) {
                loadable_classes[i].cls = nil;
                if (PrintLoading) {
                    _objc_inform("LOAD: class '%s' unscheduled for +load", 
                                 cls->nameForLogging());
                }
                return;
            }
        }
    }
}


/***********************************************************************
* remove_category_from_loadable_list
* Category cat may have been loadable before, but it is now no longer 
* loadable (because its image is being unmapped). 
**********************************************************************/
void remove_category_from_loadable_list(Category cat)
{
    loadMethodLock.assertLocked();

    if (loadable_categories) {
        int i;
        for (i = 0; i < loadable_categories_used; i++) {
            if (loadable_categories[i].cat == cat) {
                loadable_categories[i].cat = nil;
                if (PrintLoading) {
                    _objc_inform("LOAD: category '%s(%s)' unscheduled for +load",
                                 _category_getClassName(cat), 
                                 _category_getName(cat));
                }
                return;
            }
        }
    }
}


/***********************************************************************
* call_class_loads
* Call all pending class +load methods.
* If new classes become loadable, +load is NOT called for them.
*
* Called only by call_load_methods().
**********************************************************************/
static void call_class_loads(void)
{
    /**
     由于在prepare_load_methods已经确定了类的load方法执行顺序，因此call_class_loads(void)仅需简单迭代执行loadable_class中的load方法即可。处理过程大致如下：
         .将局部变量classes指向loadable_classes，将loadable_classes指向nil。classes表示本次需要执行的所有类的load方法，为旧容器。loadable_classes表示本次执行的类的load方法中动态载入的所有新类的load方法，为新容器；
         .遍历classes中所有loadable_class结构体，执行其method所指向的load方法。遍历classes时，若load方法中载入了新的类的load方法，则又会被收集于loadable_classes所指向的新容器中；
     
         .释放classes局部变量所指向的旧容器内存空间；
     
     */
    int i;
    
    // Detach（分离） current loadable list.
    struct loadable_class *classes = loadable_classes;
    int used = loadable_classes_used;
    // loadable_classes指向nil
    loadable_classes = nil;
    loadable_classes_allocated = 0;
    loadable_classes_used = 0;
    
    // Call all +loads for the detached list.
    for (i = 0; i < used; i++) {
        Class cls = classes[i].cls;
        load_method_t load_method = (load_method_t)classes[i].method;
        if (!cls) continue; 

        if (PrintLoading) {
            _objc_inform("LOAD: +[%s load]\n", cls->nameForLogging());
        }
        // 执行load方法。load方法可能包含动态加载镜像的逻辑，此时loadable_classes则会指向
        // 新的容器来收集动态加载镜像中的load方法
        (*load_method)(cls, SEL_load);
    }
    
    // Destroy the detached list.
    if (classes) free(classes); // 释放旧容器
}


/***********************************************************************
* call_category_loads
* Call some pending category +load methods.
* The parent class of the +load-implementing categories has all of 
*   its categories attached, in case some are lazily waiting for +initalize.
* Don't call +load unless the parent class is connected.
* If new categories become loadable, +load is NOT called, and they 
*   are added to the end of the loadable list, and we return TRUE.
* Return FALSE if no new categories became loadable.
*
* Called only by call_load_methods().
**********************************************************************/
static bool call_category_loads(void)
{
    
    /**
     .局部变量cats指向loadable_categories表示旧容器。loadable_categories指向nil表示新容器；
     
     .遍历旧容器中的所有loadable_category结构体，若loadable_category的cls成员非空且可加载，则执行method成员指向的load方法，并把cat成员置nil；
     
     .用cats收集 旧容器中未执行load方法的所有分类（判断cat成员非空）；
     
     .用cats收集 执行旧容器的load方法过程中动态载入的所有分类；
     
     .若cats保存的loadable_category结构体数量大于0，则设置loadable_categories指向cats所指向的内存空间；反之loadable_categories置nil。
     */
    int i, shift;
    bool new_categories_added = NO;
    
    // Detach current loadable list.
    // 局部变量cats指向loadable_categories表示旧容器。
    struct loadable_category *cats = loadable_categories;
    int used = loadable_categories_used;
    int allocated = loadable_categories_allocated;
    // loadable_categories指向nil表示新容器；
    loadable_categories = nil;
    loadable_categories_allocated = 0;
    loadable_categories_used = 0;

    // Call all +loads for the detached list.
    for (i = 0; i < used; i++) {
        // 遍历旧容器中的所有loadable_category结构体
        Category cat = cats[i].cat;
        load_method_t load_method = (load_method_t)cats[i].method;
        Class cls;
        if (!cat) continue;

        cls = _category_getClass(cat);
        if (cls  &&  cls->isLoadable()) {
            if (PrintLoading) {
                _objc_inform("LOAD: +[%s(%s) load]\n", 
                             cls->nameForLogging(), 
                             _category_getName(cat));
            }
            // 若loadable_category的cls成员非空且可加载，则执行method成员指向的load方法，并把cat成员置nil
            (*load_method)(cls, SEL_load);
            cats[i].cat = nil;
        }
    }

    // Compact detached list (order-preserving)
    
    // 收集上面for循环未执行load方法的所有分类，其中包含了load方法中可能存在动态加载
    // 镜像时载入的分类的load方法，这些load方法不能立刻执行，需要其扩展类的load方法
    // 执行完毕后才能执行。
    shift = 0;
    for (i = 0; i < used; i++) {
        if (cats[i].cat) {
            cats[i-shift] = cats[i];
        } else {
            shift++;
        }
    }
    // loadable_categories旧容器中尚未执行load方法的loadable_category结构体数量，这些
    // loadable_category均保留在loadable_categories新容器
    used -= shift;

    // Copy any new +load candidates from the new list to the detached list.
    // 若loadable_categories_used大于0，说明在执行分类load方法时收集到新的分类load方法
    new_categories_added = (loadable_categories_used > 0);
    
    // 将新收集的分类load方法添加到loadable_categories新容器
    for (i = 0; i < loadable_categories_used; i++) {
        if (used == allocated) {
            allocated = allocated*2 + 16;
            cats = (struct loadable_category *)
                realloc(cats, allocated *
                                  sizeof(struct loadable_category));
        }
        cats[used++] = loadable_categories[i];
    }

    // Destroy the new list.
    // 释放旧loadable_categories容器
    if (loadable_categories) free(loadable_categories);

    // Reattach the (now augmented) detached list. 
    // But if there's nothing left to load, destroy the list.
    
    // 赋值新loadable_categories容器
    if (used) {
        loadable_categories = cats;
        loadable_categories_used = used;
        loadable_categories_allocated = allocated;
    } else {
        if (cats) free(cats);
        loadable_categories = nil;
        loadable_categories_used = 0;
        loadable_categories_allocated = 0;
    }

    if (PrintLoading) {
        if (loadable_categories_used != 0) {
            _objc_inform("LOAD: %d categories still waiting for +load\n",
                         loadable_categories_used);
        }
    }

    return new_categories_added;
}


/***********************************************************************
* call_load_methods
* Call all pending class and category +load methods.
* Class +load methods are called superclass-first. 
* Category +load methods are not called until after the parent class's +load.
* 
* This method must be RE-ENTRANT, because a +load could trigger 
* more image mapping. In addition, the superclass-first ordering 
* must be preserved in the face of re-entrant calls. Therefore, 
* only the OUTERMOST call of this function will do anything, and 
* that call will handle all loadable classes, even those generated 
* while it was running.
*
* The sequence below preserves +load ordering in the face of 
* image loading during a +load, and make sure that no 
* +load method is forgotten because it was added during 
* a +load call.
* Sequence:
* 1. Repeatedly call class +loads until there aren't any more
* 2. Call category +loads ONCE.
* 3. Run more +loads if:
*    (a) there are more classes to load, OR
*    (b) there are some potential category +loads that have 
*        still never been attempted.
* Category +loads are only run once to ensure "parent class first" 
* ordering, even if a category +load triggers a new loadable class 
* and a new loadable category attached to that class. 
*
* Locking: loadMethodLock must be held by the caller 
*   All other locks must not be held.
**********************************************************************/
void call_load_methods(void)
{
    
    /**
     从loadable_classes容器及loadable_categories容器中推出类和分类，依次调用load方法。
     
     call_load_methods(void)代码的逻辑比较怪异，
     在do-while循环内部的while循环明明已经判断loadable_classes_used <= 0，为什么在do-while还要判断loadable_classes_used > 0进入下一次迭代？
     这是因为类、分类的load方法中，均可能存在动态加载镜像文件的逻辑，从而引入新的类、分类的load方法。do-while循环内部，执行类的load方法使用了一个while循环，而执行分类的load方法则只调用了一次，这是因为分类load方法必须等待其扩展类的load方法执行完毕才能执行，因此需要立即进入下一次迭代以执行扩展类的load方法。

     */
    static bool loading = NO;
    bool more_categories;

    loadMethodLock.assertLocked();

    // Re-entrant calls do nothing; the outermost call will finish the job.
    if (loading) return;
    loading = YES;

    void *pool = objc_autoreleasePoolPush();

    do {
        // 1. Repeatedly call class +loads until there aren't any more
        // 1. 遍历并执行类的所有可调用的load方法
        while (loadable_classes_used > 0) {
            call_class_loads();
        }

        // 2. Call category +loads ONCE
        // 2. 执行分类的load方法
        more_categories = call_category_loads();

        // 3. Run more +loads if there are classes OR more untried categories
        // 3. 循环直到类及分类的所有load方法均被执行
    } while (loadable_classes_used > 0  ||  more_categories);

    objc_autoreleasePoolPop(pool);

    loading = NO;
}


