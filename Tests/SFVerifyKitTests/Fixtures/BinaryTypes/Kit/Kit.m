#import "Kit.h"

@implementation KitSurface {
    int32_t _ordinal;
}
- (instancetype)initWithOrdinal:(int32_t)ordinal {
    if ((self = [super init])) { _ordinal = ordinal; }
    return self;
}
- (int32_t)ordinal { return _ordinal; }
+ (KitSurface *)slow { static KitSurface *value; static dispatch_once_t once; dispatch_once(&once, ^{ value = [[KitSurface alloc] initWithOrdinal:0]; }); return value; }
+ (KitSurface *)medium { static KitSurface *value; static dispatch_once_t once; dispatch_once(&once, ^{ value = [[KitSurface alloc] initWithOrdinal:1]; }); return value; }
+ (KitSurface *)fast { static KitSurface *value; static dispatch_once_t once; dispatch_once(&once, ^{ value = [[KitSurface alloc] initWithOrdinal:2]; }); return value; }
@end

@implementation KitShot
- (int32_t)hole { return 1; }
@end

@implementation KitPutt
- (int32_t)feet { return 12; }
- (KitSurface *)surface { return KitSurface.medium; }
@end

@implementation KitDrive
- (int32_t)yards { return 250; }
@end
