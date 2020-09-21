//
//  AtomicTest.m
//  objc-test
//
//  Created by 孙春磊 on 2020/9/16.
//

#import "AtomicTest.h"

@interface AtomicTest ()

/// MRC下的测试条件
@property(atomic,strong) NSObject *obj;

@end


@implementation AtomicTest

- (void)test{
       
          NSObject *obj = [NSObject new];  // 1

          self.obj = obj;  // 2
          [self printRetainCount:_obj];
    
          [obj release]; // 1
          // 每调用一次self.obj会发现retainCount加1，
          // 原因在于atomic类型get方法内部对_obj做了retain+autorelease来保证交接过程中对象的有效性，
          self.obj; // 2
          [self printRetainCount:_obj];
          self.obj; // 3
          [self printRetainCount:_obj];
          // 加入自动释放池时retainCount表现正常
          @autoreleasepool {
              self.obj; // 3
          }
          [self printRetainCount:_obj];
          @autoreleasepool {
              self.obj; //3
          }
          [self printRetainCount:_obj];
}

- (void)printRetainCount:(NSObject *)obj {
    NSLog(@"%@ reference count: %d", NSStringFromClass(obj.class), (int)[obj retainCount]);
}


@end
