/*
 * Copyright (c) 2005-2007 Apple Inc.  All Rights Reserved.
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

#ifndef _OBJC_RUNTIME_NEW_H
#define _OBJC_RUNTIME_NEW_H

#if __LP64__
typedef uint32_t mask_t;  // x86_64 & arm64 asm are less efficient with 16-bits
#else
typedef uint16_t mask_t;
#endif
typedef uintptr_t cache_key_t;

struct swift_class_t;


// 方法名SEL为Key，以方法IMP为Value，分别对应bucket_t结构体的_sel、_imp成员
// 方法缓冲哈希表的元素，_sel为key，_imp为value
struct bucket_t {
private:
    // IMP-first is better for arm64e ptrauth and no worse for arm64.
    // SEL-first is better for armv7* and i386 and x86_64.
#if __arm64__
    MethodCacheIMP _imp;
    cache_key_t _key;
#else
    cache_key_t _key;
    MethodCacheIMP _imp;
#endif

public:
    inline cache_key_t key() const { return _key; }
    inline IMP imp() const { return (IMP)_imp; }
    inline void setKey(cache_key_t newKey) { _key = newKey; }
    inline void setImp(IMP newImp) { _imp = newImp; }

    void set(cache_key_t newKey, IMP newImp);
};

// 方法缓冲的数据结构
struct cache_t {
    // _buckets：保存哈希表所有元素的数组
    // bucket_t：方法缓冲哈希表的元素，_sel为key，_imp为value
    struct bucket_t *_buckets;
    
    // _mask：间接表示哈希表的容量，为全部位为1的二进制数。哈希表容量最小为4，满足公式：哈希表容量 = _mask + 1。扩容时设置_mask =(_mask + 1) & _mask；
    mask_t _mask;
    // _occupied：哈希表实际缓存的方法个数；
    mask_t _occupied;

public:
    struct bucket_t *buckets();
    mask_t mask();
    mask_t occupied();
    void incrementOccupied();
    void setBucketsAndMask(struct bucket_t *newBuckets, mask_t newMask);
    void initializeToEmpty();

    mask_t capacity();
    bool isConstantEmptyCache();
    bool canBeFreed();

    static size_t bytesForCapacity(uint32_t cap);
    static struct bucket_t * endMarker(struct bucket_t *b, uint32_t cap);

    void expand(); // 缓存扩容
    void reallocate(mask_t oldCapacity, mask_t newCapacity); // 重新分配空间
    struct bucket_t * find(cache_key_t key, id receiver); // 查找

    static void bad_cache(id receiver, SEL sel, Class isa) __attribute__((noreturn));
};


// classref_t is unremapped class_t*
typedef struct classref * classref_t;

/***********************************************************************
* entsize_list_tt<Element, List, FlagMask>
* Generic implementation of an array of non-fragile structs.
*
* Element is the struct type (e.g. method_t)
* List is the specialization of entsize_list_tt (e.g. method_list_t)
* FlagMask is used to stash extra bits in the entsize field
*   (e.g. method list fixup markers)
**********************************************************************/

/**
 entsize_list_tt是 runtime 定义的一种顺序表模板。
 entsize_list_tt<typename Element, typename List, uint32_t FlagMask>模板中，Element表示元素的类型，List表示所定义的顺序表容器类型名称，
 FlagMask用于从entsize_list_tt的entsizeAndFlags获取目标数据（Flag标志 或者 元素占用空间大小）。
 
 既然entsize_list_tt是顺序表，那么所占用内存空间必然是连续分配的。由于每个元素都是同类型，占用相同大小的内存空间(比如存储成员变量的列表，存储的元素是IVar结构)，因此可以通过索引值及首元素地址来定位到具体元素的内存地址。
 
 entsize_list_tt包含三个成员：

 entsizeAndFlags：entsize 是 entry size 的缩写，因此该成员保存了元素  Flag 标志 以及 元素占用空间大小，entsizeAndFlags & ~FlagMask获取元素占用空间大小，entsizeAndFlags & FlagMask获取 Flag 标志（可指定 Flag 标志用于特殊用途）；
 
 count：容器的元素数量；
 
 first：保存首元素，注意是首元素，不是指向首元素的指针；
 
 */
/// entsize_list_tt数据结构非常重要，成员变量列表、方法列表、分类列表、协议列表等数据结构是使用该模板定义。

template <typename Element, typename List, uint32_t FlagMask>
struct entsize_list_tt {
    // 顺序表模板，其中Element为元素类型，List为定义的顺序表容器类型， FlagMask指定entsizeAndFlags成员的最低多少位
    // 可用作标志位，例如0x3表示最低两位用作标志位。
    
    uint32_t entsizeAndFlags; // 元素占用空间大小及Flag标志位
    uint32_t count; // count成员是容器包含的元素数
    Element first; // 保存首元素，注意是首元素，不是指向首元素的指针；
    
    uint32_t entsize() const { // 元素占用空间大小
        return entsizeAndFlags & ~FlagMask; // 假如FlagMask为0x03 那么就是将最低两位置0来获取entsize
    }
    uint32_t flags() const {
        return entsizeAndFlags & FlagMask; // // 假如FlagMask为0x03 那么就是将最低两位置1来获取flags
    }

    Element& getOrEnd(uint32_t i) const { 
        assert(i <= count);
        return *(Element *)((uint8_t *)&first + i*entsize()); 
    }
    Element& get(uint32_t i) const { 
        assert(i < count);
        return getOrEnd(i);
    }

    // byteSize()返回容器占用总内存字节数
    size_t byteSize() const {
        return byteSize(entsize(), count);
    }
    
    static size_t byteSize(uint32_t entsize, uint32_t count) {
        // sizeOf(entsize_list_tt)返回容器的三个成员占用的字节数,具体大小取决于 Element 占用内存大小以及 Element 的对齐结构；
        return sizeof(entsize_list_tt) + (count-1)*entsize; // count-1是因为first记录了一个元素了？？？
    }

    List *duplicate() const {
        auto *dup = (List *)calloc(this->byteSize(), 1);
        dup->entsizeAndFlags = this->entsizeAndFlags;
        dup->count = this->count;
        std::copy(begin(), end(), dup->begin());
        return dup;
    }

    struct iterator;
    // begin()方法返回首元素的起始地址
    const iterator begin() const { 
        return iterator(*static_cast<const List*>(this), 0); 
    }
    iterator begin() { 
        return iterator(*static_cast<const List*>(this), 0); 
    }
    const iterator end() const { 
        return iterator(*static_cast<const List*>(this), count); 
    }
    // end()方法返回容器的结束地址
    iterator end() { 
        return iterator(*static_cast<const List*>(this), count); 
    }
    
    /// 自定义迭代器
    struct iterator {
        uint32_t entsize;
        uint32_t index;  // keeping track of this saves a divide in operator-
        Element* element;
        /// 一个iterator占用48个字节

        typedef std::random_access_iterator_tag iterator_category;
        typedef Element value_type;
        typedef ptrdiff_t difference_type;
        typedef Element* pointer;
        typedef Element& reference;

        iterator() { }
        /**
            构造函数初始化列表
            相当于
            terator(const List& list, uint32_t start = 0)
            {
                entsize = list.entsize();
                index = list.start;
                element = &list.getOrEnd(start);
            }
         */
        /// 构造函数初始化列表
        iterator(const List& list, uint32_t start = 0)
            : entsize(list.entsize())
            , index(start)
            , element(&list.getOrEnd(start))
        { }

        /**
         重载运算符
         重载的运算符是带有特殊名称的函数，函数名是由关键字 operator 和其后要重载的运算符符号构成的。与其他函数一样，重载运算符有一个返回类型和一个参数列表。

         Box operator+(const Box&);

         声明加法运算符用于把两个 Box 对象相加，返回最终的 Box 对象。
         */
        
        const iterator& operator += (ptrdiff_t delta) {
            element = (Element*)((uint8_t *)element + delta*entsize);
            index += (int32_t)delta;
            return *this;
        }
        const iterator& operator -= (ptrdiff_t delta) {
            element = (Element*)((uint8_t *)element - delta*entsize);
            index -= (int32_t)delta;
            return *this;
        }
        const iterator operator + (ptrdiff_t delta) const {
            return iterator(*this) += delta;
        }
        const iterator operator - (ptrdiff_t delta) const {
            return iterator(*this) -= delta;
        }

        iterator& operator ++ () { *this += 1; return *this; }
        iterator& operator -- () { *this -= 1; return *this; }
        iterator operator ++ (int) {
            iterator result(*this); *this += 1; return result;
        }
        iterator operator -- (int) {
            iterator result(*this); *this -= 1; return result;
        }

        ptrdiff_t operator - (const iterator& rhs) const {
            return (ptrdiff_t)this->index - (ptrdiff_t)rhs.index;
        }

        Element& operator * () const { return *element; }
        Element* operator -> () const { return element; }

        operator Element& () const { return *element; }

        bool operator == (const iterator& rhs) const {
            return this->element == rhs.element;
        }
        bool operator != (const iterator& rhs) const {
            return this->element != rhs.element;
        }

        bool operator < (const iterator& rhs) const {
            return this->element < rhs.element;
        }
        bool operator > (const iterator& rhs) const {
            return this->element > rhs.element;
        }
    };
};


struct method_t {
    SEL name; // 方法选择器，即方法名
    const char *types; // 方法的类型编码
    MethodListIMP imp; // 方法的实现，即方法的函数指针、方法的IMP

    // 方法在方法列表中排序时使用
    struct SortBySELAddress :
        public std::binary_function<const method_t&,
                                    const method_t&, bool>
    {
        bool operator() (const method_t& lhs,
                         const method_t& rhs)
        { return lhs.name < rhs.name; }
    };
};

struct ivar_t {
#if __x86_64__
    // *offset was originally 64-bit on some x86_64 platforms.
    // We read and write only 32 bits of it.
    // Some metadata provides all 64 bits. This is harmless for unsigned 
    // little-endian values.
    // Some code uses all 64 bits. class_addIvar() over-allocates the 
    // offset for their benefit.
#endif
    int32_t *offset;  // 成员变量的在实例内存块中的偏移
    const char *name; // 成员变量
    const char *type; // 成员变量的类型编码
    // alignment is sometimes -1; use alignment() instead
    uint32_t alignment_raw; // 成员变量的对齐准则，表示成员变量的对齐字节数为2^alignment_raw。例如，占用4字节的int类型成员变量alignment_raw为2，占用8字节的指针类型成员变量alignment_raw为3；
    uint32_t size; // size：成员变量在对象内存空间中占用的空间大小；

    uint32_t alignment() const {
        if (alignment_raw == ~(uint32_t)0) return 1U << WORD_SHIFT;
        return 1 << alignment_raw;
    }
    
    
    /****
     注意：默认情况下，类的成员变量对齐方式和C语言结构体的原则是一致的。例如：继承自NSObject的SomeClass类依次包含bool、int、char、id类型的四个成员，SomeClass实例的内存图如下。注意到，bool类型的bo成员本该可以 1 bit 就可以表示但却占了4个字节的内存空间，这都是因为内存对齐原则。
     
                                  -----------------------------
                                    xxxxxxxxxxx
     x0100BB134020                -----------------------------
                                    object id                   占用8Byte按8Byte对齐,
     x0100BB134018                ----------------------------- 偏移24
                                    char ch                     占用1Byte按1Byte对齐,
     x0100BB134010                ----------------------------- 偏移16
                                    int num                     占用4Byte按4Byte对齐,
     x0100BB13400C                ----------------------------- 偏移12
                                    bool bo                     占用1Byte按1Byte对齐
     x0100BB134008                ----------------------------- 偏移8
                                    Class isa                   占用8Byte按8Byte对齐,
     x0100BB134000                ----------------------------- 偏移0
                                    xxxxxxxxxxx
                                  -----------------------------
     
     实际占用内存大小为: 24 + 8 = 32Byte
     
     ***/
};



/**
 
 
 一、属性概述
 
 属性（property）是为类的成员变量提供公开的访问器。属性与方法有非常紧密的联系，可读写的属性有 getter 和 setter 两个方法与之对应。
 
 属性（property）大多数情况是作为成员变量的访问器（accessor）使用，为外部访问成员变量提供接口。使用@property声明属性时需要指定属性的特性（attribute），
 包括：

     读写特性（readwrite/readonly）；
     原子性（atomic/nonatomic）；
     内存管理特性（assign/strong/weak/copy）；
     是否可空（nullable/nonnull）；


 注意：上面括号中的第一个值是属性的默认特性，不过是否可空有其特殊性，可以通过NS_ASSUME_NONNULL_BEGIN/NS_ASSUME_NONNULL_END宏包围属性的声明语句，将属性的默认可空特性置为nonnull。

 除了上述特性还可以显式指定getter、setter。属性的特性指定了属性作为访问器的行为特征。声明了属性只是意味着声明了访问器，此时的访问器是没有getter和setter的实现的，想要访问器关联特定的成员变量在代码上有两种方式：
      1、使用@synthesize修饰符合成属性；
      2、实现属性的 getter 和 setter。但是两者的本质是一样的，就是按属性的特性实现属性的 getter 和 setter。

 注意：@dynamic修饰属性，表示不合成属性的 getter 和 setter。此时要么在当前类或子类的实现中实现getter/setter、要么在子类实现中用@synthesize合成属性。

 作者：Luminix
 链接：https://juejin.im/post/5da491d95188252f051e24e1

 */

struct property_t {
    const char *name; // 有属性名、
    const char *attributes; // 特性信息
};

// Two bits of entsize are used for fixup markers.
struct method_list_t : entsize_list_tt<method_t, method_list_t, 0x3> {
    // 查询方法列表是否已排序
    bool isFixedUp() const;
    // 标记方法列表已排序
    void setFixedUp();

    // 新增返回方法在顺序表中的索引值的方法
    uint32_t indexOfMethod(const method_t *meth) const {
        uint32_t i = 
            (uint32_t)(((uintptr_t)meth - (uintptr_t)this) / entsize());
        assert(i < count);
        return i;
    }
};

 /// 类的所有成员变量保存在一个顺序表容器中，其类型为ivar_list_t结构体，代码如下。ivar_list_t继承了entsize_list_tt顺序表模板，增加了bool containsIvar(Ivar ivar) const函数，用于查找传入的Ivar类型的ivar是否包含在成员变量列表中。
struct ivar_list_t : entsize_list_tt<ivar_t, ivar_list_t, 0> {
    bool containsIvar(Ivar ivar) const {
        // 直接与顺序表开头地址与结尾地址比较，超出该内存区块表示不在该成员变量列表中
        return (ivar >= (Ivar)&*begin()  &&  ivar < (Ivar)&*end());
    }
};
/// 类似ivar_list_t、method_list_t
struct property_list_t : entsize_list_tt<property_t, property_list_t, 0> {
};


typedef uintptr_t protocol_ref_t;  // protocol_t *, but unremapped

// Values for protocol_t->flags
#define PROTOCOL_FIXED_UP_2 (1<<31)  // must never be set by compiler
#define PROTOCOL_FIXED_UP_1 (1<<30)  // must never be set by compiler
// Bits 0..15 are reserved for Swift's use.

#define PROTOCOL_FIXED_UP_MASK (PROTOCOL_FIXED_UP_1 | PROTOCOL_FIXED_UP_2)

struct protocol_t : objc_object {
    const char *mangledName;
    struct protocol_list_t *protocols;
    method_list_t *instanceMethods;
    method_list_t *classMethods;
    method_list_t *optionalInstanceMethods;
    method_list_t *optionalClassMethods;
    property_list_t *instanceProperties;
    uint32_t size;   // sizeof(protocol_t)
    uint32_t flags;
    // Fields below this point are not always present on disk.
    const char **_extendedMethodTypes;
    const char *_demangledName;
    property_list_t *_classProperties;

    const char *demangledName();

    const char *nameForLogging() {
        return demangledName();
    }

    bool isFixedUp() const;
    void setFixedUp();

#   define HAS_FIELD(f) (size >= offsetof(protocol_t, f) + sizeof(f))

    bool hasExtendedMethodTypesField() const {
        return HAS_FIELD(_extendedMethodTypes);
    }
    bool hasDemangledNameField() const {
        return HAS_FIELD(_demangledName);
    }
    bool hasClassPropertiesField() const {
        return HAS_FIELD(_classProperties);
    }

#   undef HAS_FIELD

    const char **extendedMethodTypes() const {
        return hasExtendedMethodTypesField() ? _extendedMethodTypes : nil;
    }

    property_list_t *classProperties() const {
        return hasClassPropertiesField() ? _classProperties : nil;
    }
};

struct protocol_list_t {
    // count is 64-bit by accident. 
    uintptr_t count;
    protocol_ref_t list[0]; // variable-size

    size_t byteSize() const {
        return sizeof(*this) + count*sizeof(list[0]);
    }

    protocol_list_t *duplicate() const {
        return (protocol_list_t *)memdup(this, this->byteSize());
    }

    typedef protocol_ref_t* iterator;
    typedef const protocol_ref_t* const_iterator;

    const_iterator begin() const {
        return list;
    }
    iterator begin() {
        return list;
    }
    const_iterator end() const {
        return list + count;
    }
    iterator end() {
        return list + count;
    }
};
// 分类列表中的元素的类型，包含指向分类的指针
struct locstamped_category_t {
    category_t *cat;
    struct header_info *hi;
};
// locstamped_category_list_t 数组容器是实现了分类列表
struct locstamped_category_list_t {
    uint32_t count;
#if __LP64__
    uint32_t reserved;
#endif
    locstamped_category_t list[0];
};


// class_data_bits_t is the class_t->data field (class_rw_t pointer plus flags)
// The extra bits are optimized for the retain/release and alloc/dealloc paths.

// Values for class_ro_t->flags
// These are emitted by the compiler and are part of the ABI.
// Note: See CGObjCNonFragileABIMac::BuildClassRoTInitializer in clang
// class is a metaclass
#define RO_META               (1<<0)
// class is a root class
#define RO_ROOT               (1<<1)
// class has .cxx_construct/destruct implementations
#define RO_HAS_CXX_STRUCTORS  (1<<2)
// class has +load implementation
// #define RO_HAS_LOAD_METHOD    (1<<3)
// class has visibility=hidden set
#define RO_HIDDEN             (1<<4)
// class has attribute(objc_exception): OBJC_EHTYPE_$_ThisClass is non-weak
#define RO_EXCEPTION          (1<<5)
// this bit is available for reassignment
// #define RO_REUSE_ME           (1<<6) 
// class compiled with ARC
#define RO_IS_ARC             (1<<7)
// class has .cxx_destruct but no .cxx_construct (with RO_HAS_CXX_STRUCTORS)
#define RO_HAS_CXX_DTOR_ONLY  (1<<8)
// class is not ARC but has ARC-style weak ivar layout 
#define RO_HAS_WEAK_WITHOUT_ARC (1<<9)

// class is in an unloadable bundle - must never be set by compiler
#define RO_FROM_BUNDLE        (1<<29)
// class is unrealized future class - must never be set by compiler
#define RO_FUTURE             (1<<30)
// class is realized - must never be set by compiler
#define RO_REALIZED           (1<<31)

// Values for class_rw_t->flags
// These are not emitted by the compiler and are never used in class_ro_t. 
// Their presence should be considered in future ABI versions.
// class_t->data is class_rw_t, not class_ro_t
#define RW_REALIZED           (1<<31)
// class is unresolved future class
#define RW_FUTURE             (1<<30)
// class is initialized
#define RW_INITIALIZED        (1<<29)
// class is initializing
#define RW_INITIALIZING       (1<<28)
// class_rw_t->ro is heap copy of class_ro_t
#define RW_COPIED_RO          (1<<27)
// class allocated but not yet registered
#define RW_CONSTRUCTING       (1<<26)
// class allocated and registered
#define RW_CONSTRUCTED        (1<<25)
// available for use; was RW_FINALIZE_ON_MAIN_THREAD
// #define RW_24 (1<<24)
// class +load has been called
#define RW_LOADED             (1<<23)
#if !SUPPORT_NONPOINTER_ISA
// class instances may have associative references
#define RW_INSTANCES_HAVE_ASSOCIATED_OBJECTS (1<<22)
#endif
// class has instance-specific GC layout
#define RW_HAS_INSTANCE_SPECIFIC_LAYOUT (1 << 21)
// available for use
// #define RW_20       (1<<20)
// class has started realizing but not yet completed it
#define RW_REALIZING          (1<<19)

// NOTE: MORE RW_ FLAGS DEFINED BELOW


// Values for class_rw_t->flags or class_t->bits
// These flags are optimized for retain/release and alloc/dealloc
// 64-bit stores more of them in class_t->bits to reduce pointer indirection.

#if !__LP64__    /// LP64指的是LONG/POINTER字长为64位

// class or superclass has .cxx_construct implementation
#define RW_HAS_CXX_CTOR       (1<<18)
// class or superclass has .cxx_destruct implementation
#define RW_HAS_CXX_DTOR       (1<<17)
// class or superclass has default alloc/allocWithZone: implementation
// Note this is is stored in the metaclass.
#define RW_HAS_DEFAULT_AWZ    (1<<16)
// class's instances requires raw isa
#if SUPPORT_NONPOINTER_ISA
#define RW_REQUIRES_RAW_ISA   (1<<15)
#endif
// class or superclass has default retain/release/autorelease/retainCount/
//   _tryRetain/_isDeallocating/retainWeakReference/allowsWeakReference
#define RW_HAS_DEFAULT_RR     (1<<14)

// class is a Swift class from the pre-stable Swift ABI
#define FAST_IS_SWIFT_LEGACY  (1UL<<0)
// class is a Swift class from the stable Swift ABI
#define FAST_IS_SWIFT_STABLE  (1UL<<1)
// data pointer
#define FAST_DATA_MASK        0xfffffffcUL

#elif 1
// Leaks-compatible version that steals low bits only.

// class or superclass has .cxx_construct implementation
#define RW_HAS_CXX_CTOR       (1<<18)
// class or superclass has .cxx_destruct implementation
#define RW_HAS_CXX_DTOR       (1<<17)
// class or superclass has default alloc/allocWithZone: implementation
// Note this is is stored in the metaclass.
#define RW_HAS_DEFAULT_AWZ    (1<<16)
// class's instances requires raw isa
#define RW_REQUIRES_RAW_ISA   (1<<15)

// class is a Swift class from the pre-stable Swift ABI
#define FAST_IS_SWIFT_LEGACY    (1UL<<0)
// class is a Swift class from the stable Swift ABI
#define FAST_IS_SWIFT_STABLE    (1UL<<1)
// class or superclass has default retain/release/autorelease/retainCount/
//   _tryRetain/_isDeallocating/retainWeakReference/allowsWeakReference
#define FAST_HAS_DEFAULT_RR     (1UL<<2)
// data pointer
#define FAST_DATA_MASK          0x00007ffffffffff8UL

#else
// Leaks-incompatible version that steals lots of bits.

// class is a Swift class from the pre-stable Swift ABI
#define FAST_IS_SWIFT_LEGACY    (1UL<<0)
// class is a Swift class from the stable Swift ABI
#define FAST_IS_SWIFT_STABLE    (1UL<<1)
// summary bit for fast alloc path: !hasCxxCtor and 
//   !instancesRequireRawIsa and instanceSize fits into shiftedSize
#define FAST_ALLOC              (1UL<<2)
// data pointer
#define FAST_DATA_MASK          0x00007ffffffffff8UL
// class or superclass has .cxx_construct implementation
#define FAST_HAS_CXX_CTOR       (1UL<<47)
// class or superclass has default alloc/allocWithZone: implementation
// Note this is is stored in the metaclass.
#define FAST_HAS_DEFAULT_AWZ    (1UL<<48)
// class or superclass has default retain/release/autorelease/retainCount/
//   _tryRetain/_isDeallocating/retainWeakReference/allowsWeakReference
#define FAST_HAS_DEFAULT_RR     (1UL<<49)
// class's instances requires raw isa
//   This bit is aligned with isa_t->hasCxxDtor to save an instruction.
#define FAST_REQUIRES_RAW_ISA   (1UL<<50)
// class or superclass has .cxx_destruct implementation
#define FAST_HAS_CXX_DTOR       (1UL<<51)
// instance size in units of 16 bytes
//   or 0 if the instance size is too big in this field
//   This field must be LAST
#define FAST_SHIFTED_SIZE_SHIFT 52

// FAST_ALLOC means
//   FAST_HAS_CXX_CTOR is set
//   FAST_REQUIRES_RAW_ISA is not set
//   FAST_SHIFTED_SIZE is not zero
// FAST_ALLOC does NOT check FAST_HAS_DEFAULT_AWZ because that 
// bit is stored on the metaclass.
#define FAST_ALLOC_MASK  (FAST_HAS_CXX_CTOR | FAST_REQUIRES_RAW_ISA)
#define FAST_ALLOC_VALUE (0)

#endif

// The Swift ABI requires that these bits be defined like this on all platforms.
static_assert(FAST_IS_SWIFT_LEGACY == 1, "resistance is futile");
static_assert(FAST_IS_SWIFT_STABLE == 2, "resistance is futile");


struct class_ro_t {
    
    // 32位位图，标记类的状态。需要注意class_ro_t的flags使用的位域和前面介绍的class_rw_t的flags使用的位域是完全不同的；
    uint32_t flags;
    
    /****
     类注册后只读的flags位域
     
     // 类是元类
     #define RO_META               (1<<0)
     
     // 类是根类
     #define RO_ROOT               (1<<1)
     
     // 类有CXX构造/析构函数
     #define RO_HAS_CXX_STRUCTORS  (1<<2)
     
     // 类有实现load方法
     // #define RO_HAS_LOAD_METHOD    (1<<3)
     
     // 隐藏类
     #define RO_HIDDEN             (1<<4)
     
     // class has attribute(objc_exception): OBJC_EHTYPE_$_ThisClass is non-weak
     #define RO_EXCEPTION          (1<<5)
     
     // class has ro field for Swift metadata initializer callback
     #define RO_HAS_SWIFT_INITIALIZER (1<<6)
     
     // 类使用ARC选项编译
     #define RO_IS_ARC             (1<<7)
     
     // 类有CXX析构函数，但没有CXX构造函数
     #define RO_HAS_CXX_DTOR_ONLY  (1<<8)
     
     // class is not ARC but has ARC-style weak ivar layout
     #define RO_HAS_WEAK_WITHOUT_ARC (1<<9)
     
     // 类禁止使用关联对象
     #define RO_FORBIDS_ASSOCIATED_OBJECTS (1<<10)

     // class is in an unloadable bundle - must never be set by compiler
     #define RO_FROM_BUNDLE        (1<<29)
     
     // class is unrealized future class - must never be set by compiler
     #define RO_FUTURE             (1<<30)
     
     // class is realized - must never be set by compiler
     #define RO_REALIZED           (1<<31)
    
     ****/
    
    
    // 类的成员变量，在实例的内存空间中的起始偏移量；
    uint32_t instanceStart;
    
    
    // 类的实例占用的内存空间大小；
    uint32_t instanceSize;
    
    
#ifdef __LP64__
    uint32_t reserved;
#endif
    
    /**
     成员变量内存布局，标记实例占用的内存空间中哪些WORD保存了成员变量数据，具体需要查看objc-layout.mm文件中的layout_bitmap信息
     
     class_ro_t结构体中包含ivarLayout、weakIvarLayout成员，用于标记对象占用的内存空间中，哪些 WORD 有被用来存储id类型的成员变量，weakIvarLayout专门针对weak类型成员变量。
     
     ivarLayout、weakIvarLayout可以理解为狭义上的成员变量布局。objc_class用十六进制数表示类的 ivar layout，该十六进制数是通过压缩二进制 layout bitmap 获得。例如，调用class_getIvarLayout获取UIView的ivarLayout为0x0312119A12。
     
     
     
     
     成员变量记录了成员变量的变量名，还记录了成员变量在对象内存空间中的偏移量、成员变量数据类型、占用字节数以及对齐字节数，用ivarLayout、weakIvarLayout记录成员变量的内存管理方式；

     新版本 runtime 支持 non-fragile instance variables，成员变量的偏移量并不是编译时固定，而是在运行时根据父类的instanceSize动态调整；
     ivarLayout、weakIvarLayout数据形式时十六进制数，是对layout_bitmap中bits保存的二进制数压缩处理后的结果，layout_bitmap保存的二进制数记录了类对象内存空间中的instanceStart起始的类的成员变量内存空间中哪个 WORD 保存了id类型成员变量；

     ivarLayout、weakIvarLayout记录了某 WORD 保存id，则二进制该位置为1，
     称该对象中该成员变量scanned，ivarLayout中标记了scanned的成员变量内存管理方式为strong，weakIvarLayout中标记了scanned的成员变量内存管理方式为weak。

     作者：Luminix
     链接：https://juejin.im/post/5da2a0f2e51d45780e4cea1c
     */
    const uint8_t * ivarLayout; /// 成员变量的内存布局
    
    const char * name; // 类名
    method_list_t * baseMethodList; // 基础方法列表，在类定义时指定的方法列表
    protocol_list_t * baseProtocols; // 协议列表
    const ivar_list_t * ivars; // 成员变量列表

    const uint8_t * weakIvarLayout; // weak成员变量布局
    property_list_t *baseProperties; // 基础属性列表，在类定义时指定的属性列表

    method_list_t *baseMethods() const {
        return baseMethodList;
    }
    
    /***
     类构建成员变量列表的过程，包含确定成员变量布局（ivar layout） 的过程。成员变量布局就是定义对象占用内存空间中哪块区域保存哪个成员变量，具体为确定类的instanceSize、内存对齐字节数、成员变量的offset。类的继承链上所有类的成员变量布局，共同构成了对象内存布局（object layout）。成员变量布局和对象内存布局的关系可以用一个公式表示：类的对象内存布局 = 父类的对象内存布局 + 类的成员变量布局

     1.成员变量的偏移量offset必须大于等于父类的instanceSize；
     
     2.成员变量的布局和结构体的对齐遵循同样的准则，类的对齐字节数必须大于等于父类的对齐字节数。
     例如，占用4字节的int类型成员变量的起始内存地址必须是4的倍数，占用8字节的id类型成员变量的起始内存地址必须是8的倍数；
     
     3.instanceSize的计算公式是类的instanceSize = 父类的instanceSize + 类的成员变量在实例中占用的内存空间 + 对齐填补字节，instanceSize必须是类的对齐字节数的整数倍；

     NSObject类的定义中，包含一个Class类型的isa成员，因此实际上isa指针的8个字节内存空间也属于对象内存布局的范畴。
     
     
     
     @interface TestObjectLayout : NSObject{
         bool bo;
         int num;
         char ch;
         id obj;
     }
     @end

     @implementation TestObjectLayout

     @end

     其成员变量布局的计算过程如下：

     1.instanceSize初始化为父类的instanceSize的值，并按父类的对齐字节数对齐。
     父类NSObject仅包含isa一个成员变量，isa占用8个字节offset为0，因此父类instanceSize为8，按8字节对齐；
     
     2.instanceSize初始化，按照对齐法则依次添加成员变量，并更新instanceSize。
     bo按字节对齐（注意bool类型占用1字节空间并不是1位），偏移量为8，instanceSize更新为16；
     
     3.num按4字节对齐，偏移量为12，instanceSize仍为16；
     
     4.ch按字节对齐，偏移量为16，instanceSize更新为24；
     
     5.obj按8字节对齐，偏移量为24，instanceSize更新为32。最终确定instanceSize为32字节，按8字节对齐。

     类的构建过程之所以要计算类的成员变量布局，是因为构建一个对象时需要确定需要为对象分配的内存空间大小，且构建对象仅返回对象的内存首地址，而通过成员变量的offset结合ivar_type，则可以轻而易取地通过对象地址定位到保存成员变量的内存空间。
     
     https://juejin.im/post/5d8c7aab51882505d334d7a5
     
     */
};


/***********************************************************************
* list_array_tt<Element, List>
* Generic implementation for metadata that can be augmented by categories.
*
* Element is the underlying metadata type (e.g. method_t)
* List is the metadata's list type (e.g. method_list_t)
*
* A list_array_tt has one of three values:
* - empty
* - a pointer to a single list
* - an array of pointers to lists
*
* countLists/beginLists/endLists iterate the metadata lists
* count/begin/end iterate the underlying metadata elements
**********************************************************************/


/**
 
 
 Runtime 定义list_array_tt类模板表示二维数组容器。
 list_array_tt保存的数据主体是一个联合体，包含list和arrayAndFlag成员，表示：容器要么保存一维数组，此时联合体直接保存一维数组的地址，地址的最低位必为0；要么保存二维数组，此时联合体保存二维数组的首个列表元素的地址，且最低位置为1。
 
 调用hasArray()方法可以查询容器是否保存的是二维数组，返回arrayAndFlag & 1，即通过最低位是否为1进行判断；
 
 调用list_array_tt的array()方法可以获取二维数组容器的地址，返回arrayAndFlag & ~1，即忽略最低位。
 
 
 
 当联合体保存二维数组时，联合体的arrayAndFlag指向list_array_tt内嵌定义的array_t结构体。
 
 该结构体是简单的一维数组容器，但其元素为指向列表容器的指针，因此array_t的本质是二维数组。
 
 调用array_t的byteSize()可以返回列表容器占用的总字节数，为array_t结构体本身的size与保存列表元素的连续内存区块的size之和。

 作者：Luminix
 链接：https://juejin.im/post/5da4740651882535b7242eaa
 */

// 二维数组容器模板类
template <typename Element, typename List>
class list_array_tt {
    
    // 定义二维数组的外层一维数组容器
    struct array_t {
        uint32_t count; // 外层一维数组存储元素数量
        List* lists[0]; // 内层一维数组容器，元素为指向容器列表的指针，因此array_t的本质是二维数组

        static size_t byteSize(uint32_t count) {
            return sizeof(array_t) + count*sizeof(lists[0]);
        }
        // 计算容器占用字节数
        size_t byteSize() {
            return byteSize(count);
        }
    };

 protected:
    class iterator {
        List **lists; // 当前迭代到的数组的位置
        List **listsEnd; // 二维数组的外层容器的结尾；
        typename List::iterator m, mEnd; // m:当前迭代到的数组中的元素的位置；mEnd:当前迭代到的数组的结尾；
        // 注意：构建list_array_tt的迭代器时，只能从方法列表到方法列表，不能从容器中的方法列表的某个元素的迭代器开始迭代。
        
     public:
        // 构建从begin指向的列表，到end指向的列表的迭代器
        iterator(List **begin, List **end) 
            : lists(begin), listsEnd(end)
        {
            if (begin != end) {
                m = (*begin)->begin(); // 此处的begin()是 List::iterator中的 (entsize_list_tt)
                mEnd = (*begin)->end(); // 此处的begin()是 List::iterator中的 (entsize_list_tt)
            }
        }

        const Element& operator * () const {
            return *m;
        }
        Element& operator * () {
            return *m;
        }

        bool operator != (const iterator& rhs) const {
            if (lists != rhs.lists) return true;
            if (lists == listsEnd) return false;  // m is undefined
            if (m != rhs.m) return true;
            return false;
        }
    
        // 迭代时，若达到当前数组的结尾，则切换到下一个数组的开头
        const iterator& operator ++ () {
            assert(m != mEnd);
            m++;
            if (m == mEnd) {
                assert(lists != listsEnd);
                lists++;
                if (lists != listsEnd) {
                    m = (*lists)->begin();
                    mEnd = (*lists)->end();
                }
            }
            return *this;
        }
    };

 private:
    union {
        List* list; // 要么指向一维数组容器
        uintptr_t arrayAndFlag; // 要么指向二维数组容器
    };
    
    // 容器是否保存的是二维数组
    bool hasArray() const {
        return arrayAndFlag & 1; // arrayAndFlag & 1，即通过最低位是否为1进行判断；
    }
    
    // 获取容器(指list_array_tt这个class)保存的二维数组的地址
    array_t *array() {
        return (array_t *)(arrayAndFlag & ~1); // arrayAndFlag & ~1，即忽略最低位。
    }

    void setArray(array_t *array) {
        arrayAndFlag = (uintptr_t)array | 1; // (uintptr_t)array | 1,即最低位置为1
    }

 public:
    // 计算方法列表二维数组容器中所有Element的数量
    uint32_t count() {
        uint32_t result = 0;
        
        /// lists是指向List*类型的指针 (*lists)就是获取List类型的数据  ++lists是List*为单位的递增
        for (auto lists = beginLists(), end = endLists(); 
             lists != end;
             ++lists)
        {
            
            result += (*lists)->count; // 注意该count定义在entsize_list_tt模板中
        }
        return result;
    }
    // 获取Element列表二维数组容器的起始迭代器
    iterator begin() {
        return iterator(beginLists(), endLists());
    }
    // 获取Element列表二维数组容器的结束迭代器
    iterator end() {
        List **e = endLists();
        return iterator(e, e);
    }

    // 获取Element列表二维数组容器包含的列表数量
    uint32_t countLists() {
        if (hasArray()) {
            return array()->count;
        } else if (list) {
            return 1;
        } else {
            return 0;
        }
    }
    
    
    /**
     https://bbs.csdn.net/topics/380226723
     
     指针、数组名、地址这几个东西混在一起是不少人头疼的，它们之间有紧密的关系，但不是完全含义相同的。

     指针是指针常量、指针变量、指针表达式范畴内的类型概念，我不赞同指针是指针变量的简称这一说法。

     数组名（先限定在一维数组范围内）是首元素的指针（不要简单说是数组首址），是指针常量。

     地址只是某个存储单元的位置序号（无符号整数），它本身没有类型（不提供从这个单元开始存储数据的类型信息）。

     指针的值是地址，但指针（指针常量、指针变量、指针表达式（包括了返回指针的函数））还带有类型（带有从这个单元开始存储数据的类型）！

     二维数组为例：
     int a[M][N];
     &a[i][j]+1 //都知道是下一个元素a[i][j+1]的指针，表达式中的1的类型是从&a[i][j]处得到的
     &a[1]+1    //这是下一行a[i+1]的指针,同理表达式中的1的类型是从&a[i]处得到的
     &a+1       //这已经不是a范围内的指针了，但可以理解为a数组后的那个单元的指针，形式上地址值为&[M][0]--越界了，想表达的这里的1的类型是&a的


     上述几个例子中指针表达式（泛称）中都有+1，这个1显然不是相同的含义，即1有类型、从+号左边的指针表达式传递来的“类型”
     而+1左边的指针表达式，其地址编码完全相同－－－－不附加指针表达式的“类型”概念是无法解释清楚的
     
     */
    
    // 获取xx列表二维数组容器的起始地址 List**表示二维数组存放的是List*类型的地址
    List** beginLists() {
        if (hasArray()) {
            return array()->lists; // array()获取的是外层一维数组的地址 array()->lists获取的是内部一维数组的地址
                                   // 这样返回值是指向List*类型的指针(指针的值是地址，但是带有类型该类型是List*，这样在做运算时单位就是List*)
                                   // 相当于&array[0]
        } else {
            return &list;
        }
    }
    
    // 获取Element列表二维数组容器的结束地址
    List** endLists() {
        if (hasArray()) {
            return array()->lists + array()->count;
        } else if (list) {
            return &list + 1;
        } else {
            return &list;
        }
    }

    /****

     attachLists(...)：将列表元素添加到二维数组容器的开头，注意到list_array_tt没有定义构造函数，
     这是因为构造逻辑均在attachLists(...)中，包含容器从空转化为保存一位数组，再转化为保存二维数组的处理逻辑；
     
     tryFree()：释放二维数组容器占用内存；
     
     duplicate(...)：复制二维数组容器；

     作者：Luminix
     链接：https://juejin.im/post/5da4740651882535b7242eaa
     */
    
    // 向二维数组容器中添加列表 添加的是指向List*类型的指针
    void attachLists(List* const * addedLists, uint32_t addedCount) {
        if (addedCount == 0) return;

        if (hasArray()) { // 当容器中保存的是二维数组
            // many lists -> many lists
            uint32_t oldCount = array()->count; // 外层一维数组的count
            uint32_t newCount = oldCount + addedCount;
            // 分配新内存空间重新构建容器
            setArray((array_t *)realloc(array(), array_t::byteSize(newCount)));
            
            array()->count = newCount;
            
            // 转移容器原内容到新内存空间 将以前的Element列表添加在数组后边
            memmove(array()->lists + addedCount, array()->lists, 
                    oldCount * sizeof(array()->lists[0]));
            
            // 将需要新增的Element列表拷贝到新内存空间 将以前的Element列表内容添加在数组前面
            memcpy(array()->lists, addedLists, 
                   addedCount * sizeof(array()->lists[0]));
        }
        else if (!list  &&  addedCount == 1) {
            // 0 lists -> 1 list
            // 当容器中无任何方法，直接将list成员指向addedLists
            list = addedLists[0];
        } 
        else {
            // 1 list -> many lists
            // 当容器中保存的是一维数组
            List* oldList = list;
            uint32_t oldCount = oldList ? 1 : 0;
            uint32_t newCount = oldCount + addedCount;
            
            setArray((array_t *)malloc(array_t::byteSize(newCount)));
            
            array()->count = newCount;
            /// 将数据存在array的末尾
            if (oldList) array()->lists[addedCount] = oldList;
            
            memcpy(array()->lists, addedLists, 
                   addedCount * sizeof(array()->lists[0]));
        }
    }

    // 释放二维数组容器占用内存；
    void tryFree() {
        if (hasArray()) {
            for (uint32_t i = 0; i < array()->count; i++) {
                try_free(array()->lists[i]);
            }
            try_free(array());
        }
        else if (list) {
            try_free(list);
        }
    }
    
    // 复制二维数组容器；
    template<typename Result>
    Result duplicate() {
        Result result;

        if (hasArray()) {
            array_t *a = array();
            result.setArray((array_t *)memdup(a, a->byteSize()));
            for (uint32_t i = 0; i < a->count; i++) {
                result.array()->lists[i] = a->lists[i]->duplicate();
            }
        } else if (list) {
            result.list = list->duplicate();
        } else {
            result.list = nil;
        }

        return result;
    }
};

// 方法列表二维数组容器 容器中存放的是指向method_list_t指针的地址
class method_array_t : 
    public list_array_tt<method_t, method_list_t> 
{
    typedef list_array_tt<method_t, method_list_t> Super;

    
    
 /**
  由method_array_t中扩展list_array_tt的方法的方法名可见，method_array_t是为 category 量身定做的，显然 category 中定义的所有方法都存储在该容器中，每个 category 定义的方法对应method_array_t二维数组容器中的一个元素，也就是一个方法列表method_list_t结构体的指针。扩展的方法如下：

  beginCategoryMethodLists()：指向容器的第一个数组；
  
  endCategoryMethodLists(Class cls)：当类的class_rw_t中不存在baseMethodList时，直接返回容器最后一个数组，
  当存在baseMethodList时，返回容器的倒数第二个数组。

  作者：Luminix
  链接：https://juejin.im/post/5da4740651882535b7242eaa
  */
 public:
    method_list_t **beginCategoryMethodLists() {
        return beginLists(); /// 返回指向容器的第一个方法列表地址，这个地址存放的内容是一个method_list_t指针的地址
    }
    
    // 当类的class_rw_t中不存在baseMethodList时，直接返回容器最后一个数组，当存在baseMethodList时，返回容器的倒数第二个数组。
    method_list_t **endCategoryMethodLists(Class cls);

    method_array_t duplicate() {
        return Super::duplicate<method_array_t>();
    }
    
    /****
     
     在类的加载过程。从 class realizing 时调用的methodizeClass(...)函数的处理逻辑可以看出：
     
     class_rw_t中的method_array_t容器保存了类的完整方法列表，包括静态编译的类的基本方法、运行时决议的 category 中的方法以及运行时动态添加的方法。
     而且class_rw_t中method_array_t容器的最后一个数组实际上就是class_ro_t的baseMethodList。
     再结合 介绍的list_array_tt的attachLists(...)方法逻辑，可以基本了解方法列表容器的工作机制。
     
     当使用class_addMethod(...)动态添加类，或者应用加载阶段加载 category 时，均调用了该方法。由于attachLists(...)添加方法时，将方法添加到容器的开头，
     将原有的method_list_t集体后移，因此类的同名方法的IMP的优先级从高到低排序如下：

     通过class_addMethod(...)动态添加的方法；
     后编译的类的 category 中的方法；
     先编译的类的 category 中的方法；
     类实现的方法；
     类的父类实现的方法；

     作者：Luminix
     链接：https://juejin.im/post/5da4740651882535b7242eaa
     
     */
};

/// 属性列表二维数组容器 容器中存放的是指向property_list_t指针的地址
class property_array_t : 
    public list_array_tt<property_t, property_list_t> 
{
    typedef list_array_tt<property_t, property_list_t> Super;

 public:
    property_array_t duplicate() {
        return Super::duplicate<property_array_t>();
    }
};


class protocol_array_t : 
    public list_array_tt<protocol_ref_t, protocol_list_t> 
{
    typedef list_array_tt<protocol_ref_t, protocol_list_t> Super;

 public:
    protocol_array_t duplicate() {
        return Super::duplicate<protocol_array_t>();
    }
};


struct class_rw_t {
    // Be warned that Symbolication knows the layout of this structure.
    uint32_t flags; // 32位位图，标记类的状态
    /**
     类注册后可读写的flags位域
     class_rw_t的flags成员中比较重要的一些位域定义列举如下，均以RW_为前缀，这些位域在类注册后仍可读写。
     
     // 类是已经注册的类
     #define RW_REALIZED           (1<<31)
     
     // 类是尚未解析的future class
     #define RW_FUTURE             (1<<30)
     
     // 类是已经初始化的类
     #define RW_INITIALIZED        (1<<29)
     
     // 类是正在初始化的类
     #define RW_INITIALIZING       (1<<28)
     
     // class_rw_t->ro是class_ro_t的堆拷贝
     // 此时类的class_rw_t->ro是可写入的，拷贝之前ro的内存区域锁死不可写入
     #define RW_COPIED_RO          (1<<27)
     
     // 类是正在构建而仍未注册的类
     #define RW_CONSTRUCTING       (1<<26)
     
     // 类是已经构建完成并注册的类
     #define RW_CONSTRUCTED        (1<<25)
     
     // 类是load方法已经调用过的类
     #define RW_LOADED             (1<<23)
     
     #if !SUPPORT_NONPOINTER_ISA
     
     // 类是可能实例可能存在关联对象的类
     // 默认编译选项下，无需定义该位，因为都可能有关联对象
     #define RW_INSTANCES_HAVE_ASSOCIATED_OBJECTS (1<<22)
     
     #endif
     
     // 类是具有实例相关的GC layout的类
     #define RW_HAS_INSTANCE_SPECIFIC_LAYOUT (1 << 21)
     
     // 类是禁止使用关联对象的类
     #define RW_FORBIDS_ASSOCIATED_OBJECTS       (1<<20)
     
     // 类是正在注册，但是未注册完成的类
     #define RW_REALIZING          (1<<19)
     
     // 链接：https://juejin.im/post/5da17d08e51d45783a772a13
     */
    
    uint32_t version; // 标记类的类型，0表示类为非元类，7表示类为元类；

    
    /**
      类完成注册后，类的实例占用的内存大小、成员变量列表、成员变量内存布局等重要信息需要固定下来，
      这些在类注册后需要标记为只读的数据保存在class_ro_t结构体中，class_rw_t结构体的ro成员为指向该结构体的指针。
    ***/
    const class_ro_t *ro; // 保存类的只读数据，注册类后ro中的数据标记为只读，成员变量列表保存在ro中

    method_array_t methods; // 方法列表，其类型method_array_t为二维数组容器
    property_array_t properties; // 属性列表，其类型property_array_t为二维数组容器
    protocol_array_t protocols;  // 协议列表，其类型protocol_array_t为二维数组容器

    Class firstSubclass;  // 类的首个子类，与nextSiblingClass记录所有类的继承链组织成的继承树
    Class nextSiblingClass; // 类的下一个兄弟类

    char *demangledName; // 类名，来自Swift的类会包含一些特别前缀，demangledName是处理后的类名

#if SUPPORT_INDEXED_ISA // iWatch中定义
    uint32_t index; // 标记类的对象的isa是否为index类型
#endif

    // 设置set指定的位
    void setFlags(uint32_t set) 
    {
        OSAtomicOr32Barrier(set, &flags);
    }

    // 清空clear指定的位
    void clearFlags(uint32_t clear) 
    {
        OSAtomicXor32Barrier(clear, &flags);
    }

    // set and clear must not overlap
    // 设置set指定的位，清空clear指定的位
    void changeFlags(uint32_t set, uint32_t clear) 
    {
        assert((set & clear) == 0);

        uint32_t oldf, newf;
        do {
            oldf = flags;
            newf = (oldf | set) & ~clear;
        } while (!OSAtomicCompareAndSwap32Barrier(oldf, newf, (volatile int32_t *)&flags));
    }
};


struct class_data_bits_t {

    // Values are the FAST_ flags above.
    uintptr_t bits;
private:
    bool getBit(uintptr_t bit)
    {
        return bits & bit;
    }

#if FAST_ALLOC
    static uintptr_t updateFastAlloc(uintptr_t oldBits, uintptr_t change)
    {
        if (change & FAST_ALLOC_MASK) {
            if (((oldBits & FAST_ALLOC_MASK) == FAST_ALLOC_VALUE)  &&  
                ((oldBits >> FAST_SHIFTED_SIZE_SHIFT) != 0)) 
            {
                oldBits |= FAST_ALLOC;
            } else {
                oldBits &= ~FAST_ALLOC;
            }
        }
        return oldBits;
    }
#else
    static uintptr_t updateFastAlloc(uintptr_t oldBits, uintptr_t change) {
        return oldBits;
    }
#endif

    void setBits(uintptr_t set) 
    {
        uintptr_t oldBits;
        uintptr_t newBits;
        do {
            oldBits = LoadExclusive(&bits);
            newBits = updateFastAlloc(oldBits | set, set);
        } while (!StoreReleaseExclusive(&bits, oldBits, newBits));
    }

    void clearBits(uintptr_t clear) 
    {
        uintptr_t oldBits;
        uintptr_t newBits;
        do {
            oldBits = LoadExclusive(&bits);
            newBits = updateFastAlloc(oldBits & ~clear, clear);
        } while (!StoreReleaseExclusive(&bits, oldBits, newBits));
    }

public:

    class_rw_t* data() {
        return (class_rw_t *)(bits & FAST_DATA_MASK);
    }
    void setData(class_rw_t *newData)
    {
        // 仅在类注册、构建阶段才允许调用setData
        assert(!data()  ||  (newData->flags & (RW_REALIZING | RW_FUTURE)));
        // Set during realization or construction only. No locking needed.
        // Use a store-release fence because there may be concurrent
        // readers of data and data's contents.
        uintptr_t newBits = (bits & ~FAST_DATA_MASK) | (uintptr_t)newData;
        atomic_thread_fence(memory_order_release);
        bits = newBits;
    }

#if FAST_HAS_DEFAULT_RR
    bool hasDefaultRR() {
        /// class or superclass has default retain/release/autorelease/retainCount/
        ///   _tryRetain/_isDeallocating/retainWeakReference/allowsWeakReference
        return getBit(FAST_HAS_DEFAULT_RR);
    }
    void setHasDefaultRR() {
        setBits(FAST_HAS_DEFAULT_RR);
    }
    void setHasCustomRR() {
        clearBits(FAST_HAS_DEFAULT_RR);
    }
#else
    bool hasDefaultRR() {
        return data()->flags & RW_HAS_DEFAULT_RR;
    }
    void setHasDefaultRR() {
        data()->setFlags(RW_HAS_DEFAULT_RR);
    }
    void setHasCustomRR() {
        data()->clearFlags(RW_HAS_DEFAULT_RR);
    }
#endif

#if FAST_HAS_DEFAULT_AWZ
    bool hasDefaultAWZ() {
        return getBit(FAST_HAS_DEFAULT_AWZ);
    }
    void setHasDefaultAWZ() {
        setBits(FAST_HAS_DEFAULT_AWZ);
    }
    void setHasCustomAWZ() {
        clearBits(FAST_HAS_DEFAULT_AWZ);
    }
#else
    bool hasDefaultAWZ() {
        return data()->flags & RW_HAS_DEFAULT_AWZ;
    }
    void setHasDefaultAWZ() {
        data()->setFlags(RW_HAS_DEFAULT_AWZ);
    }
    void setHasCustomAWZ() {
        data()->clearFlags(RW_HAS_DEFAULT_AWZ);
    }
#endif

#if FAST_HAS_CXX_CTOR
    bool hasCxxCtor() {
        return getBit(FAST_HAS_CXX_CTOR);
    }
    void setHasCxxCtor() {
        setBits(FAST_HAS_CXX_CTOR);
    }
#else
    bool hasCxxCtor() {
        return data()->flags & RW_HAS_CXX_CTOR;
    }
    void setHasCxxCtor() {
        data()->setFlags(RW_HAS_CXX_CTOR);
    }
#endif

#if FAST_HAS_CXX_DTOR
    bool hasCxxDtor() {
        return getBit(FAST_HAS_CXX_DTOR);
    }
    void setHasCxxDtor() {
        setBits(FAST_HAS_CXX_DTOR);
    }
#else
    bool hasCxxDtor() {
        return data()->flags & RW_HAS_CXX_DTOR;
    }
    void setHasCxxDtor() {
        data()->setFlags(RW_HAS_CXX_DTOR);
    }
#endif

// 是否支持非指针类型isa
    
#if FAST_REQUIRES_RAW_ISA
    bool instancesRequireRawIsa() {
        return getBit(FAST_REQUIRES_RAW_ISA);
    }
    void setInstancesRequireRawIsa() {
        setBits(FAST_REQUIRES_RAW_ISA);
    }
#elif SUPPORT_NONPOINTER_ISA
    // 主流机型一般走到这个编译分支
    bool instancesRequireRawIsa() {
        return data()->flags & RW_REQUIRES_RAW_ISA;
    }
    void setInstancesRequireRawIsa() {
        data()->setFlags(RW_REQUIRES_RAW_ISA);
    }
#else
    bool instancesRequireRawIsa() {
        return true;
    }
    void setInstancesRequireRawIsa() {
        // nothing
    }
#endif

#if FAST_ALLOC
    size_t fastInstanceSize() 
    {
        assert(bits & FAST_ALLOC);
        return (bits >> FAST_SHIFTED_SIZE_SHIFT) * 16;
    }
    void setFastInstanceSize(size_t newSize) 
    {
        // Set during realization or construction only. No locking needed.
        assert(data()->flags & RW_REALIZING);

        // Round up to 16-byte boundary, then divide to get 16-byte units
        newSize = ((newSize + 15) & ~15) / 16;
        
        uintptr_t newBits = newSize << FAST_SHIFTED_SIZE_SHIFT;
        if ((newBits >> FAST_SHIFTED_SIZE_SHIFT) == newSize) {
            int shift = WORD_BITS - FAST_SHIFTED_SIZE_SHIFT;
            uintptr_t oldBits = (bits << shift) >> shift;
            if ((oldBits & FAST_ALLOC_MASK) == FAST_ALLOC_VALUE) {
                newBits |= FAST_ALLOC;
            }
            bits = oldBits | newBits;
        }
    }

    bool canAllocFast() {
        return bits & FAST_ALLOC;
        // # define FAST_ALLOC  (1UL<<2)
        // summary bit for fast alloc path: !hasCxxCtor and
        // !instancesRequireRawIsa and instanceSize fits into shiftedSize
    }
#else
    size_t fastInstanceSize() {
        abort();
    }
    void setFastInstanceSize(size_t) {
        // nothing
    }
    bool canAllocFast() {
        return false;
    }
#endif

    void setClassArrayIndex(unsigned Idx) {
#if SUPPORT_INDEXED_ISA
        // 0 is unused as then we can rely on zero-initialisation from calloc.
        assert(Idx > 0);
        data()->index = Idx;
#endif
    }

    unsigned classArrayIndex() {
#if SUPPORT_INDEXED_ISA
        return data()->index;
#else
        return 0;
#endif
    }

    bool isAnySwift() {
        return isSwiftStable() || isSwiftLegacy();
    }

    bool isSwiftStable() {
        return getBit(FAST_IS_SWIFT_STABLE);
    }
    void setIsSwiftStable() {
        setBits(FAST_IS_SWIFT_STABLE);
    }

    bool isSwiftLegacy() {
        return getBit(FAST_IS_SWIFT_LEGACY);
    }
    void setIsSwiftLegacy() {
        setBits(FAST_IS_SWIFT_LEGACY);
    }
};


struct objc_class : objc_object {
    // Class ISA;     // 元类
    Class superclass; // 父类
    
    // 类使用哈希表数据结构缓存最近调用方法，以提高方法查找效率
    cache_t cache;             // formerly cache pointer and vtable
    
    /// class_data_bits_t结构体类型，该结构体主要用于记录，保存类的数据的class_rw_t结构体的内存地址。
    /// 通过data()方法访问bits的有效位域指向的内存空间，返回class_rw_t结构体；setData(class_rw_t *newData)用于设置bits的值；
    class_data_bits_t bits;    // class_rw_t * plus custom rr/alloc flags

    /**
     类的数据主要保存在class_data_bits_t结构体中，其成员仅有一个bits指针。
     objc_class的data()方法用于获取bits成员的 4~47 位域（FAST_DATA_MASK）中保存的class_rw_t结构体地址。
     类的数据保存在class_rw_t结构体中，剩余的部分保存在ro指针指向的class_ro_t结构体中。
     class_rw_t、class_ro_t结构体名中，rw是 read write 的缩写，ro是 read only 的缩写，可见class_ro_t的保存类的只读信息，这些信息在类完成注册后不可改变。
     以类的成员变量列表为例（成员变量列表保存在class_ro_t结构体中）。
     若应用类注册到内存后，使用类构建了若干实例，此时若添加成员变量必然需要对内存中的这些类重新分配内存，这个操作的花销是相当大的。
     若考虑再极端一些，为根类NSObject添加成员变量，则内存中基本所有 Objective-C 对象都需要重新分配内存，如此庞大的计算量在运行时是不可接受的
     */
    
    
    // 获取类的数据
    class_rw_t *data() { 
        return bits.data();
    }
    
    // 设置类的数据
    void setData(class_rw_t *newData) {
        bits.setData(newData);
    }

    void setInfo(uint32_t set) {
        assert(isFuture()  ||  isRealized());
        data()->setFlags(set);
    }

    void clearInfo(uint32_t clear) {
        assert(isFuture()  ||  isRealized());
        data()->clearFlags(clear);
    }

    // set and clear must not overlap
    void changeInfo(uint32_t set, uint32_t clear) {
        assert(isFuture()  ||  isRealized());
        assert((set & clear) == 0);
        data()->changeFlags(set, clear);
    }

    bool hasCustomRR() {
        return ! bits.hasDefaultRR();
    }
    void setHasDefaultRR() {
        assert(isInitializing());
        bits.setHasDefaultRR();
    }
    void setHasCustomRR(bool inherited = false);
    void printCustomRR(bool inherited);

    bool hasCustomAWZ() {
        return ! bits.hasDefaultAWZ();
    }
    void setHasDefaultAWZ() {
        assert(isInitializing());
        bits.setHasDefaultAWZ();
    }
    void setHasCustomAWZ(bool inherited = false);
    void printCustomAWZ(bool inherited);

    bool instancesRequireRawIsa() {
        return bits.instancesRequireRawIsa();
    }
    void setInstancesRequireRawIsa(bool inherited = false);
    void printInstancesRequireRawIsa(bool inherited);

    bool canAllocNonpointer() {
        assert(!isFuture());
        return !instancesRequireRawIsa();
    }
    bool canAllocFast() {
        assert(!isFuture());
        return bits.canAllocFast();
    }


    bool hasCxxCtor() {
        // addSubclass() propagates this flag from the superclass.
        assert(isRealized());
        return bits.hasCxxCtor();
    }
    void setHasCxxCtor() { 
        bits.setHasCxxCtor();
    }

    bool hasCxxDtor() {
        // addSubclass() propagates this flag from the superclass.
        assert(isRealized());
        return bits.hasCxxDtor();
    }
    void setHasCxxDtor() { 
        bits.setHasCxxDtor();
    }


    bool isSwiftStable() {
        return bits.isSwiftStable();
    }

    bool isSwiftLegacy() {
        return bits.isSwiftLegacy();
    }

    bool isAnySwift() {
        return bits.isAnySwift();
    }


    // Return YES if the class's ivars are managed by ARC, 
    // or the class is MRC but has ARC-style weak ivars.
    bool hasAutomaticIvars() {
        return data()->ro->flags & (RO_IS_ARC | RO_HAS_WEAK_WITHOUT_ARC);
    }

    // Return YES if the class's ivars are managed by ARC.
    bool isARC() {
        return data()->ro->flags & RO_IS_ARC;
    }


#if SUPPORT_NONPOINTER_ISA
    // Tracked in non-pointer isas; not tracked otherwise
#else
    bool instancesHaveAssociatedObjects() {
        // this may be an unrealized future class in the CF-bridged case
        assert(isFuture()  ||  isRealized());
        return data()->flags & RW_INSTANCES_HAVE_ASSOCIATED_OBJECTS;
    }

    void setInstancesHaveAssociatedObjects() {
        // this may be an unrealized future class in the CF-bridged case
        assert(isFuture()  ||  isRealized());
        setInfo(RW_INSTANCES_HAVE_ASSOCIATED_OBJECTS);
    }
#endif

    bool shouldGrowCache() {
        return true;
    }

    void setShouldGrowCache(bool) {
        // fixme good or bad for memory use?
    }
    
    // 查询是否正在初始化（initializing）
    bool isInitializing() {
        return getMeta()->data()->flags & RW_INITIALIZING;
    }
    
    // 标记为正在初始化（initializing）
    void setInitializing() {
        assert(!isMetaClass());
        ISA()->setInfo(RW_INITIALIZING);
    }

    // 是否已完成初始化（initializing）
    bool isInitialized() {
        return getMeta()->data()->flags & RW_INITIALIZED;
    }

    // 实现写在.mm文件中
    void setInitialized();

    bool isLoadable() {
        assert(isRealized());
        return true;  // any class registered for +load is definitely loadable
    }

    // 实现写在.mm文件中
    IMP getLoadMethod();

    // Locking: To prevent concurrent realization, hold runtimeLock.
    // runtime是否已认识类
    bool isRealized() {
        return data()->flags & RW_REALIZED;
    }

    // Returns true if this is an unrealized future class.
    // Locking: To prevent concurrent realization, hold runtimeLock.
    
    // 是否future class
    bool isFuture() { 
        return data()->flags & RW_FUTURE;
    }

    bool isMetaClass() {
        assert(this);
        assert(isRealized());
        return data()->ro->flags & RO_META;
    }

    // NOT identical to this->ISA when this is a metaclass
    Class getMeta() {
        if (isMetaClass()) return (Class)this;
        else return this->ISA();
    }

    bool isRootClass() {
        return superclass == nil;
    }
    bool isRootMetaclass() {
        return ISA() == (Class)this;
    }

    const char *mangledName() { 
        // fixme can't assert locks here
        assert(this);

        if (isRealized()  ||  isFuture()) {
            return data()->ro->name;
        } else {
            return ((const class_ro_t *)data())->name;
        }
    }
    
    const char *demangledName(bool realize = false);
    const char *nameForLogging();

    // May be unaligned depending on class's ivars.
    uint32_t unalignedInstanceStart() {
        assert(isRealized());
        return data()->ro->instanceStart;
    }

    // Class's instance start rounded up to a pointer-size boundary.
    // This is used for ARC layout bitmaps.
    uint32_t alignedInstanceStart() {
        return word_align(unalignedInstanceStart());
    }

    // May be unaligned depending on class's ivars.
    uint32_t unalignedInstanceSize() {
        assert(isRealized());
        return data()->ro->instanceSize;
    }

    // Class's ivar size rounded up to a pointer-size boundary.
    uint32_t alignedInstanceSize() {
        return word_align(unalignedInstanceSize());
    }

    size_t instanceSize(size_t extraBytes) {
        size_t size = alignedInstanceSize() + extraBytes;
        // CF requires all objects be at least 16 bytes.
        if (size < 16) size = 16;
        return size;
    }

    void setInstanceSize(uint32_t newSize) {
        assert(isRealized());
        if (newSize != data()->ro->instanceSize) {
            assert(data()->flags & RW_COPIED_RO);
            *const_cast<uint32_t *>(&data()->ro->instanceSize) = newSize;
        }
        bits.setFastInstanceSize(newSize);
    }

    void chooseClassArrayIndex();

    void setClassArrayIndex(unsigned Idx) {
        bits.setClassArrayIndex(Idx);
    }

    unsigned classArrayIndex() {
        return bits.classArrayIndex();
    }

};


struct swift_class_t : objc_class {
    uint32_t flags;
    uint32_t instanceAddressOffset;
    uint32_t instanceSize;
    uint16_t instanceAlignMask;
    uint16_t reserved;

    uint32_t classSize;
    uint32_t classAddressOffset;
    void *description;
    // ...

    void *baseAddress() {
        return (void *)((uint8_t *)this - classAddressOffset);
    }
};

/**
 分类是对 Objective-C 类的一种扩展方式。说到分类不可不提扩展（Extension）。扩展通常被视为匿名的分类，但是两者实现的区别还是很大的：

 扩展只是对接口的扩展，所有实现还是在类的@implementation块中，分类是对接口以及实现的扩展，分类的实现在@implementation(CategoryName)块中；
 分类在 Runtime 中有category_t结构体与之对应，而扩展则没有；
 扩展是编译时决议，分类是运行时决议，分类在运行加载阶段才载入方法列表中；


 注意：分类是装饰器模式。用分类扩展的好处是：对父类的扩展可以直接作用于其所有的衍生类。


 
 分类的数据结构是category_t结构体。包含了分类名称name，分类所扩展的类cls，分类实现的实例方法列表instanceMethods，分类实现的类方法列表classMethods，分类遵循的协议列表protocols，分类定义的属性列表instanceProperties。
 
 
 类并不包含像分类列表这样的数据结构
 category_t结构体只是为了在编译阶段记录开发者定义的分类，并将其保存到特定的容器中。
 但是程序本身则需要保存分类列表，因为加载程序时，需要按照容器内记录的分类信息依次加载分类。
 保存应用定义的所有分类的容器是category_list，也是locstamped_category_list_t的别名。
 locstamped_category_list_t是顺序表容器，元素为locstamped_category_t结构体。locstamped_category_t结构体包含指向category_t结构体的cat成员。

 */

struct category_t {
    const char *name;
    classref_t cls;
    struct method_list_t *instanceMethods;
    struct method_list_t *classMethods;
    struct protocol_list_t *protocols;
    struct property_list_t *instanceProperties;
    // Fields below this point are not always present on disk.
    struct property_list_t *_classProperties;

    method_list_t *methodsForMeta(bool isMeta) {
        if (isMeta) return classMethods;
        else return instanceMethods;
    }

    property_list_t *propertiesForMeta(bool isMeta, struct header_info *hi);
};

struct objc_super2 {
    id receiver;
    Class current_class;
};

struct message_ref_t {
    IMP imp;
    SEL sel;
};


extern Method protocol_getMethod(protocol_t *p, SEL sel, bool isRequiredMethod, bool isInstanceMethod, bool recursive);

static inline void
foreach_realized_class_and_subclass_2(Class top, unsigned& count,
                                      std::function<bool (Class)> code) 
{
    // runtimeLock.assertLocked();
    assert(top);
    Class cls = top;
    while (1) {
        if (--count == 0) {
            _objc_fatal("Memory corruption in class list.");
        }
        if (!code(cls)) break;

        if (cls->data()->firstSubclass) {
            cls = cls->data()->firstSubclass;
        } else {
            while (!cls->data()->nextSiblingClass  &&  cls != top) {
                cls = cls->superclass;
                if (--count == 0) {
                    _objc_fatal("Memory corruption in class list.");
                }
            }
            if (cls == top) break;
            cls = cls->data()->nextSiblingClass;
        }
    }
}

extern Class firstRealizedClass();
extern unsigned int unreasonableClassCount();

// Enumerates a class and all of its realized subclasses.
static inline void
foreach_realized_class_and_subclass(Class top,
                                    std::function<void (Class)> code)
{
    unsigned int count = unreasonableClassCount();

    foreach_realized_class_and_subclass_2(top, count,
                                          [&code](Class cls) -> bool
    {
        code(cls);
        return true; 
    });
}

// Enumerates all realized classes and metaclasses.
static inline void
foreach_realized_class_and_metaclass(std::function<void (Class)> code) 
{
    unsigned int count = unreasonableClassCount();
    
    for (Class top = firstRealizedClass(); 
         top != nil; 
         top = top->data()->nextSiblingClass) 
    {
        foreach_realized_class_and_subclass_2(top, count,
                                              [&code](Class cls) -> bool
        {
            code(cls);
            return true; 
        });
    }

}

#endif
