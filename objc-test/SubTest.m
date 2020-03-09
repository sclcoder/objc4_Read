//
//  SubTest.m
//  objc-test
//
//  Created by 孙春磊 on 2020/3/9.
//

#import "SubTest.h"

@implementation SubTest

+ (void)load{
    
    NSLog(@"%s",__func__);
}


+ (void)initialize{
    // [super initialize]; // 其实该方法不用主动调用, runtime中会自动先调用super的initialize
    NSLog(@"%s",__func__);
}

@end
