/*
 * ntfs_bridge.h — narrow C bridge to libntfs-3g.
 *
 * Ownership and lifetime contract:
 *   - ntfs_bridge_open()/ntfs_bridge_open_device() return an opaque bridge
 *     that owns one ntfs_volume. The caller owns nothing else.
 *   - Every other call requires a live bridge and is not thread-safe:
 *     serialize all calls on one queue. (The FSKit extension uses one
 *     dedicated serial queue.)
 *   - ntfs_bridge_close() flushes and releases everything; the pointer is
 *     invalid afterwards.
 *   - With ntfs_bridge_open_device(), the device context and its callbacks
 *     belong to the caller and must stay alive until ntfs_bridge_close().
 *
 * Safety policy enforced here:
 *   - The volume is always opened read-only first. Read/write is only used
 *     when the caller asked for it AND the volume is neither dirty nor
 *     hibernated (Windows hibernation / Fast Startup). Otherwise the bridge
 *     stays read-only and reports the reason.
 *   - Metadata files (mft_no < FILE_first_user) can never be unlinked.
 *   - Unsupported file shapes (compressed, encrypted, reparse points) return
 *     NTFS_BRIDGE_ERR_NOT_SUPPORTED instead of pretending to succeed.
 */

#ifndef NTFS_BRIDGE_H
#define NTFS_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ntfs_bridge ntfs_bridge;

#define NTFS_BRIDGE_ROOT_INODE 5u /* FILE_root */

typedef enum {
    NTFS_BRIDGE_OK = 0,
    NTFS_BRIDGE_ERR_IO,
    NTFS_BRIDGE_ERR_NOT_FOUND,
    NTFS_BRIDGE_ERR_EXISTS,
    NTFS_BRIDGE_ERR_PERM,
    NTFS_BRIDGE_ERR_INVAL,
    NTFS_BRIDGE_ERR_NOT_SUPPORTED,
    NTFS_BRIDGE_ERR_NOT_DIRECTORY,
    NTFS_BRIDGE_ERR_IS_DIRECTORY,
    NTFS_BRIDGE_ERR_NOT_EMPTY,
    NTFS_BRIDGE_ERR_NO_SPACE,
} ntfs_bridge_status;

typedef struct {
    uint64_t file_id;
    uint64_t size;
    uint64_t allocated_size;
    uint32_t mode; /* POSIX mode bits including type */
    uint32_t link_count;
    int64_t access_time_ns;
    int64_t modify_time_ns;
    int64_t change_time_ns;
    int64_t birth_time_ns;
    bool is_directory;
} ntfs_bridge_attrs;

typedef struct {
    uint64_t total_bytes;
    uint64_t free_bytes;
    uint32_t cluster_size;
    uint64_t total_clusters;
    uint64_t free_clusters;
} ntfs_bridge_volume_stats;

typedef enum {
    NTFS_BRIDGE_TYPE_UNKNOWN = 0,
    NTFS_BRIDGE_TYPE_FILE,
    NTFS_BRIDGE_TYPE_DIRECTORY,
    NTFS_BRIDGE_TYPE_SYMLINK,
} ntfs_bridge_entry_type;

typedef struct {
    char name[1024]; /* UTF-8, NUL-terminated */
    ntfs_bridge_entry_type type;
    uint64_t file_id;
} ntfs_bridge_dirent;

/* Return false to stop the enumeration early. */
typedef bool (*ntfs_bridge_dir_emit)(void *context, const ntfs_bridge_dirent *entry);

/*
 * Block-device access supplied by the host (the FSKit extension implements it
 * over FSBlockDeviceResource). Callbacks return the number of bytes
 * transferred, or -1 with errno set. All calls happen on the caller's serial
 * queue and on the FSKit resource's own thread of control.
 */
typedef struct {
    void *context;
    int64_t (*pread)(void *context, void *buffer, uint64_t length, uint64_t offset);
    int64_t (*pwrite)(void *context, const void *buffer, uint64_t length, uint64_t offset);
    int64_t (*device_size)(void *context);
    int64_t (*sector_size)(void *context);
    int (*sync)(void *context);
} ntfs_bridge_device_ops;

ntfs_bridge *ntfs_bridge_open(const char *image_path,
                              bool read_only,
                              ntfs_bridge_status *status,
                              bool *downgraded_to_read_only,
                              bool *is_dirty,
                              bool *is_hibernated);

ntfs_bridge *ntfs_bridge_open_device(const ntfs_bridge_device_ops *ops,
                                     const char *name,
                                     bool read_only,
                                     ntfs_bridge_status *status,
                                     bool *downgraded_to_read_only,
                                     bool *is_dirty,
                                     bool *is_hibernated);

ntfs_bridge_status ntfs_bridge_close(ntfs_bridge *bridge);

bool ntfs_bridge_is_read_only(const ntfs_bridge *bridge);
bool ntfs_bridge_was_dirty(const ntfs_bridge *bridge);
bool ntfs_bridge_was_hibernated(const ntfs_bridge *bridge);
ntfs_bridge_status ntfs_bridge_sync(ntfs_bridge *bridge);
ntfs_bridge_status ntfs_bridge_statfs(ntfs_bridge *bridge, ntfs_bridge_volume_stats *out);

/* Path-based operations (resolve the path on every call). */
ntfs_bridge_status ntfs_bridge_getattr(ntfs_bridge *bridge, const char *path, ntfs_bridge_attrs *out);
ntfs_bridge_status ntfs_bridge_readdir(ntfs_bridge *bridge, const char *path,
                                       ntfs_bridge_dir_emit emit, void *context);
ntfs_bridge_status ntfs_bridge_create(ntfs_bridge *bridge, const char *path, bool directory);
ntfs_bridge_status ntfs_bridge_unlink(ntfs_bridge *bridge, const char *path);
ntfs_bridge_status ntfs_bridge_read(ntfs_bridge *bridge, const char *path, uint64_t offset,
                                    void *buffer, size_t length, size_t *out_read);
ntfs_bridge_status ntfs_bridge_write(ntfs_bridge *bridge, const char *path, uint64_t offset,
                                     const void *buffer, size_t length, size_t *out_written);
ntfs_bridge_status ntfs_bridge_truncate(ntfs_bridge *bridge, const char *path, uint64_t size);
ntfs_bridge_status ntfs_bridge_rename(ntfs_bridge *bridge, const char *from, const char *to);

/* Inode-based operations (used by the FSKit extension after lookup). */
ntfs_bridge_status ntfs_bridge_lookup(ntfs_bridge *bridge, uint64_t directory_inode, const char *name,
                                      uint64_t *out_inode, ntfs_bridge_attrs *out_attrs);
ntfs_bridge_status ntfs_bridge_getattr_inode(ntfs_bridge *bridge, uint64_t inode, ntfs_bridge_attrs *out);
ntfs_bridge_status ntfs_bridge_readdir_inode(ntfs_bridge *bridge, uint64_t inode,
                                             ntfs_bridge_dir_emit emit, void *context);
ntfs_bridge_status ntfs_bridge_read_inode(ntfs_bridge *bridge, uint64_t inode, uint64_t offset,
                                          void *buffer, size_t length, size_t *out_read);
ntfs_bridge_status ntfs_bridge_write_inode(ntfs_bridge *bridge, uint64_t inode, uint64_t offset,
                                           const void *buffer, size_t length, size_t *out_written);
ntfs_bridge_status ntfs_bridge_truncate_inode(ntfs_bridge *bridge, uint64_t inode, uint64_t size);

/* Test fixtures only: marks the on-disk volume dirty and flushes. */
ntfs_bridge_status ntfs_bridge_test_mark_dirty(ntfs_bridge *bridge);

const char *ntfs_bridge_strerror(ntfs_bridge_status status);

#endif /* NTFS_BRIDGE_H */
