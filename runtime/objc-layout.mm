/*
 * Copyright (c) 2004-2008 Apple Inc. All rights reserved.
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

#include <stdlib.h>
#include <assert.h>

#include "objc-private.h"

/**********************************************************************
* Object Layouts.
*
* Layouts are used by the garbage collector to identify references from
* the object to other objects.
* 
* Layout information is in the form of a '\0' terminated byte string. 
* Each byte contains a word skip count in the high nibble and a
* consecutive references count in the low nibble. Counts that exceed 15 are
* continued in the succeeding byte with a zero in the opposite nibble. 
* Objects that should be scanned conservatively will have a NULL layout.
* Objects that have no references have a empty byte string.
*
* Example;
* 
*   For a class with pointers at offsets 4,12, 16, 32-128
*   the layout is { 0x11, 0x12, 0x3f, 0x0a, 0x00 } or
*       skip 1 - 1 reference (4)
*       skip 1 - 2 references (12, 16)
*       skip 3 - 15 references (32-88)
*       no skip - 10 references (92-128)
*       end
 
  
  一下解释来自: https://juejin.im/post/5da2a0f2e51d45780e4cea1c#heading-4
  Runtime中用layout_bitmap结构体表示压缩前的ivarLayout，保存的是一个二进制数，
  二进制数每一位标记类的成员变量空间（instanceStart为起始instanceSize大小的内存空间）中，对应位置的 WORD  是否存储了id类型成员变量。例如，二进制数0101表示成员第二个、第四个成员变量是id类型
  
 
  某个对象占用的内存空间: 数据1-4表示使用的空间 空白区域表示未使用的空间
                 在内存地址偏移量为 4-8 12-16 16-20 32-132处保存有数据
                 根据构建规则构建layout bitmap的bits,bits的有效位数为 132/4 = 33位，需要分配 33/8 = 5个字节。因此最高7位为无效位
  
 如下32位机器（WORD为4个字节）中某个对象占用的内存空间 注意此处的地址以WORD为单位
 
                 ----------------------------------------
                    xxxxxxxxxx 其他 xxxxxxxxxx
  0x100BB134084  ----------------------------------------
                        数据4
  0x100BB134020  ----------------------------------------
 
  0x100BB134014  ----------------------------------------
                        数据3
  0x100BB134010  ----------------------------------------
                        数据2
  0x100BB13400C  ----------------------------------------
 
  0x100BB134008  ----------------------------------------
                        数据1
  0x100BB134004  ----------------------------------------
                    
  0x100BB134000  ----------------------------------------
                    xxxxxxxxxx 其他 xxxxxxxxxx
                 ----------------------------------------
 
  compress_layout算法

  步骤一、 分配layout bitmap的5个字节空间如下 高7位无效
 
          xxxxxxx0 00000000 00000000 00000000  00000000
  
  步骤二、根据成员变量列表构建bits
 
        由于在4-8保存了数据，因此实例内存空间的第2个WORD被使用，于是将bits的第2个位置置为1
          xxxxxxx0 00000000 00000000 00000000  00000010
         
        由于在12-16保存了数据，因此实例内存空间的第4个WORD被使用，于是将bits的第4个位置置为1
          xxxxxxx0 00000000 00000000 00000000  00001010
        
        由于在16-20保存了数据，因此实例内存空间的第5个WORD被使用，于是将bits的第4个位置置为1
          xxxxxxx0 00000000 00000000 00000000  00011010
        
        同理
          xxxxxxx0 11111111 11111111 11111111  00011010
 
  步骤三、
        压缩layout bitmap第一次迭代,找到第一摞来续的0第一摞连续的1。连续0个数为1即 skip=1, 连续1个数为1即 scan=1 因此第一次迭代得到 0x11
 
        压缩layout bitmap第二次迭代,找到第一摞来续的0第一摞连续的1。连续0个数为1即 skip=1, 连续1个数为2即 scan=2 因此第一次迭代得到 0x12
        
        压缩layout bitmap第三次迭代,找到第一摞来续的0第一摞连续的1。连续0个数为3即 skip=3。 注意因为skip和scan都使用4bit表示，所以值不能大于15，当skip或scan大于15时本次迭代必须结束，因此本次迭代scan=15,得到 0x3f
  
        压缩layout bitmap第四次迭代,找到第一摞来续的0第一摞连续的1。连续0个数为0即 skip=0。连续1个数为10即 scan=10 因此第一次迭代得到 0x0a
 
 步骤四、
        综合每次迭代结果依次串联，并以0x00结尾，得到iVarLayout为{0x11 0x12 0x3f 0x0a 0x00}
        
        ---------------------------------
        |        IvarLayout             |            |
        |                               |
        |    0x11 0x12 0x3f 0x0a 0x00   |
        |                               |
        ---------------------------------
 
**********************************************************************/


/**********************************************************************
* compress_layout
* Allocates and returns a compressed string matching the given layout bitmap.
 
 类的ivarLayout是layout_bitmap压缩后得到的十六进制数，layout_bitmap压缩调用compress_layout(...)实现。
 其中bits参数指向保存layout_bitmap的内存；bitmap_bits参数为二进制数的位数；weak参数表示bits数据是否为weakIvarLayout。
**********************************************************************/
static unsigned char *
compress_layout(const uint8_t *bits, size_t bitmap_bits, bool weak)
{
    bool all_set = YES;
    bool none_set = YES;
    unsigned char *result;

    // overallocate a lot; reallocate at correct size later
    // 多分配些额外的位
    unsigned char * const layout = (unsigned char *)
        calloc(bitmap_bits + 1, 1);
    unsigned char *l = layout;

    size_t i = 0;
    while (i < bitmap_bits) {
        size_t skip = 0;
        size_t scan = 0;

        // Count one range each of skip and scan.
        while (i < bitmap_bits) {
            // skip为本次循环二进制数连续的0位数，scan为连续的1位数
            uint8_t bit = (uint8_t)((bits[i/8] >> (i % 8)) & 1);
            if (bit) break;
            i++;
            skip++;
        }
        while (i < bitmap_bits) {
            uint8_t bit = (uint8_t)((bits[i/8] >> (i % 8)) & 1);
            if (!bit) break;
            i++;
            scan++;
            none_set = NO;
        }

        // Record skip and scan
        // skip和scan的值均不能超过15，超过15则立即进行分割
        if (skip) all_set = NO;
        if (scan) none_set = NO;
        while (skip > 0xf) {
            *l++ = 0xf0;
            skip -= 0xf;
        }
        if (skip || scan) {
            *l = (uint8_t)(skip << 4);    // NOT incremented - merges with scan
            while (scan > 0xf) {
                *l++ |= 0x0f;  // May merge with short skip; must calloc
                scan -= 0xf;
            }
            *l++ |= scan;      // NOT checked for zero - always increments
                               // May merge with short skip; must calloc
        }
    }
    
    // insert terminating byte
     // 插入终止字节
    *l++ = '\0';
    
    // return result
    if (none_set  &&  weak) {
        result = NULL;  // NULL weak layout means none-weak
    } else if (all_set  &&  !weak) {
        result = NULL;  // NULL ivar layout means all-scanned
    } else {
        result = (unsigned char *)strdup((char *)layout); 
    }
    free(layout);
    return result;
}


static void set_bits(layout_bitmap bits, size_t which, size_t count)
{
    // fixme optimize for byte/word at a time
    size_t bit;
    for (bit = which; bit < which + count  &&  bit < bits.bitCount; bit++) {
        bits.bits[bit/8] |= 1 << (bit % 8);
    }
    if (bit == bits.bitCount  &&  bit < which + count) {
        // couldn't fit full type in bitmap
        _objc_fatal("layout bitmap too short");
    }
}

static void clear_bits(layout_bitmap bits, size_t which, size_t count)
{
    // fixme optimize for byte/word at a time
    size_t bit;
    for (bit = which; bit < which + count  &&  bit < bits.bitCount; bit++) {
        bits.bits[bit/8] &= ~(1 << (bit % 8));
    }
    if (bit == bits.bitCount  &&  bit < which + count) {
        // couldn't fit full type in bitmap
        _objc_fatal("layout bitmap too short");
    }
}

static void move_bits(layout_bitmap bits, size_t src, size_t dst, 
                      size_t count)
{
    // fixme optimize for byte/word at a time

    if (dst == src) {
        return;
    }
    else if (dst > src) {
        // Copy backwards in case of overlap
        size_t pos = count;
        while (pos--) {
            size_t srcbit = src + pos;
            size_t dstbit = dst + pos;
            if (bits.bits[srcbit/8] & (1 << (srcbit % 8))) {
                bits.bits[dstbit/8] |= 1 << (dstbit % 8);
            } else {
                bits.bits[dstbit/8] &= ~(1 << (dstbit % 8));
            }
        }
    }
    else {
        // Copy forwards in case of overlap
        size_t pos;
        for (pos = 0; pos < count; pos++) {
            size_t srcbit = src + pos;
            size_t dstbit = dst + pos;
            if (bits.bits[srcbit/8] & (1 << (srcbit % 8))) {
                bits.bits[dstbit/8] |= 1 << (dstbit % 8);
            } else {
                bits.bits[dstbit/8] &= ~(1 << (dstbit % 8));
            }
        }
    }
}

// emacs autoindent hack - it doesn't like the loop in set_bits/clear_bits
#if 0
} }
#endif

/**
 调用decompress_layout(...)解压缩ivarLayout，为压缩的逆过程。
 例如，增加成员变量时需要更新ivarLayout，此时需要先解压ivarLayout的十六进制数得到layout_bitmap，然后更新layout_bitmap数据，最后压缩layout_bitmap得到十六进制数保存到ivarLayout。

 作者：Luminix
 链接：https://juejin.im/post/5da2a0f2e51d45780e4cea1c
 来源：掘金
 */
static void decompress_layout(const unsigned char *layout_string, layout_bitmap bits)
{
    unsigned char c;
    size_t bit = 0;
    while ((c = *layout_string++)) {
        unsigned char skip = (c & 0xf0) >> 4;
        unsigned char scan = (c & 0x0f);
        bit += skip;
        set_bits(bits, bit, scan);
        bit += scan;
    }
}


/***********************************************************************
* layout_bitmap_create
* Allocate a layout bitmap.
* The new bitmap spans the given instance size bytes.
* The start of the bitmap is filled from the given layout string (which 
*   spans an instance size of layoutStringSize); the rest is zero-filled.
* The returned bitmap must be freed with layout_bitmap_free().
**********************************************************************/
layout_bitmap 
layout_bitmap_create(const unsigned char *layout_string,
                     size_t layoutStringInstanceSize, 
                     size_t instanceSize, bool weak)
{
    layout_bitmap result;
    size_t words = instanceSize / sizeof(id);
    
    result.weak = weak;
    result.bitCount = words;
    result.bitsAllocated = words;
    result.bits = (uint8_t *)calloc((words+7)/8, 1);

    if (!layout_string) {
        if (!weak) {
            // NULL ivar layout means all-scanned
            // (but only up to layoutStringSize instance size)
            set_bits(result, 0, layoutStringInstanceSize/sizeof(id));
        } else {
            // NULL weak layout means none-weak.
        }
    } else {
        decompress_layout(layout_string, result);
    }

    return result;
}


/***********************************************************************
 * layout_bitmap_create_empty
 * Allocate a layout bitmap.
 * The new bitmap spans the given instance size bytes.
 * The bitmap is empty, to represent an object whose ivars are completely unscanned.
 * The returned bitmap must be freed with layout_bitmap_free().
 **********************************************************************/
layout_bitmap
layout_bitmap_create_empty(size_t instanceSize, bool weak)
{
    layout_bitmap result;
    size_t words = instanceSize / sizeof(id);
    
    result.weak = weak;
    result.bitCount = words;
    result.bitsAllocated = words;
    result.bits = (uint8_t *)calloc((words+7)/8, 1);

    return result;
}

void 
layout_bitmap_free(layout_bitmap bits)
{
    if (bits.bits) free(bits.bits);
}

const unsigned char * 
layout_string_create(layout_bitmap bits)
{
    const unsigned char *result =
        compress_layout(bits.bits, bits.bitCount, bits.weak);

#if DEBUG
    // paranoia: cycle to bitmap and back to string again, and compare
    layout_bitmap check = layout_bitmap_create(result, bits.bitCount*sizeof(id), 
                                               bits.bitCount*sizeof(id), bits.weak);
    unsigned char *result2 = 
        compress_layout(check.bits, check.bitCount, check.weak);
    if (result != result2  &&  0 != strcmp((char*)result, (char *)result2)) {
        layout_bitmap_print(bits);
        layout_bitmap_print(check);
        _objc_fatal("libobjc bug: mishandled layout bitmap");
    }
    free(result2);
    layout_bitmap_free(check);
#endif

    return result;
}

/**
    设置成员变量对应的ivarLayout、weakIvarLayout位调用layout_bitmap_set_ivar(...)函数。
    其中bits参数为类的当前ivarLayout或weakIvarLayout；type参数成员变量的类型编码；offset为成员变量的offset。
 */
void
layout_bitmap_set_ivar(layout_bitmap bits, const char *type, size_t offset)
{
    // fixme only handles some types
    size_t bit = offset / sizeof(id);

    if (!type) return;
    if (type[0] == '@'  ||  0 == strcmp(type, "^@")) {
        // id
        // id *
        // Block ("@?")
        set_bits(bits, bit, 1);
    } 
    else if (type[0] == '[') {
        // id[]
        char *t;
        unsigned long count = strtoul(type+1, &t, 10);
        if (t  &&  t[0] == '@') {
            set_bits(bits, bit, count);
        }
    } 
    else if (strchr(type, '@')) {
        _objc_inform("warning: failing to set GC layout for '%s'\n", type);
    }
}



/***********************************************************************
* layout_bitmap_grow
* Expand a layout bitmap to span newCount bits. 
* The new bits are undefined.
**********************************************************************/
void 
layout_bitmap_grow(layout_bitmap *bits, size_t newCount)
{
    if (bits->bitCount >= newCount) return;
    bits->bitCount = newCount;
    if (bits->bitsAllocated < newCount) {
        size_t newAllocated = bits->bitsAllocated * 2;
        if (newAllocated < newCount) newAllocated = newCount;
        bits->bits = (uint8_t *)
            realloc(bits->bits, (newAllocated+7) / 8);
        bits->bitsAllocated = newAllocated;
    }
    assert(bits->bitsAllocated >= bits->bitCount);
    assert(bits->bitsAllocated >= newCount);
}


/***********************************************************************
* layout_bitmap_slide
* Slide the end of a layout bitmap farther from the start.
* Slides bits [oldPos, bits.bitCount) to [newPos, bits.bitCount+newPos-oldPos)
* Bits [oldPos, newPos) are zero-filled.
* The bitmap is expanded and bitCount updated if necessary.
* newPos >= oldPos.
**********************************************************************/
void
layout_bitmap_slide(layout_bitmap *bits, size_t oldPos, size_t newPos)
{
    size_t shift;
    size_t count;

    if (oldPos == newPos) return;
    if (oldPos > newPos) _objc_fatal("layout bitmap sliding backwards");

    shift = newPos - oldPos;
    count = bits->bitCount - oldPos;
    layout_bitmap_grow(bits, bits->bitCount + shift);
    move_bits(*bits, oldPos, newPos, count);  // slide
    clear_bits(*bits, oldPos, shift);         // zero-fill
}


/***********************************************************************
* layout_bitmap_slide_anywhere
* Slide the end of a layout bitmap relative to the start.
* Like layout_bitmap_slide, but can slide backwards too.
* The end of the bitmap is truncated.
**********************************************************************/
void
layout_bitmap_slide_anywhere(layout_bitmap *bits, size_t oldPos, size_t newPos)
{
    size_t shift;
    size_t count;

    if (oldPos == newPos) return;

    if (oldPos < newPos) {
        layout_bitmap_slide(bits, oldPos, newPos);
        return;
    } 

    shift = oldPos - newPos;
    count = bits->bitCount - oldPos;
    move_bits(*bits, oldPos, newPos, count);  // slide
    bits->bitCount -= shift;
}


/***********************************************************************
* layout_bitmap_splat
* Pastes the contents of bitmap src to the start of bitmap dst.
* dst bits between the end of src and oldSrcInstanceSize are zeroed.
* dst must be at least as long as src.
* Returns YES if any of dst's bits were changed.
**********************************************************************/
bool
layout_bitmap_splat(layout_bitmap dst, layout_bitmap src, 
                    size_t oldSrcInstanceSize)
{
    bool changed;
    size_t oldSrcBitCount;
    size_t bit;

    if (dst.bitCount < src.bitCount) _objc_fatal("layout bitmap too short");

    changed = NO;
    oldSrcBitCount = oldSrcInstanceSize / sizeof(id);
    
    // fixme optimize for byte/word at a time
    for (bit = 0; bit < oldSrcBitCount; bit++) {
        int dstset = dst.bits[bit/8] & (1 << (bit % 8));
        int srcset = (bit < src.bitCount) 
            ? src.bits[bit/8] & (1 << (bit % 8))
            : 0;
        if (dstset != srcset) {
            changed = YES;
            if (srcset) {
                dst.bits[bit/8] |= 1 << (bit % 8);
            } else {
                dst.bits[bit/8] &= ~(1 << (bit % 8));
            }
        }
    }

    return changed;
}


/***********************************************************************
* layout_bitmap_or
* Set dst=dst|src.
* dst must be at least as long as src.
* Returns YES if any of dst's bits were changed.
**********************************************************************/
bool
layout_bitmap_or(layout_bitmap dst, layout_bitmap src, const char *msg)
{
    bool changed = NO;
    size_t bit;

    if (dst.bitCount < src.bitCount) {
        _objc_fatal("layout_bitmap_or: layout bitmap too short%s%s", 
                    msg ? ": " : "", msg ? msg : "");
    }
    
    // fixme optimize for byte/word at a time
    for (bit = 0; bit < src.bitCount; bit++) {
        int dstset = dst.bits[bit/8] & (1 << (bit % 8));
        int srcset = src.bits[bit/8] & (1 << (bit % 8));
        if (srcset  &&  !dstset) {
            changed = YES;
            dst.bits[bit/8] |= 1 << (bit % 8);
        }
    }

    return changed;
}


/***********************************************************************
* layout_bitmap_clear
* Set dst=dst&~src.
* dst must be at least as long as src.
* Returns YES if any of dst's bits were changed.
**********************************************************************/
bool
layout_bitmap_clear(layout_bitmap dst, layout_bitmap src, const char *msg)
{
    bool changed = NO;
    size_t bit;

    if (dst.bitCount < src.bitCount) {
        _objc_fatal("layout_bitmap_clear: layout bitmap too short%s%s", 
                    msg ? ": " : "", msg ? msg : "");
    }
    
    // fixme optimize for byte/word at a time
    for (bit = 0; bit < src.bitCount; bit++) {
        int dstset = dst.bits[bit/8] & (1 << (bit % 8));
        int srcset = src.bits[bit/8] & (1 << (bit % 8));
        if (srcset  &&  dstset) {
            changed = YES;
            dst.bits[bit/8] &= ~(1 << (bit % 8));
        }
    }

    return changed;
}


void
layout_bitmap_print(layout_bitmap bits)
{
    size_t i;
    printf("%zu: ", bits.bitCount);
    for (i = 0; i < bits.bitCount; i++) {
        int set = bits.bits[i/8] & (1 << (i % 8));
        printf("%c", set ? '#' : '.');
    }
    printf("\n");
}

#if 0
// The code below may be useful when interpreting ivar types more precisely.

/**********************************************************************
* mark_offset_for_layout
*
* Marks the appropriate bit in the bits array cooresponding to a the
* offset of a reference.  If we are scanning a nested pointer structure
* then the bits array will be NULL then this function does nothing.  
* 
**********************************************************************/
static void mark_offset_for_layout(long offset, long bits_size, unsigned char *bits) {
    // references are ignored if bits is NULL
    if (bits) {
        long slot = offset / sizeof(long);
        
        // determine byte index using (offset / 8 bits per byte)
        long i_byte = slot >> 3;
        
        // if the byte index is valid 
        if (i_byte < bits_size) {
            // set the (offset / 8 bits per byte)th bit
            bits[i_byte] |= 1 << (slot & 7);
        } else {
            // offset not within instance size
            _objc_inform ("layout - offset exceeds instance size");
        }
    }
}

/**********************************************************************
* skip_ivar_type_name
*
* Skip over the name of a field/class in an ivar type string.  Names
* are in the form of a double-quoted string.  Returns the remaining
* string.
*
**********************************************************************/
static char *skip_ivar_type_name(char *type) {
    // current character
    char ch;
    
    // if there is an open quote
    if (*type == '\"') {
        // skip quote
        type++;
        
        // while no closing quote
        while ((ch = *type) != '\"') {
            // if end of string return end of string
            if (!ch) return type;
            
            // skip character
            type++;
        }
        
        // skip closing quote
        type++;
    }
    
    // return remaining string
    return type;
}


/**********************************************************************
* skip_ivar_struct_name
*
* Skip over the name of a struct in an ivar type string.  Names
* may be followed by an equals sign.  Returns the remaining string.
*
**********************************************************************/
static char *skip_ivar_struct_name(char *type) {
    // get first character
    char ch = *type;
    
    if (ch == _C_UNDEF) {
        // skip undefined name 
        type++;
    } else if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_') {
        // if alphabetic
        
        // scan alphanumerics
        do {
            // next character
            ch = *++type;
        } while ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_' || (ch >= '0' && ch <= '9'));
    } else {
        // no struct name present
        return type;
    }
    
    // skip equals sign
    if (*type == '=') type++;
    
    return type;
}


/**********************************************************************
* scan_basic_ivar_type
* 
* Determines the size and alignment of a basic ivar type.  If the basic
* type is a possible reference to another garbage collected type the 
* is_reference is set to true (false otherwise.)  Returns the remaining
* string.
* 
**********************************************************************/
static char *scan_ivar_type_for_layout(char *type, long offset, long bits_size, unsigned char *bits, long *next_offset);
static char *scan_basic_ivar_type(char *type, long *size, long *alignment, bool *is_reference) {
    // assume it is a non-reference type
    *is_reference = NO;
    
    // get the first character (advancing string)
    const char *full_type = type;
    char ch = *type++;
    
    // GCC 4 uses for const type*.
    if (ch == _C_CONST) ch = *type++;
    
    // act on first character
    switch (ch) {
        case _C_ID: {
            // ID type
            
            // skip over optional class name
            type = skip_ivar_type_name(type);
            
            // size and alignment of an id type
            *size = sizeof(id);
            *alignment = __alignof(id);
            
            // is a reference type
            *is_reference = YES;
            break;
        }        
        case _C_PTR: {
            // C pointer type
            
            // skip underlying type
            long ignored_offset;
            type = scan_ivar_type_for_layout(type, 0, 0, NULL, &ignored_offset);
            
            // size and alignment of a generic pointer type
            *size = sizeof(void *);
            *alignment = __alignof(void *);
            
            // is a reference type
            *is_reference = YES;
            break;
        }
        case _C_CHARPTR: {
            // C string 
            
           // size and alignment of a char pointer type
            *size = sizeof(char *);
            *alignment = __alignof(char *);
            
            // is a reference type
            *is_reference = YES;
            break;
        }
        case _C_CLASS:
        case _C_SEL: {
            // classes and selectors are ignored for now
            *size = sizeof(void *);
            *alignment = __alignof(void *);
            break;
        }
        case _C_CHR:
        case _C_UCHR: {
            // char and unsigned char
            *size = sizeof(char);
            *alignment = __alignof(char);
            break;
        }
        case _C_SHT:
        case _C_USHT: {
            // short and unsigned short
            *size = sizeof(short);
            *alignment = __alignof(short);
            break;
        }
        case _C_ATOM:
        case _C_INT:
        case _C_UINT: {
            // int and unsigned int
            *size = sizeof(int);
            *alignment = __alignof(int);
            break;
        }
        case _C_LNG:
        case _C_ULNG: {
            // long and unsigned long
            *size = sizeof(long);
            *alignment = __alignof(long);
            break;
        }
        case _C_LNG_LNG:
        case _C_ULNG_LNG: {
            // long long and unsigned long long
            *size = sizeof(long long);
            *alignment = __alignof(long long);
            break;
        }
        case _C_VECTOR: {
            // vector
            *size = 16;
            *alignment = 16;
            break;
        }
        case _C_FLT: {
            // float
            *size = sizeof(float);
            *alignment = __alignof(float);
            break;
        }
        case _C_DBL: {
            // double
            *size = sizeof(double);
            *alignment = __alignof(double);
            break;
        }
        case _C_BFLD: {
            // bit field
            
            // get number of bits in bit field (advance type string)
            long lng = strtol(type, &type, 10);
            
            // while next type is a bit field
            while (*type == _C_BFLD) {
                // skip over _C_BFLD
                type++;
                
                // get next bit field length
                long next_lng = strtol(type, &type, 10);
                
                // if spans next word then align to next word
                if ((lng & ~31) != ((lng + next_lng) & ~31)) lng = (lng + 31) & ~31;
                
                // increment running length
                lng += next_lng;
                
                // skip over potential field name
                type = skip_ivar_type_name(type);
            }
            
            // determine number of bytes bits represent
            *size = (lng + 7) / 8;
            
            // byte alignment
            *alignment = __alignof(char);
            break;
        }
        case _C_BOOL: {
            // double
            *size = sizeof(BOOL);
            *alignment = __alignof(BOOL);
            break;
        }
        case _C_VOID: {
            // skip void types
            *size = 0;
            *alignment = __alignof(char);
            break;
        }
        case _C_UNDEF: {
            *size = 0;
            *alignment = __alignof(char);
            break;
        }
        default: {
            // unhandled type
            _objc_fatal("unrecognized character \'%c\' in ivar type: \"%s\"", ch, full_type);
        }
    }
    
    return type;
}


/**********************************************************************
* scan_ivar_type_for_layout
*
* Scan an ivar type string looking for references.  The offset indicates
* where the ivar begins.  bits is a byte array of size bits_size used to
* contain the references bit map.  next_offset is the offset beyond the
* ivar.  Returns the remaining string.
*
**********************************************************************/
static char *scan_ivar_type_for_layout(char *type, long offset, long bits_size, unsigned char *bits, long *next_offset) {
    long size;                                   // size of a basic type
    long alignment;                              // alignment of the basic type
    bool is_reference;                      // true if the type indicates a reference to a garbage collected object
    
    // get the first character
    char ch = *type;

    // GCC 4 uses for const type*.
    if (ch == _C_CONST) ch = *++type;
    
    // act on first character
    switch (ch) {
        case _C_ARY_B: {
            // array type
            
            // get the array length
            long lng = strtol(type + 1, &type, 10);
            
            // next type will be where to advance the type string once the array is processed
            char *next_type = type;
           
            // repeat the next type x lng
            if (!lng) {
                next_type = scan_ivar_type_for_layout(type, 0, 0, NULL, &offset);
            } else {
                while (lng--) {
                    // repeatedly scan the same type
                    next_type = scan_ivar_type_for_layout(type, offset, bits_size, bits, &offset);
                }
            }
            
            // advance the type now
            type = next_type;
            
            // after the end of the array
            *next_offset = offset;
            
            // advance over closing bracket
            if (*type == _C_ARY_E) type++;
            else                   _objc_inform("missing \'%c\' in ivar type.", _C_ARY_E);
            
            break;
        }
        case _C_UNION_B: {
            // union type
            
            // skip over possible union name
            type = skip_ivar_struct_name(type + 1); 
            
            // need to accumulate the maximum element offset
            long max_offset = 0;
        
            // while not closing paren
            while ((ch = *type) && ch != _C_UNION_E) {
                // skip over potential field name
                type = skip_ivar_type_name(type);
                
                // scan type
                long union_offset;
                type = scan_ivar_type_for_layout(type, offset, bits_size, bits, &union_offset);
                
                // adjust the maximum element offset
                if (max_offset < union_offset) max_offset = union_offset;
            }
        
            // after the largest element 
            *next_offset = max_offset;
            
            // advance over closing paren
            if (ch == _C_UNION_E) {
              type++;
            } else {
              _objc_inform("missing \'%c\' in ivar type", _C_UNION_E);
            }
            
            break;
        }
        case _C_STRUCT_B: {
            // struct type
            
            // skip over possible struct name
            type = skip_ivar_struct_name(type + 1); 
            
            // while not closing brace
            while ((ch = *type) && ch != _C_STRUCT_E) {
                // skip over potential field name
                type = skip_ivar_type_name(type);
                
                // scan type
                type = scan_ivar_type_for_layout(type, offset, bits_size, bits, &offset);
            }
            
            // after the end of the struct
            *next_offset = offset;
            
            // advance over closing brace
            if (ch == _C_STRUCT_E) type++;
            else                   _objc_inform("missing \'%c\' in ivar type", _C_STRUCT_E);
            
            break;
        }
        default: {
            // basic type
            
            // scan type
            type = scan_basic_ivar_type(type, &size, &alignment, &is_reference);
            
            // create alignment mask
            alignment--; 
            
            // align offset
            offset = (offset + alignment) & ~alignment;
            
            // if is a reference then mark in the bit map
            if (is_reference) mark_offset_for_layout(offset, bits_size, bits);
            
            // after the basic type
            *next_offset = offset + size;
            break;
        }
    }
    
    // return remainder of type string
    return type;
}

#endif
