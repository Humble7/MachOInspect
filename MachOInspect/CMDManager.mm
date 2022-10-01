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
// machOInfo: 从__objc_nlclslist段和__objc_nlcatlist分别读取实现了load方法的class和category
// -- case1: 类和分类都实现了load方法。__objc_nlclslist有class信息，__objc_nlcatlist有category信息
// -- case2: 类实现了load方法，分类没有实现load方法。只有__objc_nlclslist有class信息
// -- case4: 类没有实现load方法，只有一个分类实现了load方法。此时__objc_nlclslist有class信息，__objc_nlcatlist无category信息
// -- case4: 类没有实现load方法，有一个以上的分类实现了load方法。此时__objc_nlclslist无class信息，__objc_nlcatlist有category信息
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
        NSString *clsOrCatNameInMachO = [result objectAtIndex:i];
        if ([self isCategory:clsOrCatNameInMachO]) {
            // cat method in machO not found
            [checkedResult addObject:clsOrCatNameInMachO];
        } else {
            [checkedResult addObject:clsOrCatNameInMachO];
            
            // 处理case 4
            // 此处加判断，如果在类中的配置没有被消耗，在cat中将会使用这次配置
            // 用户在load_config文件中配置了注册了Category，但由于此时命中了case4，所以没有category的信息，只有class的信息。此时尝试将配置文件中的category部分移除掉去匹配class名
            for (int i = 0; i < inputDict.allKeys.count; i ++) {
                NSString *clsOrCatNameInJson = [inputDict.allKeys objectAtIndex:i];
                if ([self isCategory:clsOrCatNameInJson] && [[self extractClassFromCategory:clsOrCatNameInJson] isEqualToString:clsOrCatNameInMachO] && ![checkedList objectForKey:clsOrCatNameInJson]) {
                    [checkedResult removeObject:clsOrCatNameInMachO];
                    break;
                }
            }
        }
    }
    return checkedResult;
}

- (BOOL)isCategory:(NSString *)name {
    if (!name) return NO;
    return [name containsString:@"("] && [name containsString:@")"];
}

- (NSString *)extractClassFromCategory:(NSString *)category {
    if (!category || category.length == 0) return @"";
    
    NSRange catRange = [category rangeOfString:@"("];
    NSRange classRange = NSMakeRange(0, catRange.location);
    
    NSString *ret = [category substringWithRange:classRange];
    return ret;
}

@end
