//
//  main.m
//  objc-test
//
//  Created by GongCF on 2018/12/16.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
int main(int argc, const char * argv[]) {
    @autoreleasepool {
          NSObject *p = [[NSObject alloc] init];
          __weak NSObject *p1 = p;
    }
    return 0;
}





