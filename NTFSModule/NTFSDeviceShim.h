#import <Foundation/Foundation.h>
#import <FSKit/FSKit.h>

#include "ntfs_bridge.h"

NS_ASSUME_NONNULL_BEGIN

/// Bridges an FSBlockDeviceResource to the ntfs_bridge block-device callbacks.
///
/// All calls are synchronous, on the caller's serial queue. The shim must
/// outlive the bridge it is attached to (the volume keeps it alive and closes
/// the bridge before releasing the shim).
@interface NTFSDeviceShim : NSObject

- (instancetype)initWithResource:(FSBlockDeviceResource *)resource;

@property (nonatomic, readonly) BOOL writable;
@property (nonatomic, readonly) int64_t deviceSize;
@property (nonatomic, readonly) int64_t alignment;

- (int64_t)preadInto:(void *)buffer length:(int64_t)length offset:(int64_t)offset;
- (int64_t)pwriteFrom:(const void *)buffer length:(int64_t)length offset:(int64_t)offset;
- (int)syncDevice;

/// Fills C callbacks that dispatch into this shim. Passes the shim as the
/// callback context.
- (void)fillOperations:(ntfs_bridge_device_ops *)operations;

@end

NS_ASSUME_NONNULL_END
