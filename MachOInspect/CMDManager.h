//
//  CMDManager.h
//  MachOInspect
//
//  Created by ChenZhen on 2022/9/28.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CMDManager : NSObject
+ (CMDManager *)shareInstance;
// args[1] : Origin Mach-O path
// args[2] : Modified Mach-O path
// args[3] : symbol name which should be modified
// args[4] : new symbol name
// args[5] : sub section which should be changed
// args[6] : section which should be changed
// eg: "/users/App" "/user/App" "load" "czld" "C String Literals" "__TEXT,__objcmethname"
- (void)runWithArgs:(NSArray *)args;
@end

NS_ASSUME_NONNULL_END
