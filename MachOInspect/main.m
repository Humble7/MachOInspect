//
//  main.m
//  MachOInspect
//
//  Created by ChenZhen on 2022/9/28.
//

#import <Foundation/Foundation.h>
#import "CMDManager.h"

// Troubleshoot for building error:
// 1. make sure all .c and .inc file are compiled.
// 2. build setting: "Prefix header" : "MachOInspect/Prefix.pch"
// 3. build setting: "header search path" : ["$(SRCROOT)", "$(SRCROOT)/capstone/include"]
// 4. build setting: "c++ standard library" : choose c++ with c++11

NSCondition *pipeCondition;
int32_t numIOThread;

int main(int argc, const char * argv[]) {
    pipeCondition = [[NSCondition alloc] init];
    numIOThread = 0;
    @autoreleasepool {
        NSMutableArray *args = [NSMutableArray array];
        for (int i = 0; i < argc; i ++) {
            char *arg = argv[i];
            NSString *para = [NSString stringWithUTF8String:arg];
            NSLog(@"[arg]%@", para);
            [args addObject:para];
        }
        
        [[CMDManager shareInstance] runWithArgs:args];
    }
    return 0;
}
