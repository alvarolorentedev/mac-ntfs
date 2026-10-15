#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "ntfs_bridge.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#if defined(__APPLE__)
#include <sys/disk.h>
#endif

#include <ntfs-3g/attrib.h>
#include <ntfs-3g/device.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/layout.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/volume.h>

struct ntfs_bridge {
    ntfs_volume *volume;
    struct bridge_device *device_wrapper; /* NULL for path-based mounts */
    bool read_only;
    bool dirty;
    bool hibernated;
};

#define NTFS_VOLUME_DIRTY_FLAG 0x0001

/* MARK: - status mapping */

const char *ntfs_bridge_strerror(ntfs_bridge_status status)
{
    switch (status) {
    case NTFS_BRIDGE_OK: return "ok";
    case NTFS_BRIDGE_ERR_IO: return "input/output error";
    case NTFS_BRIDGE_ERR_NOT_FOUND: return "not found";
    case NTFS_BRIDGE_ERR_EXISTS: return "already exists";
    case NTFS_BRIDGE_ERR_PERM: return "operation not permitted";
    case NTFS_BRIDGE_ERR_INVAL: return "invalid argument";
    case NTFS_BRIDGE_ERR_NOT_SUPPORTED: return "operation not supported";
    case NTFS_BRIDGE_ERR_NOT_DIRECTORY: return "not a directory";
    case NTFS_BRIDGE_ERR_IS_DIRECTORY: return "is a directory";
    case NTFS_BRIDGE_ERR_NOT_EMPTY: return "directory not empty";
    case NTFS_BRIDGE_ERR_NO_SPACE: return "no space left";
    }
    return "unknown";
}

static ntfs_bridge_status status_from_errno(int error)
{
    switch (error) {
    case 0: return NTFS_BRIDGE_ERR_IO;
    case ENOENT: return NTFS_BRIDGE_ERR_NOT_FOUND;
    case EEXIST: return NTFS_BRIDGE_ERR_EXISTS;
    case EACCES:
    case EPERM: return NTFS_BRIDGE_ERR_PERM;
    case EINVAL: return NTFS_BRIDGE_ERR_INVAL;
    case ENOTDIR: return NTFS_BRIDGE_ERR_NOT_DIRECTORY;
    case EISDIR: return NTFS_BRIDGE_ERR_IS_DIRECTORY;
    case ENOTEMPTY: return NTFS_BRIDGE_ERR_NOT_EMPTY;
    case ENOSPC: return NTFS_BRIDGE_ERR_NO_SPACE;
    case EOPNOTSUPP: return NTFS_BRIDGE_ERR_NOT_SUPPORTED;
    default: return NTFS_BRIDGE_ERR_IO;
    }
}

/* MARK: - path helpers */

static bool valid_path(const char *path)
{
    if (!path || path[0] != '/') {
        return false;
    }
    size_t length = strlen(path);
    if (length == 0 || length >= 4000) {
        return false;
    }
    if (length > 1 && path[length - 1] == '/') {
        return false;
    }
    const char *cursor = path + 1; /* skip the leading slash */
    while (*cursor) {
        const char *slash = strchr(cursor, '/');
        size_t component_length = slash ? (size_t)(slash - cursor) : strlen(cursor);
        if (component_length == 0) {
            return false; /* "//" */
        }
        if (component_length == 1 && cursor[0] == '.') {
            return false;
        }
        if (component_length == 2 && cursor[0] == '.' && cursor[1] == '.') {
            return false;
        }
        if (!slash) {
            break;
        }
        cursor = slash + 1;
    }
    return true;
}

/* Splits "/parent/name" into "/parent" and "name". */
static ntfs_bridge_status split_parent(const char *path, char *parent, size_t parent_size, const char **name_out)
{
    if (!valid_path(path) || strcmp(path, "/") == 0) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    const char *name = strrchr(path, '/') + 1;
    if (*name == 0) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    size_t parent_length = (size_t)(name - 1 - path);
    if (parent_length == 0) {
        if (parent_size < 2) {
            return NTFS_BRIDGE_ERR_INVAL;
        }
        parent[0] = '/';
        parent[1] = 0;
    } else {
        if (parent_length + 1 > parent_size) {
            return NTFS_BRIDGE_ERR_INVAL;
        }
        memcpy(parent, path, parent_length);
        parent[parent_length] = 0;
    }
    *name_out = name;
    return NTFS_BRIDGE_OK;
}

static bool valid_component(const char *name)
{
    return name && name[0] != 0 && name[0] != '/' && strchr(name, '/') == NULL;
}

/* MARK: - inode helpers */

static bool is_directory_inode(ntfs_inode *ni)
{
    /* The inode flags field does not carry I30_INDEX_PRESENT on all volumes;
     * the reliable test is whether an INDEX_ROOT attribute exists. */
    ntfs_attr *index = ntfs_attr_open(ni, AT_INDEX_ROOT, NTFS_INDEX_I30, 4);
    if (!index) {
        return false;
    }
    ntfs_attr_close(index);
    return true;
}

static int64_t timespec_to_ns(struct timespec value)
{
    return (int64_t)value.tv_sec * 1000000000LL + value.tv_nsec;
}

static void fill_attrs(const ntfs_inode *ni, ntfs_bridge_attrs *out)
{
    memset(out, 0, sizeof(*out));
    bool directory = is_directory_inode((ntfs_inode *)ni);
    out->file_id = ni->mft_no;
    out->is_directory = directory;
    out->link_count = 1;
    out->size = directory ? 0 : (uint64_t)(ni->data_size < 0 ? 0 : ni->data_size);
    out->allocated_size = directory ? 0 : (uint64_t)(ni->allocated_size < 0 ? 0 : ni->allocated_size);
    /* POSIX mode mapping from security descriptors lands with the M3 follow-up. */
    out->mode = directory ? (S_IFDIR | 0755) : (S_IFREG | 0644);
    out->access_time_ns = timespec_to_ns(ntfs2timespec(ni->last_access_time));
    out->modify_time_ns = timespec_to_ns(ntfs2timespec(ni->last_data_change_time));
    out->change_time_ns = timespec_to_ns(ntfs2timespec(ni->last_mft_change_time));
    out->birth_time_ns = timespec_to_ns(ntfs2timespec(ni->creation_time));
}

static ntfs_inode *open_inode_by_path(ntfs_bridge *bridge, const char *path, ntfs_bridge_status *status)
{
    if (!valid_path(path)) {
        *status = NTFS_BRIDGE_ERR_INVAL;
        return NULL;
    }
    errno = 0;
    ntfs_inode *ni = ntfs_pathname_to_inode(bridge->volume, NULL, path);
    if (!ni) {
        *status = status_from_errno(errno);
        return NULL;
    }
    *status = NTFS_BRIDGE_OK;
    return ni;
}

static ntfs_inode *open_inode_by_id(ntfs_bridge *bridge, uint64_t inode, ntfs_bridge_status *status)
{
    if (inode == 0) {
        *status = NTFS_BRIDGE_ERR_INVAL;
        return NULL;
    }
    errno = 0;
    ntfs_inode *ni = ntfs_inode_open(bridge->volume, (MFT_REF)inode);
    if (!ni) {
        *status = status_from_errno(errno);
        return NULL;
    }
    *status = NTFS_BRIDGE_OK;
    return ni;
}

static bool unsupported_shape(const ntfs_inode *ni)
{
    unsigned long flags = (unsigned long)ni->flags;
    unsigned long masked = flags & (unsigned long)(FILE_ATTR_COMPRESSED |
                                                   FILE_ATTR_ENCRYPTED |
                                                   FILE_ATTR_REPARSE_POINT);
    return masked != 0;
}

/* MARK: - device operations (FSKit block device or any host-provided backend) */

struct bridge_device {
    ntfs_bridge_device_ops user;
    int64_t position;
    int64_t size;
    int64_t sector;
};

static int bridge_dev_open(struct ntfs_device *dev, int flags)
{
    struct bridge_device *device = dev->d_private;
    if ((flags & O_ACCMODE) != O_RDONLY && !device->user.pwrite) {
        errno = EROFS;
        return -1;
    }
    device->size = device->user.device_size(device->user.context);
    if (device->size <= 0) {
        errno = EIO;
        return -1;
    }
    device->sector = device->user.sector_size ? device->user.sector_size(device->user.context) : 512;
    if (device->sector <= 0) {
        device->sector = 512;
    }
    device->position = 0;
    return 0;
}

static int bridge_dev_close(struct ntfs_device *dev)
{
    (void)dev;
    return 0;
}

static s64 bridge_dev_seek(struct ntfs_device *dev, s64 offset, int whence)
{
    struct bridge_device *device = dev->d_private;
    switch (whence) {
    case SEEK_SET: device->position = offset; break;
    case SEEK_CUR: device->position += offset; break;
    case SEEK_END: device->position = device->size + offset; break;
    default:
        errno = EINVAL;
        return -1;
    }
    return device->position;
}

static s64 bridge_dev_read(struct ntfs_device *dev, void *buffer, s64 count)
{
    struct bridge_device *device = dev->d_private;
    if (count <= 0) {
        return 0;
    }
    int64_t got = device->user.pread(device->user.context, buffer, (uint64_t)count, (uint64_t)device->position);
    if (got < 0) {
        return -1;
    }
    device->position += got;
    return got;
}

static s64 bridge_dev_write(struct ntfs_device *dev, const void *buffer, s64 count)
{
    struct bridge_device *device = dev->d_private;
    if (!device->user.pwrite) {
        errno = EROFS;
        return -1;
    }
    if (count <= 0) {
        return 0;
    }
    int64_t put = device->user.pwrite(device->user.context, buffer, (uint64_t)count, (uint64_t)device->position);
    if (put < 0) {
        return -1;
    }
    device->position += put;
    return put;
}

static s64 bridge_dev_pread(struct ntfs_device *dev, void *buffer, s64 count, s64 offset)
{
    struct bridge_device *device = dev->d_private;
    return device->user.pread(device->user.context, buffer, (uint64_t)count, (uint64_t)offset);
}

static s64 bridge_dev_pwrite(struct ntfs_device *dev, const void *buffer, s64 count, s64 offset)
{
    struct bridge_device *device = dev->d_private;
    if (!device->user.pwrite) {
        errno = EROFS;
        return -1;
    }
    return device->user.pwrite(device->user.context, buffer, (uint64_t)count, (uint64_t)offset);
}

static int bridge_dev_sync(struct ntfs_device *dev)
{
    struct bridge_device *device = dev->d_private;
    if (!device->user.sync) {
        return 0;
    }
    return device->user.sync(device->user.context);
}

static int bridge_dev_stat(struct ntfs_device *dev, struct stat *buffer)
{
    struct bridge_device *device = dev->d_private;
    memset(buffer, 0, sizeof(*buffer));
    buffer->st_mode = S_IFBLK | 0666;
    buffer->st_size = device->size;
    buffer->st_blksize = 4096;
    return 0;
}

static int bridge_dev_ioctl(struct ntfs_device *dev, unsigned long request, void *arg)
{
#if defined(__APPLE__)
    struct bridge_device *device = dev->d_private;
    if (request == DKIOCGETBLOCKSIZE) {
        *(int *)arg = (int)device->sector;
        return 0;
    }
    if (request == DKIOCGETBLOCKCOUNT) {
        *(uint64_t *)arg = (uint64_t)(device->size / device->sector);
        return 0;
    }
#else
    (void)dev;
    (void)arg;
#endif
    errno = ENOTTY;
    return -1;
}

static struct ntfs_device_operations bridge_device_operations = {
    .open = bridge_dev_open,
    .close = bridge_dev_close,
    .seek = bridge_dev_seek,
    .read = bridge_dev_read,
    .write = bridge_dev_write,
    .pread = bridge_dev_pread,
    .pwrite = bridge_dev_pwrite,
    .sync = bridge_dev_sync,
    .stat = bridge_dev_stat,
    .ioctl = bridge_dev_ioctl,
};

/* Mounts once. With ops == NULL, uses libntfs-3g's default (path-based) device. */
static ntfs_volume *mount_once(const char *name,
                               const ntfs_bridge_device_ops *ops,
                               bool read_only,
                               struct bridge_device **out_wrapper,
                               int *out_errno)
{
    ntfs_mount_flags flags = read_only ? NTFS_MNT_RDONLY : NTFS_MNT_NONE;
    if (out_wrapper) {
        *out_wrapper = NULL;
    }
    if (!ops) {
        errno = 0;
        ntfs_volume *volume = ntfs_mount(name, flags);
        if (!volume) {
            *out_errno = errno;
        }
        return volume;
    }

    struct bridge_device *wrapper = calloc(1, sizeof(*wrapper));
    if (!wrapper) {
        *out_errno = ENOMEM;
        return NULL;
    }
    wrapper->user = *ops;
    struct ntfs_device *device = ntfs_device_alloc(name, 0L, &bridge_device_operations, wrapper);
    if (!device) {
        *out_errno = errno;
        free(wrapper);
        return NULL;
    }
    errno = 0;
    ntfs_volume *volume = ntfs_device_mount(device, flags);
    if (!volume) {
        *out_errno = errno;
        ntfs_device_free(device);
        free(wrapper);
        return NULL;
    }
    if (out_wrapper) {
        *out_wrapper = wrapper;
    }
    return volume;
}

static void free_wrapper(struct bridge_device *wrapper)
{
    free(wrapper);
}

/*
 * Safety flow: always probe read-only first, inspect dirty/hibernation state,
 * and only remount read/write when the caller asked for it and the volume is
 * clean. Never transiently mounts a dirty volume read/write.
 */
static ntfs_bridge *open_common(const char *name,
                                const ntfs_bridge_device_ops *ops,
                                bool read_only,
                                ntfs_bridge_status *status,
                                bool *downgraded_to_read_only,
                                bool *is_dirty,
                                bool *is_hibernated)
{
    if (status) *status = NTFS_BRIDGE_OK;
    if (downgraded_to_read_only) *downgraded_to_read_only = false;
    if (is_dirty) *is_dirty = false;
    if (is_hibernated) *is_hibernated = false;
    if (!name) {
        if (status) *status = NTFS_BRIDGE_ERR_INVAL;
        return NULL;
    }

    int error = 0;
    struct bridge_device *wrapper = NULL;
    ntfs_volume *volume = mount_once(name, ops, true, &wrapper, &error);
    if (!volume) {
        if (status) *status = status_from_errno(error);
        return NULL;
    }

    bool dirty = (le16_to_cpu(volume->flags) & NTFS_VOLUME_DIRTY_FLAG) != 0;
    bool hibernated = ntfs_volume_check_hiberfile(volume, 0) != 0;
    bool downgraded = false;

    if (!read_only && !dirty && !hibernated) {
        if (ntfs_umount(volume, FALSE)) {
            error = errno;
            free_wrapper(wrapper);
            if (status) *status = status_from_errno(error);
            return NULL;
        }
        free_wrapper(wrapper);
        wrapper = NULL;
        volume = mount_once(name, ops, false, &wrapper, &error);
        if (!volume) {
            if (status) *status = status_from_errno(error);
            return NULL;
        }
    } else {
        downgraded = !read_only;
    }

    ntfs_bridge *bridge = calloc(1, sizeof(*bridge));
    if (!bridge) {
        ntfs_umount(volume, FALSE);
        free_wrapper(wrapper);
        if (status) *status = NTFS_BRIDGE_ERR_IO;
        return NULL;
    }
    bridge->volume = volume;
    bridge->device_wrapper = wrapper;
    bridge->read_only = downgraded || read_only;
    bridge->dirty = dirty;
    bridge->hibernated = hibernated;

    if (downgraded_to_read_only) *downgraded_to_read_only = downgraded;
    if (is_dirty) *is_dirty = dirty;
    if (is_hibernated) *is_hibernated = hibernated;
    return bridge;
}

ntfs_bridge *ntfs_bridge_open(const char *image_path,
                              bool read_only,
                              ntfs_bridge_status *status,
                              bool *downgraded_to_read_only,
                              bool *is_dirty,
                              bool *is_hibernated)
{
    return open_common(image_path, NULL, read_only, status,
                       downgraded_to_read_only, is_dirty, is_hibernated);
}

ntfs_bridge *ntfs_bridge_open_device(const ntfs_bridge_device_ops *ops,
                                     const char *name,
                                     bool read_only,
                                     ntfs_bridge_status *status,
                                     bool *downgraded_to_read_only,
                                     bool *is_dirty,
                                     bool *is_hibernated)
{
    if (!ops || !ops->pread || !ops->device_size) {
        if (status) *status = NTFS_BRIDGE_ERR_INVAL;
        return NULL;
    }
    return open_common(name, ops, read_only, status,
                       downgraded_to_read_only, is_dirty, is_hibernated);
}

ntfs_bridge_status ntfs_bridge_close(ntfs_bridge *bridge)
{
    if (!bridge) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    errno = 0;
    int result = ntfs_umount(bridge->volume, FALSE);
    ntfs_bridge_status status = result ? status_from_errno(errno) : NTFS_BRIDGE_OK;
    free_wrapper(bridge->device_wrapper);
    free(bridge);
    return status;
}

bool ntfs_bridge_is_read_only(const ntfs_bridge *bridge)
{
    return bridge ? bridge->read_only : true;
}

bool ntfs_bridge_was_dirty(const ntfs_bridge *bridge)
{
    return bridge ? bridge->dirty : false;
}

bool ntfs_bridge_was_hibernated(const ntfs_bridge *bridge)
{
    return bridge ? bridge->hibernated : false;
}

ntfs_bridge_status ntfs_bridge_sync(ntfs_bridge *bridge)
{
    if (!bridge) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    if (bridge->read_only) {
        return NTFS_BRIDGE_OK;
    }
    errno = 0;
    if (ntfs_device_sync(bridge->volume->dev)) {
        return status_from_errno(errno);
    }
    return NTFS_BRIDGE_OK;
}

ntfs_bridge_status ntfs_bridge_statfs(ntfs_bridge *bridge, ntfs_bridge_volume_stats *out)
{
    if (!bridge || !out) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    ntfs_volume *volume = bridge->volume;
    if (!volume->cluster_size || volume->nr_clusters <= 0) {
        return NTFS_BRIDGE_ERR_IO;
    }
    memset(out, 0, sizeof(*out));
    out->cluster_size = volume->cluster_size;
    out->total_clusters = (uint64_t)volume->nr_clusters;
    out->free_clusters = (uint64_t)(volume->free_clusters < 0 ? 0 : volume->free_clusters);
    out->total_bytes = out->total_clusters * out->cluster_size;
    out->free_bytes = out->free_clusters * out->cluster_size;
    return NTFS_BRIDGE_OK;
}

/* MARK: - attribute operations */

ntfs_bridge_status ntfs_bridge_getattr_inode(ntfs_bridge *bridge, uint64_t inode, ntfs_bridge_attrs *out)
{
    if (!bridge || !out) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    ntfs_bridge_status status;
    ntfs_inode *ni = open_inode_by_id(bridge, inode, &status);
    if (!ni) {
        return status;
    }
    fill_attrs(ni, out);
    if (ntfs_inode_close(ni)) {
        return NTFS_BRIDGE_ERR_IO;
    }
    return NTFS_BRIDGE_OK;
}

ntfs_bridge_status ntfs_bridge_getattr(ntfs_bridge *bridge, const char *path, ntfs_bridge_attrs *out)
{
    if (!bridge || !out) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    ntfs_bridge_status status;
    ntfs_inode *ni = open_inode_by_path(bridge, path, &status);
    if (!ni) {
        return status;
    }
    fill_attrs(ni, out);
    if (ntfs_inode_close(ni)) {
        return NTFS_BRIDGE_ERR_IO;
    }
    return NTFS_BRIDGE_OK;
}

ntfs_bridge_status ntfs_bridge_lookup(ntfs_bridge *bridge, uint64_t directory_inode, const char *name,
                                      uint64_t *out_inode, ntfs_bridge_attrs *out_attrs)
{
    if (!bridge || !out_inode || !valid_component(name)) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    ntfs_bridge_status status;
    ntfs_inode *dir_ni = open_inode_by_id(bridge, directory_inode, &status);
    if (!dir_ni) {
        return status;
    }
    if (!is_directory_inode(dir_ni)) {
        ntfs_inode_close(dir_ni);
        return NTFS_BRIDGE_ERR_NOT_DIRECTORY;
    }

    ntfschar *unicode = NULL;
    int unicode_length = ntfs_mbstoucs(name, &unicode);
    if (unicode_length < 0) {
        status = status_from_errno(errno);
        free(unicode);
        ntfs_inode_close(dir_ni);
        return status;
    }

    errno = 0;
    u64 mref = ntfs_inode_lookup_by_name(dir_ni, unicode, unicode_length);
    int lookup_errno = errno;
    free(unicode);
    ntfs_inode_close(dir_ni);

    if (mref == (u64)-1) {
        return lookup_errno ? status_from_errno(lookup_errno) : NTFS_BRIDGE_ERR_NOT_FOUND;
    }

    ntfs_inode *ni = open_inode_by_id(bridge, MREF(mref), &status);
    if (!ni) {
        return status;
    }
    fill_attrs(ni, out_attrs);
    *out_inode = ni->mft_no;
    if (ntfs_inode_close(ni)) {
        return NTFS_BRIDGE_ERR_IO;
    }
    return NTFS_BRIDGE_OK;
}

/* MARK: - directory enumeration */

struct readdir_context {
    ntfs_bridge_dir_emit emit;
    void *user;
    bool stopped;
};

static int readdir_filldir(void *dirent,
                           const ntfschar *name,
                           const int name_len,
                           const int name_type,
                           const s64 pos,
                           const MFT_REF mref,
                           const unsigned dt_type)
{
    (void)pos;
    struct readdir_context *context = dirent;

    if (name_type != FILE_NAME_POSIX) {
        return 0;
    }
    if (name_len == 1 && name[0] == '.') {
        return 0;
    }
    if (name_len == 2 && name[0] == '.' && name[1] == '.') {
        return 0;
    }

    char *utf8 = NULL;
    int length = ntfs_ucstombs(name, name_len, &utf8, 0);
    if (length < 0 || !utf8) {
        free(utf8);
        return 0;
    }

    ntfs_bridge_dirent entry;
    memset(&entry, 0, sizeof(entry));
    strncpy(entry.name, utf8, sizeof(entry.name) - 1);
    free(utf8);
    entry.file_id = MREF(mref);

    switch (dt_type) {
    case NTFS_DT_REG: entry.type = NTFS_BRIDGE_TYPE_FILE; break;
    case NTFS_DT_DIR: entry.type = NTFS_BRIDGE_TYPE_DIRECTORY; break;
    case NTFS_DT_LNK: entry.type = NTFS_BRIDGE_TYPE_SYMLINK; break;
    default: entry.type = NTFS_BRIDGE_TYPE_UNKNOWN; break;
    }

    if (context->emit && !context->emit(context->user, &entry)) {
        context->stopped = true;
        return 1;
    }
    return 0;
}

static ntfs_bridge_status readdir_inode_core(ntfs_bridge *bridge, ntfs_inode *ni,
                                             ntfs_bridge_dir_emit emit, void *context)
{
    (void)bridge;
    if (!is_directory_inode(ni)) {
        return NTFS_BRIDGE_ERR_NOT_DIRECTORY;
    }
    struct readdir_context readdir = { .emit = emit, .user = context, .stopped = false };
    s64 position = 0;
    errno = 0;
    int result = ntfs_readdir(ni, &position, &readdir, readdir_filldir);
    int error = errno;
    if (result && !readdir.stopped) {
        return status_from_errno(error);
    }
    return NTFS_BRIDGE_OK;
}

ntfs_bridge_status ntfs_bridge_readdir_inode(ntfs_bridge *bridge, uint64_t inode,
                                             ntfs_bridge_dir_emit emit, void *context)
{
    if (!bridge || !emit) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    ntfs_bridge_status status;
    ntfs_inode *ni = open_inode_by_id(bridge, inode, &status);
    if (!ni) {
        return status;
    }
    status = readdir_inode_core(bridge, ni, emit, context);
    ntfs_inode_close(ni);
    return status;
}

ntfs_bridge_status ntfs_bridge_readdir(ntfs_bridge *bridge, const char *path,
                                       ntfs_bridge_dir_emit emit, void *context)
{
    if (!bridge || !emit) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    ntfs_bridge_status status;
    ntfs_inode *ni = open_inode_by_path(bridge, path, &status);
    if (!ni) {
        return status;
    }
    status = readdir_inode_core(bridge, ni, emit, context);
    ntfs_inode_close(ni);
    return status;
}

/* MARK: - create / unlink / rename */

ntfs_bridge_status ntfs_bridge_create(ntfs_bridge *bridge, const char *path, bool directory)
{
    if (!bridge || bridge->read_only) {
        return NTFS_BRIDGE_ERR_PERM;
    }
    char parent[4096];
    const char *name;
    ntfs_bridge_status status = split_parent(path, parent, sizeof(parent), &name);
    if (status != NTFS_BRIDGE_OK || !valid_component(name)) {
        return status == NTFS_BRIDGE_OK ? NTFS_BRIDGE_ERR_INVAL : status;
    }

    ntfs_inode *dir_ni = open_inode_by_path(bridge, parent, &status);
    if (!dir_ni) {
        return status;
    }
    if (!is_directory_inode(dir_ni)) {
        ntfs_inode_close(dir_ni);
        return NTFS_BRIDGE_ERR_NOT_DIRECTORY;
    }

    ntfschar *unicode = NULL;
    int unicode_length = ntfs_mbstoucs(name, &unicode);
    if (unicode_length < 0) {
        status = status_from_errno(errno);
        free(unicode);
        ntfs_inode_close(dir_ni);
        return status;
    }

    errno = 0;
    ntfs_inode *ni = ntfs_create(dir_ni, const_cpu_to_le32(0),
                                 unicode, (u8)unicode_length,
                                 directory ? S_IFDIR : S_IFREG);
    if (!ni) {
        status = status_from_errno(errno);
        free(unicode);
        ntfs_inode_close(dir_ni);
        return status;
    }

    if (!(ni->flags & FILE_ATTR_ARCHIVE)) {
        ni->flags |= FILE_ATTR_ARCHIVE;
        NInoSetDirty(ni);
    }
    if (ntfs_inode_close_in_dir(ni, dir_ni)) {
        status = NTFS_BRIDGE_ERR_IO;
    } else {
        status = NTFS_BRIDGE_OK;
    }
    free(unicode);
    ntfs_inode_close(dir_ni);
    return status;
}

ntfs_bridge_status ntfs_bridge_unlink(ntfs_bridge *bridge, const char *path)
{
    if (!bridge || bridge->read_only) {
        return NTFS_BRIDGE_ERR_PERM;
    }
    ntfs_bridge_status status;
    ntfs_inode *ni = open_inode_by_path(bridge, path, &status);
    if (!ni) {
        return status;
    }
    if (ni->mft_no < FILE_first_user) {
        ntfs_inode_close(ni);
        return NTFS_BRIDGE_ERR_PERM;
    }

    char parent[4096];
    const char *name;
    status = split_parent(path, parent, sizeof(parent), &name);
    if (status != NTFS_BRIDGE_OK) {
        ntfs_inode_close(ni);
        return status;
    }
    ntfs_inode *dir_ni = open_inode_by_path(bridge, parent, &status);
    if (!dir_ni) {
        ntfs_inode_close(ni);
        return status;
    }

    ntfschar *unicode = NULL;
    int unicode_length = ntfs_mbstoucs(name, &unicode);
    if (unicode_length < 0) {
        status = status_from_errno(errno);
        free(unicode);
        ntfs_inode_close(ni);
        ntfs_inode_close(dir_ni);
        return status;
    }

    errno = 0;
    /* ntfs_delete() closes ni and dir_ni on success and failure. */
    int result = ntfs_delete(bridge->volume, path, ni, dir_ni, unicode, (u8)unicode_length);
    status = result ? status_from_errno(errno) : NTFS_BRIDGE_OK;
    free(unicode);
    return status;
}

ntfs_bridge_status ntfs_bridge_rename(ntfs_bridge *bridge, const char *from, const char *to)
{
    if (!bridge || bridge->read_only) {
        return NTFS_BRIDGE_ERR_PERM;
    }
    if (!valid_path(from) || !valid_path(to) ||
        strcmp(from, "/") == 0 || strcmp(to, "/") == 0) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    if (strcmp(from, to) == 0) {
        return NTFS_BRIDGE_OK;
    }

    ntfs_bridge_status status;
    char dest_parent[4096];
    const char *dest_name = NULL;
    status = split_parent(to, dest_parent, sizeof(dest_parent), &dest_name);
    if (status != NTFS_BRIDGE_OK) {
        return status;
    }

    /* Open source inode; it stays open through link and delete. */
    ntfs_inode *src_ni = open_inode_by_path(bridge, from, &status);
    if (!src_ni) {
        return status;
    }
    if (src_ni->mft_no < FILE_first_user) {
        ntfs_inode_close(src_ni);
        return NTFS_BRIDGE_ERR_PERM;
    }

    ntfs_inode *dest_dir_ni = open_inode_by_path(bridge, dest_parent, &status);
    if (!dest_dir_ni) {
        ntfs_inode_close(src_ni);
        return status;
    }

    ntfschar *dest_unicode = NULL;
    int dest_length = ntfs_mbstoucs(dest_name, &dest_unicode);
    if (dest_length < 0) {
        status = status_from_errno(errno);
        free(dest_unicode);
        ntfs_inode_close(src_ni);
        ntfs_inode_close(dest_dir_ni);
        return status;
    }

    /* Existing destination: replace it first. Non-atomic (upstream FIXME). */
    ntfs_inode *existing_ni = NULL;
    errno = 0;
    ntfs_inode *found = ntfs_pathname_to_inode(bridge->volume, NULL, to);
    int find_errno = errno;
    if (found) {
        existing_ni = found;
    } else if (find_errno != ENOENT) {
        status = status_from_errno(find_errno);
        goto cleanup;
    }

    if (existing_ni) {
        if (existing_ni->mft_no == src_ni->mft_no) {
            status = NTFS_BRIDGE_OK;
            ntfs_inode_close(existing_ni);
            goto cleanup;
        }
        if (is_directory_inode(existing_ni) && ntfs_check_empty_dir(existing_ni) < 0) {
            status = NTFS_BRIDGE_ERR_NOT_EMPTY;
            ntfs_inode_close(existing_ni);
            goto cleanup;
        }
        ntfs_inode *dest_dir_for_delete = open_inode_by_path(bridge, dest_parent, &status);
        if (!dest_dir_for_delete) {
            ntfs_inode_close(existing_ni);
            goto cleanup;
        }
        ntfschar *delete_unicode = NULL;
        int delete_length = ntfs_mbstoucs(dest_name, &delete_unicode);
        if (delete_length < 0) {
            status = status_from_errno(errno);
            free(delete_unicode);
            ntfs_inode_close(existing_ni);
            ntfs_inode_close(dest_dir_for_delete);
            goto cleanup;
        }
        errno = 0;
        /* Closes existing_ni and dest_dir_for_delete. */
        if (ntfs_delete(bridge->volume, to, existing_ni, dest_dir_for_delete,
                        delete_unicode, (u8)delete_length)) {
            status = status_from_errno(errno);
            free(delete_unicode);
            goto cleanup;
        }
        free(delete_unicode);
    }

    /* Hard-link source into destination. */
    errno = 0;
    if (ntfs_link(src_ni, dest_dir_ni, dest_unicode, (u8)dest_length)) {
        status = status_from_errno(errno);
        ntfs_inode_close(src_ni);
        goto cleanup;
    }

    /* Remove the old name. */
    {
        char src_parent[4096];
        const char *src_name = NULL;
        status = split_parent(from, src_parent, sizeof(src_parent), &src_name);
        if (status != NTFS_BRIDGE_OK) {
            ntfs_inode_close(src_ni);
            goto rollback;
        }
        ntfs_inode *src_dir_ni = open_inode_by_path(bridge, src_parent, &status);
        if (!src_dir_ni) {
            ntfs_inode_close(src_ni);
            goto rollback;
        }
        ntfschar *src_unicode = NULL;
        int src_length = ntfs_mbstoucs(src_name, &src_unicode);
        if (src_length < 0) {
            status = status_from_errno(errno);
            free(src_unicode);
            ntfs_inode_close(src_ni);
            ntfs_inode_close(src_dir_ni);
            goto rollback;
        }
        errno = 0;
        /* Closes src_ni and src_dir_ni. */
        int delete_result = ntfs_delete(bridge->volume, from, src_ni, src_dir_ni,
                                        src_unicode, (u8)src_length);
        free(src_unicode);
        if (delete_result) {
            status = status_from_errno(errno);
            goto rollback;
        }
        status = NTFS_BRIDGE_OK;
        goto cleanup;
    }

rollback: {
        /* Remove the new link to restore the original name. */
        errno = 0;
        ntfs_inode *rollback_ni = ntfs_pathname_to_inode(bridge->volume, NULL, to);
        ntfs_inode *rollback_dir = open_inode_by_path(bridge, dest_parent, &status);
        ntfschar *rollback_unicode = NULL;
        int rollback_length = ntfs_mbstoucs(dest_name, &rollback_unicode);
        if (rollback_ni && rollback_dir && rollback_length >= 0) {
            ntfs_delete(bridge->volume, to, rollback_ni, rollback_dir,
                        rollback_unicode, (u8)rollback_length);
        } else {
            if (rollback_ni) ntfs_inode_close(rollback_ni);
            if (rollback_dir) ntfs_inode_close(rollback_dir);
        }
        free(rollback_unicode);
    }

cleanup:
    free(dest_unicode);
    ntfs_inode_close(dest_dir_ni);
    return status;
}

/* MARK: - file data */

static ntfs_bridge_status read_inode_core(ntfs_bridge *bridge, ntfs_inode *ni, uint64_t offset,
                                          void *buffer, size_t length, size_t *out_read)
{
    (void)bridge;
    if (!buffer) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    if (out_read) {
        *out_read = 0;
    }
    if (is_directory_inode(ni)) {
        return NTFS_BRIDGE_ERR_IS_DIRECTORY;
    }
    if (unsupported_shape(ni)) {
        return NTFS_BRIDGE_ERR_NOT_SUPPORTED;
    }

    errno = 0;
    ntfs_attr *attribute = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!attribute) {
        return status_from_errno(errno);
    }

    size_t total = 0;
    ntfs_bridge_status status = NTFS_BRIDGE_OK;
    while (total < length) {
        s64 got = ntfs_attr_pread(attribute, (s64)(offset + total), (s64)(length - total),
                                  (char *)buffer + total);
        if (got < 0) {
            status = status_from_errno(errno);
            break;
        }
        if (got == 0) {
            break; /* end of file */
        }
        total += (size_t)got;
    }

    ntfs_attr_close(attribute);
    if (status == NTFS_BRIDGE_OK && out_read) {
        *out_read = total;
    }
    return status;
}

static ntfs_bridge_status write_inode_core(ntfs_bridge *bridge, ntfs_inode *ni, uint64_t offset,
                                           const void *buffer, size_t length, size_t *out_written)
{
    if (!buffer) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    if (bridge->read_only) {
        return NTFS_BRIDGE_ERR_PERM;
    }
    if (out_written) {
        *out_written = 0;
    }
    if (is_directory_inode(ni)) {
        return NTFS_BRIDGE_ERR_IS_DIRECTORY;
    }
    if (unsupported_shape(ni)) {
        return NTFS_BRIDGE_ERR_NOT_SUPPORTED;
    }

    errno = 0;
    ntfs_attr *attribute = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!attribute) {
        return status_from_errno(errno);
    }

    size_t total = 0;
    ntfs_bridge_status status = NTFS_BRIDGE_OK;
    while (total < length) {
        s64 put = ntfs_attr_pwrite(attribute, (s64)(offset + total), (s64)(length - total),
                                   (const char *)buffer + total);
        if (put <= 0) {
            status = status_from_errno(errno);
            break;
        }
        total += (size_t)put;
    }

    if (status == NTFS_BRIDGE_OK) {
        NInoSetDirty(ni);
        if (out_written) {
            *out_written = total;
        }
    }
    ntfs_attr_close(attribute);
    return status;
}

static ntfs_bridge_status truncate_inode_core(ntfs_bridge *bridge, ntfs_inode *ni, uint64_t size)
{
    if (bridge->read_only) {
        return NTFS_BRIDGE_ERR_PERM;
    }
    if (is_directory_inode(ni)) {
        return NTFS_BRIDGE_ERR_IS_DIRECTORY;
    }
    if (unsupported_shape(ni)) {
        return NTFS_BRIDGE_ERR_NOT_SUPPORTED;
    }
    if (size > (uint64_t)INT64_MAX) {
        return NTFS_BRIDGE_ERR_INVAL;
    }

    errno = 0;
    ntfs_attr *attribute = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!attribute) {
        return status_from_errno(errno);
    }

    ntfs_bridge_status status = NTFS_BRIDGE_OK;
    if (ntfs_attr_truncate(attribute, (s64)size)) {
        status = status_from_errno(errno);
    } else {
        NInoSetDirty(ni);
    }
    ntfs_attr_close(attribute);
    return status;
}

ntfs_bridge_status ntfs_bridge_read_inode(ntfs_bridge *bridge, uint64_t inode, uint64_t offset,
                                          void *buffer, size_t length, size_t *out_read)
{
    if (!bridge) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    ntfs_bridge_status status;
    ntfs_inode *ni = open_inode_by_id(bridge, inode, &status);
    if (!ni) {
        return status;
    }
    status = read_inode_core(bridge, ni, offset, buffer, length, out_read);
    ntfs_inode_close(ni);
    return status;
}

ntfs_bridge_status ntfs_bridge_write_inode(ntfs_bridge *bridge, uint64_t inode, uint64_t offset,
                                           const void *buffer, size_t length, size_t *out_written)
{
    if (!bridge) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    ntfs_bridge_status status;
    ntfs_inode *ni = open_inode_by_id(bridge, inode, &status);
    if (!ni) {
        return status;
    }
    status = write_inode_core(bridge, ni, offset, buffer, length, out_written);
    ntfs_inode_close(ni);
    return status;
}

ntfs_bridge_status ntfs_bridge_truncate_inode(ntfs_bridge *bridge, uint64_t inode, uint64_t size)
{
    if (!bridge) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    ntfs_bridge_status status;
    ntfs_inode *ni = open_inode_by_id(bridge, inode, &status);
    if (!ni) {
        return status;
    }
    status = truncate_inode_core(bridge, ni, size);
    ntfs_inode_close(ni);
    return status;
}

ntfs_bridge_status ntfs_bridge_read(ntfs_bridge *bridge, const char *path, uint64_t offset,
                                    void *buffer, size_t length, size_t *out_read)
{
    if (!bridge) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    ntfs_bridge_status status;
    ntfs_inode *ni = open_inode_by_path(bridge, path, &status);
    if (!ni) {
        return status;
    }
    status = read_inode_core(bridge, ni, offset, buffer, length, out_read);
    ntfs_inode_close(ni);
    return status;
}

ntfs_bridge_status ntfs_bridge_write(ntfs_bridge *bridge, const char *path, uint64_t offset,
                                     const void *buffer, size_t length, size_t *out_written)
{
    if (!bridge) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    if (bridge->read_only) {
        return NTFS_BRIDGE_ERR_PERM;
    }
    ntfs_bridge_status status;
    ntfs_inode *ni = open_inode_by_path(bridge, path, &status);
    if (!ni) {
        return status;
    }
    status = write_inode_core(bridge, ni, offset, buffer, length, out_written);
    ntfs_inode_close(ni);
    return status;
}

ntfs_bridge_status ntfs_bridge_truncate(ntfs_bridge *bridge, const char *path, uint64_t size)
{
    if (!bridge) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    if (bridge->read_only) {
        return NTFS_BRIDGE_ERR_PERM;
    }
    ntfs_bridge_status status;
    ntfs_inode *ni = open_inode_by_path(bridge, path, &status);
    if (!ni) {
        return status;
    }
    status = truncate_inode_core(bridge, ni, size);
    ntfs_inode_close(ni);
    return status;
}

/* MARK: - fixtures */

ntfs_bridge_status ntfs_bridge_test_mark_dirty(ntfs_bridge *bridge)
{
    if (!bridge || bridge->read_only) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    le16 flags = bridge->volume->flags | const_cpu_to_le16(NTFS_VOLUME_DIRTY_FLAG);
    errno = 0;
    if (ntfs_volume_write_flags(bridge->volume, flags)) {
        return status_from_errno(errno);
    }
    if (ntfs_device_sync(bridge->volume->dev)) {
        return status_from_errno(errno);
    }
    return NTFS_BRIDGE_OK;
}
