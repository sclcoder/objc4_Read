//
//  TestObject.m
//  objc-test
//
//  Created by 孙春磊 on 2020/3/4.
//

#import "TestObject.h"
#import <objc/runtime.h>

@implementation TestObject

+ (void)load{
    
    NSLog(@"%s",__func__);
}


+ (void)initialize{
    NSLog(@"%s",__func__);
}

// OC方法
- (void)other
{
    NSLog(@"%s", __func__);
    NSObject *obj = [NSObject new];
}


/// 动态解析
+ (BOOL)resolveInstanceMethod:(SEL)sel{
    
    if (sel == @selector(unknowSel)) {
        // 获取其他方法
        Method method = class_getInstanceMethod(self, @selector(other));
        // 动态添加test方法的实现 会添加到 class_rw_t中的方法列表中
        class_addMethod(self, sel,
                        method_getImplementation(method),
                        method_getTypeEncoding(method));
        // 返回YES代表有动态添加方法
        return YES;
    }
    return [super resolveInstanceMethod:sel];

}
@end
