#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// A Kotlin enum class as Kotlin/Native exports it; Swift sees the bridged Swift enum `Surface` (Kit.apinotes).
@interface KitSurface : NSObject
@property (class, readonly) KitSurface *slow;
@property (class, readonly) KitSurface *medium;
@property (class, readonly) KitSurface *fast;
@property (readonly) int32_t ordinal;
@end
/// A Kotlin sealed class and its subclasses (data classes).
@interface KitShot : NSObject
@property (readonly) int32_t hole;
@end
@interface KitPutt : KitShot
@property (readonly) int32_t feet;
@property (readonly) KitSurface *surface;
@end
@interface KitDrive : KitShot
@property (readonly) int32_t yards;
@end
NS_ASSUME_NONNULL_END
