//
//  main.m
//  objc-test
//
//  Created by GongCF on 2018/12/16.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "TestObject.h"
#import "SubTest.h"

int main(int argc, const char * argv[]) {
    @autoreleasepool { /// debug  @autoreleasepool
          NSObject *p = [[NSObject alloc] init];
        
        
          
          NSObject *p2 = p; // debug retain\release
          __weak NSObject *p1 = p; // debug weak
        
        
//        SubTest *sub = [SubTest new];
////        sub.name = @"initialize";
//
//        TestObject *test = [TestObject new];
//        test.name = @"layout_bitmap";
//        test.age = 20;
//        [test unknowSel];
//
//        sub.name = @"initialize";
        
        
        
        
//        int array[6] = {10,1,2,3,455,6};
//        int *pointer = array;
//
//        printf("%p \n",array);   // 0x7ffeefbff4c0
//        printf("%p \n",pointer); // 0x7ffeefbff4c0
//        printf("%p \n",&array[0]); // 0x7ffeefbff4c0
//
//        printf("%d \n",array[0]); // 10
//
//
//        printf("%d \n",*(pointer + 1)); // 1
//
//
//        printf("%d \n",*pointer); // 10
//
//        printf("%d \n",array + 1); // -272632636 由此可见array 和 *pointer并不一样

    }
    return 0;
}





