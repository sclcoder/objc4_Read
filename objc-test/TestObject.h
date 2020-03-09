//
//  TestObject.h
//  objc-test
//
//  Created by 孙春磊 on 2020/3/4.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TestObject : NSObject
@property(nonatomic,copy)  NSString *name;
@property(nonatomic,assign) int age;

- (void)unknowSel;
@end

NS_ASSUME_NONNULL_END
