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
// args[1] : Mach-O path
// args[2] : json file path
// eg: "/users/App" "/check_load_symbol/load_method.json"
- (void)runWithArgs:(NSArray *)args;
@end

NS_ASSUME_NONNULL_END
