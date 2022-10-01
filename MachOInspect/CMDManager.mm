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

- (NSString *)fileUrl {
    return [@"file://" stringByAppendingString:self.args[1]];
}

- (NSString *)destUrl {
    return [@"file://" stringByAppendingString:self.args[2]];
}

- (NSString *)symbol {
    return self.args[3];
}

- (NSString *)destSymbol {
    return self.args[4];
}

- (NSArray *)fatherNode {
    NSMutableArray *father = [NSMutableArray array];
    for (int i = 5; i < self.args.count; i ++) {
        [father addObject:self.args[i]];
    }
    return father;
}

@end

NSString * const MVScannerErrorMessage = @"NSScanner error";

@implementation CMDManager {
    MVDataController *dataController;
    NSURL *tmpURL;
    NSMutableArray *allRows;
    NSDictionary *utf8Map;
    CZArgs *czArgs;
    BOOL machoParseComplete;
    int32_t threadCount;
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
        allRows = [NSMutableArray array];
        [self initUTF8Map];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleThreadStateChanged:) name:MVThreadStateChangedNotification object:nil];
    }
    
    return self;
}

- (void)handleThreadStateChanged:(NSNotification *)notification {
    NSString *threadState = [[notification userInfo] objectForKey:MVStatusUserInfoKey];
    if ([threadState isEqualToString:MVStatusTaskStarted]) {
        if (OSAtomicIncrement32(&threadCount) == 1) {
            machoParseComplete = NO;
        }
    } else if ([threadState isEqualToString:MVStatusTaskTerminated]) {
        machoParseComplete = YES;
    }
}

- (void)runWithArgs:(NSArray *)args {
    if ([self dealWithArgs:args] && [self loadData] == 0) {
        [self dataLayout];
        while (!machoParseComplete) {
            sleep(1);
        }
        [self processData];
        int mCount = [self modifyData];
        NSLog(@"Modify Successfully for %d place", mCount);
        [self saveFile];
        [self clearTempFile];
    } else {
        NSLog(@"Modify symbol error!");
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
    NSURL *absoluteURL = [NSURL URLWithString:[czArgs fileUrl]];
    
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

- (void)dataLayout {
    for (MVLayout *layout in dataController.layouts) {
        [layout doMainTasks];
    }
    
    for (MVLayout *layout in dataController.layouts) {
#ifdef MV_NO_MULTITHREAD
        [layout doBackgroundTasks];
#else
        [layout.backgroundThread start];
#endif
    }
}

- (void)processData {
    NSMutableArray *queue = [NSMutableArray array];
    [queue addObject:dataController.rootNode];
    
    while (queue.count > 0) {
        MVNode *cnode = [queue firstObject];
        [queue removeObjectAtIndex:0];
        [cnode openDetails];
        [cnode closeDetails];
        MVTable *detail = [cnode details];
        NSArray *rows = [detail valueForKey:@"rows"];
        for (int i = 0; i < rows.count; i ++) {
            MVRow *row = [rows objectAtIndex:i];
            row.node = cnode;
            [allRows addObject:row];
        }
        
        for (int i = 0; i < cnode.numberOfChildren; i ++) {
            MVNode *ch = [cnode childAtIndex:i];
            [queue addObject:ch];
        }
    }
}

- (int)modifyData {
    int modifyCount = 0;
    for (int i = 0; i < allRows.count; i ++) {
        BOOL isTheDestRow = YES;
        MVRow *row = allRows[i];
        if ([row.coloumns.valueStr isEqual:[czArgs symbol]]) {
            MVNode *node = row.node;
            NSArray *fatherNode = [czArgs fatherNode];
            for (int i = 0; i < fatherNode.count; i ++) {
                if (![node.caption containsString:[fatherNode objectAtIndex:i]]) {
                    isTheDestRow = NO;
                    break;
                }
                node = node.parent;
            }
        } else {
            isTheDestRow = NO;
        }
        
        if (isTheDestRow) {
            row.coloumns.valueStr = [czArgs destSymbol];
            row.coloumns.dataStr = [self stringToUTF8Code:row.coloumns.valueStr];
            [self modifyTheDetailData:row.coloumns.dataStr onNode:row.node withRow:row];
            MVArchiver *archiver = [row.node.details valueForKey:@"archiver"];
            [archiver addObjectToSave:row];
            modifyCount ++;
        }
        isTheDestRow = NO;
    }
    return modifyCount;
}

- (void)saveFile {
    MVDocument *doc = [[MVDocument alloc] init];
    doc.dataController.fileData = dataController.fileData;
    NSURL *destURL = [NSURL URLWithString:[czArgs destUrl]];
    NSError *outError;
    BOOL result = [doc writeToURL:destURL ofType:@"Mach-O Binaries" error:&outError];
    if (result) {
        NSLog(@"save file %@ success", [destURL absoluteString]);
    } else {
        NSLog(@"save file failed %@", outError);
    }
}

- (void)clearTempFile {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *tempDir = [MVDocument temporaryDirectory];
    [fileManager removeItemAtPath:tempDir error:NULL];
}

- (NSString *)stringToUTF8Code:(NSString *)str {
    NSString *codeStr = @"00";
    for (long i = str.length - 1; i >= 0; i --) {
        NSString *aChar = [str substringWithRange:NSMakeRange(i, 1)];
        codeStr = [codeStr stringByAppendingString:[utf8Map objectForKey:aChar]];
    }
    return codeStr;
}

- (void)modifyTheDetailData:(NSString *)cellContent onNode:(MVNode *)selectedNode withRow:(MVRow *)row {
    BOOL scanResult;
    uint32_t fileOffset;
    NSScanner *scanner = [NSScanner scannerWithString:cellContent];
    if (selectedNode.details) {
        if (!row) return;
        
        scanResult = [[NSScanner scannerWithString:row.coloumns.offsetStr] scanHexInt:&fileOffset];
        if (!scanResult) {
            NSAssert(NO, MVScannerErrorMessage);
            return;
        }
        
        NSRange dataRange = NSMakeRange(fileOffset, [cellContent length] / 2);
        if (dataRange.length <= sizeof(uint64_t)) {
            uint64_t value;
            scanResult = [scanner scanHexLongLong:&value];
            if (!scanResult) {
                NSAssert(NO, MVScannerErrorMessage);
                return;
            }
            [dataController.fileData replaceBytesInRange:dataRange withBytes:&value];
        } else {
            // create a place holder for new value
            NSAssert([cellContent length] % 2 == 0, @"cell content must be even");
            NSMutableData *mdata = [NSMutableData dataWithCapacity:dataRange.length];
            static char buf[3];
            char const * orgstr = CSTRING(cellContent);
            for (NSUInteger s = 0; s < [cellContent length]; s += 2) {
                buf[0] = orgstr[s];
                buf[1] = orgstr[s + 1];
                unsigned value = strtoul(buf, NULL, 16);
                [mdata appendBytes:&value length:sizeof(uint8_t)];
             }
            
            // replace data with the new value
            NSLog(@"Replace data with the new value");
            [dataController.fileData replaceBytesInRange:dataRange withBytes:[mdata bytes]];
        }
        
        // update the cell content to indicate changes
        selectedNode.detailsOffset = 0;
    } else {  // options: group of bytes
        
    }
}

- (void)initUTF8Map {
    utf8Map = @{
        @"!":@"21",
        @"\"":@"21",  // TODO: should be 22?
        @"#":@"23",
        @"$":@"24",
        @"%":@"25",
        @"&":@"26",
        @"'":@"27",
        @"(":@"28",
        @")":@"29",
        @"*":@"2A",
        @"+":@"2B",
        @",":@"2C",
        @"-":@"2D",
        @".":@"2E",
        @"/":@"2F",
        @"0":@"30",
        @"1":@"31",
        @"2":@"32",
        @"3":@"33",
        @"4":@"34",
        @"5":@"35",
        @"6":@"36",
        @"7":@"37",
        @"8":@"38",
        @"9":@"39",
        @":":@"3A",
        @";":@"3B",
        @"<":@"3C",
        @"=":@"3D",
        @">":@"3E",
        @"?":@"3F",
        @"@":@"40",
        @"A":@"41",
        @"B":@"42",
        @"C":@"43",
        @"D":@"44",
        @"E":@"45",
        @"F":@"46",
        @"G":@"47",
        @"H":@"48",
        @"I":@"49",
        @"J":@"4A",
        @"K":@"4B",
        @"L":@"4C",
        @"M":@"4D",
        @"N":@"4E",
        @"O":@"4F",
        @"P":@"50",
        @"Q":@"51",
        @"R":@"52",
        @"S":@"53",
        @"T":@"54",
        @"U":@"55",
        @"V":@"56",
        @"W":@"57",
        @"X":@"58",
        @"Y":@"59",
        @"Z":@"5A",
        @"[":@"5B",
        @"\\":@"5C",
        @"]":@"5D",
        @"^":@"5E",
        @"_":@"5F",
        @"`":@"60",
        @"a":@"61",
        @"b":@"62",
        @"c":@"63",
        @"d":@"64",
        @"e":@"65",
        @"f":@"66",
        @"g":@"67",
        @"h":@"68",
        @"i":@"69",
        @"j":@"6A",
        @"k":@"6B",
        @"l":@"6C",
        @"m":@"6D",
        @"n":@"6E",
        @"o":@"6F",
        @"p":@"70",
        @"q":@"71",
        @"r":@"72",
        @"s":@"73",
        @"t":@"74",
        @"u":@"75",
        @"v":@"76",
        @"w":@"77",
        @"x":@"78",
        @"y":@"79",
        @"z":@"7A",
        @"{":@"7B",
        @"|":@"7C",
        @"}":@"7D",
        @"~":@"7E"
    };
}

@end
