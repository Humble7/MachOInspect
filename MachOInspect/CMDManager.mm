//
//  CMDManager.m
//  MachOInspect
//
//  Created by ChenZhen on 2022/9/28.
//

#import "CMDManager.h"
#import "Document.h"
#import "DataController.h"
#import "Layout.h"
#import "MachOLayout.h"

@interface CZArgs : NSObject
@property (nonatomic, strong) NSArray *args;
@end

@implementation CZArgs

- (id)initWithArray:(NSArray *)array {
    self = [super init];
    if (self) {
        self.args = array;
    }
    return self;
}

- (NSString *)machoUrl {
    return [@"file://" stringByAppendingString:self.args[1]];
}

- (NSString *)loadClassUrl {
    return [@"file://" stringByAppendingString:self.args[2]];
}

@end

NSString * const MVScannerErrorMessage = @"NSScanner error";

@implementation CMDManager {
    MVDataController *dataController;
    NSURL *tmpURL;
    CZArgs *czArgs;
    BOOL machoParseComplete;
    int32_t threadCount;
    NSDictionary *nonLazyClassInfo;
}

+ (CMDManager *)shareInstance {
    static CMDManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CMDManager alloc] init];
    });
    return instance;
}

- (id)init {
    self = [super init];
    if (self) {
        dataController = [[MVDataController alloc] init];
    }
    
    return self;
}

- (void)runWithArgs:(NSArray *)args {
    NSLog(@"begin run the analysis.");
    if ([self dealWithArgs:args] && [self loadData] == 0) {
        MachOLayout *machOLayout = nil;
        NSLog(@"the layout count is:%ld", dataController.layouts.count);
        for (MVLayout *layout in dataController.layouts) {
            NSLog(@"MVLayout:%@", layout);
            if ([layout isKindOfClass:[MachOLayout class]]) {
                machOLayout = (MachOLayout *)layout;
                break;
            }
        }
        
        if (!machOLayout) {
            NSLog(@"[ERROR]:Unable to get loadClass info.");
            exit(2);
        }
        
        NSLog(@"begin machOLayout");
        [machOLayout doMainTasks];
        NSLog(@"end machOLayout");
        // TODO: 名字有歧义？nonLazy 和 getLazy
        nonLazyClassInfo = [machOLayout getLazyClassInfo];
        NSURL *loadClassUrl = [NSURL URLWithString:[czArgs loadClassUrl]];
        NSData *data = [[NSData alloc] initWithContentsOfURL:loadClassUrl];
        if (data) {
            NSDictionary *loadClassInput = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:nil];
            NSArray *addedCls = [self isLoadClassInput:loadClassInput containLoadClassFromMachO:nonLazyClassInfo];
            if (addedCls.count == 0) {
                NSLog(@"[SUCCESS]: No new load method class add in the MachO file.");
                exit(0);
            } else {
                NSLog(@"[ERROR]: New load method class [%@] are add in the project.", addedCls);
                exit(3);
            }
        }
    } else {
        NSLog(@"[ERROR]:Unable to parse MachO file properly.");
        exit(1);
    }
}

- (BOOL)dealWithArgs:(NSArray *)args {
    czArgs = [[CZArgs alloc] initWithArray:args];
    return YES;
}

// success: return 0
- (int)loadData {
    NSError *outError;
    NSURL *absoluteURL = [NSURL URLWithString:[czArgs machoUrl]];
    
    // create a temporary copy for patching
    const char *tmp = [[MVDocument temporaryDirectory] UTF8String];
    char *tmpFilePath = strdup(tmp);
    if (mktemp(tmpFilePath) == NULL) {
        NSLog(@"mktemp failed!");
        free(tmpFilePath);
        return 1;
    }
    
    tmpURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:tmpFilePath]];
    free(tmpFilePath);
    
    [[NSFileManager defaultManager] copyItemAtURL:absoluteURL toURL:tmpURL error:&outError];
    if (outError) return 2;
    
    // open the copied binary for patching
    dataController.realData = [NSMutableData dataWithContentsOfURL:tmpURL options:NSDataReadingMappedIfSafe error:&outError];
    if (outError) return 3;
    
    // open the original binary for viewing/editing
    dataController.fileName = [absoluteURL path];
    dataController.fileData = [NSMutableData dataWithContentsOfURL:absoluteURL options:NSDataReadingMappedIfSafe error:&outError];
    if (outError) return 4;
    
    @try {
        [dataController createLayouts:dataController.rootNode location:0 length:[dataController.fileData length]];
    } @catch (NSException *exception) {
        outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:[absoluteURL path], NSFilePathErrorKey, [exception reason], NSLocalizedDescriptionKey, nil]];
        return 5;
    }
    return 0;
}

// inputInfo: 从Json文件中读取的内容
- (NSArray *)isLoadClassInput:(NSDictionary *)inputInfo containLoadClassFromMachO:(NSDictionary *)machOInfo {
    NSMutableDictionary *inputDict = [NSMutableDictionary dictionary];
    NSMutableArray *result = [NSMutableArray array];
    NSArray *clslist = machOInfo[@"clslist"];
    NSArray *catlist = machOInfo[@"catlist"];
    
    NSArray *mainList = inputInfo[@"mainlist"];
    for (int i = 0; i < mainList.count; i ++) {
        NSDictionary *item = mainList[i];
        NSString *key = item[@"cls"];
        NSString *cat = item[@"cat"];
        if (cat.length > 0) {
            key = [NSString stringWithFormat:@"%@(%@)", key, cat];
        }
        
        [inputDict setObject:item forKey:key];
    }
    
    NSArray *mainBGList = inputInfo[@"mainbglist"];
    for (int i = 0; i < mainBGList.count; i ++) {
        NSDictionary *item = mainBGList[i];
        NSString *key = item[@"cls"];
        NSString *cat = item[@"cat"];
        if (cat.length > 0) {
            key = [NSString stringWithFormat:@"%@(%@)", key, cat];
        }
        
        [inputDict setObject:item forKey:key];
    }
    
    NSArray *delayList = inputInfo[@"delaylist"];
    for (int i = 0; i < delayList.count; i ++) {
        NSDictionary *item = delayList[i];
        NSString *key = item[@"cls"];
        NSString *cat = item[@"cat"];
        if (cat.length > 0) {
            key = [NSString stringWithFormat:@"%@(%@)", key, cat];
        }
        
        [inputDict setObject:item forKey:key];
    }
    
    NSMutableDictionary *checkedList = [NSMutableDictionary dictionary];
    // search key
    for (int i = 0; i < clslist.count; i ++) {
        NSDictionary *item = clslist[i];
        NSString *key = item[@"c"];
        
        if (![inputDict objectForKey:key]) {
            [result addObject:key];
        } else {
            [checkedList setObject:key forKey:key];
        }
    }
    
    for (int i = 0; i < catlist.count; i ++) {
        NSDictionary *item = catlist[i];
        NSString *key = item[@"c"];
        NSString *ct = item[@"ct"];
        key = [NSString stringWithFormat:@"%@(%@)", key, ct];
        
        if (![inputDict objectForKey:key]) {
            [result addObject:key];
        } else {
            [checkedList setObject:key forKey:key];
        }
    }
    
    NSMutableArray *checkedResult = [NSMutableArray array];
    for (int i = 0; i < result.count; i ++) {
        NSString *key = [result objectAtIndex:i];
        if ([key containsString:@"("] && [key containsString:@")"]) {
            // cat method in machO not found
            [checkedResult addObject:key];
        } else {
            [checkedResult addObject:key];
            
            // 如果一个本地类，只在category里面实现了load方法，编译器不会把方法放进__objc_catlist和_objc_nlcatlist
            // 此处加判断，如果在类中的配置没有被消耗，在cat中将会使用这次配置
            for (int i = 0; i < inputDict.allKeys.count; i ++) {
                NSString *kkey = [inputDict.allKeys objectAtIndex:i];
                if ([kkey containsString:key] && ![checkedList objectForKey:kkey]) {
                    [checkedResult removeObject:key];
                    break;
                }
            }
        }
    }
    return checkedResult;
}

@end
