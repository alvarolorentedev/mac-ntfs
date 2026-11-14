#import "NTFSDeviceShim.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

@implementation NTFSDeviceShim {
    FSBlockDeviceResource *_resource;
    int64_t _alignment;
    int64_t _deviceSize;
}

- (instancetype)initWithResource:(FSBlockDeviceResource *)resource
{
    self = [super init];
    if (self) {
        _resource = resource;
        int64_t physical = (int64_t)resource.physicalBlockSize;
        int64_t logical = (int64_t)resource.blockSize;
        _alignment = physical > 0 ? physical : (logical > 0 ? logical : 512);
        _deviceSize = (int64_t)resource.blockCount * (logical > 0 ? logical : 512);
    }
    return self;
}

- (BOOL)writable
{
    return _resource.writable;
}

- (int64_t)deviceSize
{
    return _deviceSize;
}

- (int64_t)alignment
{
    return _alignment;
}

static int bridge_errno_from_error(NSError *error)
{
    if (!error) {
        return 0;
    }
    if ([error.domain isEqualToString:NSPOSIXErrorDomain]) {
        return (int)error.code;
    }
    return EIO;
}

/// Synchronous read that keeps requesting until `length` bytes arrive or the
/// resource reports a partial read with no error (end of device).
- (int64_t)rawReadInto:(void *)buffer length:(int64_t)length offset:(int64_t)offset
{
    uint8_t *cursor = buffer;
    int64_t total = 0;
    while (total < length) {
        NSError *error = nil;
        size_t got = [_resource readInto:cursor + total
                              startingAt:(off_t)(offset + total)
                                  length:(size_t)(length - total)
                                   error:&error];
        if (got == 0) {
            if (error) {
                errno = bridge_errno_from_error(error);
                return -1;
            }
            break; /* end of device */
        }
        total += (int64_t)got;
    }
    return total;
}

- (int64_t)rawWriteFrom:(const void *)buffer length:(int64_t)length offset:(int64_t)offset
{
    const uint8_t *cursor = buffer;
    int64_t total = 0;
    while (total < length) {
        NSError *error = nil;
        size_t put = [_resource writeFrom:(void *)(cursor + total)
                               startingAt:(off_t)(offset + total)
                                   length:(size_t)(length - total)
                                    error:&error];
        if (put == 0) {
            if (error) {
                errno = bridge_errno_from_error(error);
                return -1;
            }
            errno = EIO;
            return -1;
        }
        total += (int64_t)put;
    }
    return total;
}

/// Read-modify-write around the resource's transfer-requirement alignment.
- (int64_t)preadInto:(void *)buffer length:(int64_t)length offset:(int64_t)offset
{
    if (length <= 0 || offset < 0) {
        errno = EINVAL;
        return -1;
    }
    if (offset % _alignment == 0 && length % _alignment == 0) {
        return [self rawReadInto:buffer length:length offset:offset];
    }

    int64_t start = offset - (offset % _alignment);
    int64_t end = offset + length;
    if (end % _alignment != 0) {
        end += _alignment - (end % _alignment);
    }
    if (end > _deviceSize) {
        end = _deviceSize;
    }
    int64_t span = end - start;
    if (span <= 0) {
        return 0;
    }

    uint8_t *scratch = malloc((size_t)span);
    if (!scratch) {
        errno = ENOMEM;
        return -1;
    }
    int64_t got = [self rawReadInto:scratch length:span offset:start];
    if (got < 0) {
        free(scratch);
        return -1;
    }
    int64_t available = got - (offset - start);
    if (available < 0) {
        available = 0;
    }
    int64_t toCopy = length < available ? length : available;
    memcpy(buffer, scratch + (offset - start), (size_t)toCopy);
    free(scratch);
    return toCopy;
}

- (int64_t)pwriteFrom:(const void *)buffer length:(int64_t)length offset:(int64_t)offset
{
    if (length <= 0 || offset < 0) {
        errno = EINVAL;
        return -1;
    }
    if (!_resource.writable) {
        errno = EROFS;
        return -1;
    }
    if (offset % _alignment == 0 && length % _alignment == 0) {
        return [self rawWriteFrom:buffer length:length offset:offset];
    }

    int64_t start = offset - (offset % _alignment);
    int64_t end = offset + length;
    if (end % _alignment != 0) {
        end += _alignment - (end % _alignment);
    }
    if (end > _deviceSize) {
        end = _deviceSize;
    }
    int64_t span = end - start;
    if (span <= 0 || span < length) {
        errno = EINVAL;
        return -1;
    }

    uint8_t *scratch = malloc((size_t)span);
    if (!scratch) {
        errno = ENOMEM;
        return -1;
    }
    int64_t got = [self rawReadInto:scratch length:span offset:start];
    if (got < span) {
        free(scratch);
        if (got >= 0) {
            errno = EIO;
        }
        return -1;
    }
    memcpy(scratch + (offset - start), buffer, (size_t)length);
    int64_t put = [self rawWriteFrom:scratch length:span offset:start];
    free(scratch);
    if (put < 0) {
        return -1;
    }
    if (put != span) {
        errno = EIO;
        return -1;
    }
    return length;
}

- (int)syncDevice
{
    /* Writes go through the resource's direct I/O path; there is no separate
     * flush entry point on FSBlockDeviceResource in this SDK. */
    return 0;
}

#pragma mark - C trampolines

static int64_t shim_pread(void *context, void *buffer, uint64_t length, uint64_t offset)
{
    @autoreleasepool {
        NTFSDeviceShim *shim = (__bridge NTFSDeviceShim *)context;
        if (length > INT64_MAX || offset > INT64_MAX) {
            errno = EINVAL;
            return -1;
        }
        return [shim preadInto:buffer length:(int64_t)length offset:(int64_t)offset];
    }
}

static int64_t shim_pwrite(void *context, const void *buffer, uint64_t length, uint64_t offset)
{
    @autoreleasepool {
        NTFSDeviceShim *shim = (__bridge NTFSDeviceShim *)context;
        if (length > INT64_MAX || offset > INT64_MAX) {
            errno = EINVAL;
            return -1;
        }
        return [shim pwriteFrom:buffer length:(int64_t)length offset:(int64_t)offset];
    }
}

static int64_t shim_device_size(void *context)
{
    NTFSDeviceShim *shim = (__bridge NTFSDeviceShim *)context;
    return shim.deviceSize;
}

static int64_t shim_sector_size(void *context)
{
    NTFSDeviceShim *shim = (__bridge NTFSDeviceShim *)context;
    return shim.alignment;
}

static int shim_sync(void *context)
{
    NTFSDeviceShim *shim = (__bridge NTFSDeviceShim *)context;
    return [shim syncDevice];
}

- (void)fillOperations:(ntfs_bridge_device_ops *)operations
{
    operations->context = (__bridge void *)self;
    operations->pread = shim_pread;
    operations->pwrite = self.writable ? shim_pwrite : NULL;
    operations->device_size = shim_device_size;
    operations->sector_size = shim_sector_size;
    operations->sync = shim_sync;
}

@end
