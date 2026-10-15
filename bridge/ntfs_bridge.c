#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "ntfs_bridge.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include <ntfs-3g/attrib.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/layout.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/volume.h>

struct ntfs_bridge {
    ntfs_volume *volume;
    bool read_only;
    bool dirty;
    bool hibernated;
};

#define NTFS_VOLUME_DIRTY_FLAG 0x0001

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
    case ENOSPC: return NTFS_BRIDGE_ERR_NO_SPACE;
    case EOPNOTSUPP: return NTFS_BRIDGE_ERR_NOT_SUPPORTED;
    default: return NTFS_BRIDGE_ERR_IO;
    }
}

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

/* Reject anything that could escape the volume or confuse the split. */
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

static ntfs_inode *open_inode(ntfs_bridge *bridge, const char *path, ntfs_bridge_status *status)
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

ntfs_bridge *ntfs_bridge_open(const char *image_path,
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

    if (!image_path) {
        if (status) *status = NTFS_BRIDGE_ERR_INVAL;
        return NULL;
    }

    /* Always probe read-only first so a dirty or hibernated volume is never
     * even transiently mounted for writing. */
    errno = 0;
    ntfs_volume *volume = ntfs_mount(image_path, NTFS_MNT_RDONLY);
    if (!volume) {
        if (status) *status = status_from_errno(errno);
        return NULL;
    }

    bool dirty = (le16_to_cpu(volume->flags) & NTFS_VOLUME_DIRTY_FLAG) != 0;
    bool hibernated = ntfs_volume_check_hiberfile(volume, 0) != 0;
    bool downgraded = false;

    if (!read_only && !dirty && !hibernated) {
        if (ntfs_umount(volume, FALSE)) {
            if (status) *status = status_from_errno(errno);
            return NULL;
        }
        errno = 0;
        volume = ntfs_mount(image_path, NTFS_MNT_NONE);
        if (!volume) {
            if (status) *status = status_from_errno(errno);
            return NULL;
        }
    } else {
        downgraded = !read_only;
    }

    ntfs_bridge *bridge = calloc(1, sizeof(*bridge));
    if (!bridge) {
        ntfs_umount(volume, FALSE);
        if (status) *status = NTFS_BRIDGE_ERR_IO;
        return NULL;
    }
    bridge->volume = volume;
    bridge->read_only = downgraded || read_only;
    bridge->dirty = dirty;
    bridge->hibernated = hibernated;

    if (downgraded_to_read_only) *downgraded_to_read_only = downgraded;
    if (is_dirty) *is_dirty = dirty;
    if (is_hibernated) *is_hibernated = hibernated;
    return bridge;
}

ntfs_bridge_status ntfs_bridge_close(ntfs_bridge *bridge)
{
    if (!bridge) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    errno = 0;
    int result = ntfs_umount(bridge->volume, FALSE);
    ntfs_bridge_status status = result ? status_from_errno(errno) : NTFS_BRIDGE_OK;
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

static int64_t timespec_to_ns(struct timespec value)
{
    return (int64_t)value.tv_sec * 1000000000LL + value.tv_nsec;
}

ntfs_bridge_status ntfs_bridge_getattr(ntfs_bridge *bridge, const char *path, ntfs_bridge_attrs *out)
{
    if (!bridge || !out) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    ntfs_bridge_status status;
    ntfs_inode *ni = open_inode(bridge, path, &status);
    if (!ni) {
        return status;
    }

    memset(out, 0, sizeof(*out));
    bool directory = is_directory_inode(ni);
    out->file_id = ni->mft_no;
    out->is_directory = directory;
    out->link_count = 1;
    out->size = directory ? 0 : (uint64_t)(ni->data_size < 0 ? 0 : ni->data_size);
    out->allocated_size = directory ? 0 : (uint64_t)(ni->allocated_size < 0 ? 0 : ni->allocated_size);
    /* POSIX mode mapping from security descriptors lands with the M3 bridge. */
    out->mode = directory ? (S_IFDIR | 0755) : (S_IFREG | 0644);
    out->access_time_ns = timespec_to_ns(ntfs2timespec(ni->last_access_time));
    out->modify_time_ns = timespec_to_ns(ntfs2timespec(ni->last_data_change_time));
    out->change_time_ns = timespec_to_ns(ntfs2timespec(ni->last_mft_change_time));
    out->birth_time_ns = timespec_to_ns(ntfs2timespec(ni->creation_time));

    if (ntfs_inode_close(ni)) {
        return NTFS_BRIDGE_ERR_IO;
    }
    return NTFS_BRIDGE_OK;
}

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

ntfs_bridge_status ntfs_bridge_readdir(ntfs_bridge *bridge, const char *path,
                                       ntfs_bridge_dir_emit emit, void *context)
{
    if (!bridge) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    if (!emit) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    ntfs_bridge_status status;
    ntfs_inode *ni = open_inode(bridge, path, &status);
    if (!ni) {
        return status;
    }
    if (!is_directory_inode(ni)) {
        ntfs_inode_close(ni);
        return NTFS_BRIDGE_ERR_NOT_DIRECTORY;
    }

    struct readdir_context readdir = { .emit = emit, .user = context, .stopped = false };
    s64 position = 0;
    errno = 0;
    int result = ntfs_readdir(ni, &position, &readdir, readdir_filldir);
    int error = errno;
    ntfs_inode_close(ni);

    if (result && !readdir.stopped) {
        return status_from_errno(error);
    }
    return NTFS_BRIDGE_OK;
}

ntfs_bridge_status ntfs_bridge_create(ntfs_bridge *bridge, const char *path, bool directory)
{
    if (!bridge || bridge->read_only) {
        return NTFS_BRIDGE_ERR_PERM;
    }
    char parent[4096];
    const char *name;
    ntfs_bridge_status status = split_parent(path, parent, sizeof(parent), &name);
    if (status != NTFS_BRIDGE_OK) {
        return status;
    }

    ntfs_inode *dir_ni = open_inode(bridge, parent, &status);
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
        ntfs_inode_close(dir_ni);
        return status_from_errno(errno);
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
    ntfs_inode *ni = open_inode(bridge, path, &status);
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
    ntfs_inode *dir_ni = open_inode(bridge, parent, &status);
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

static bool unsupported_shape(const ntfs_inode *ni)
{
    unsigned long flags = (unsigned long)ni->flags;
    unsigned long masked = flags & (unsigned long)(FILE_ATTR_COMPRESSED |
                                                   FILE_ATTR_ENCRYPTED |
                                                   FILE_ATTR_REPARSE_POINT);
    return masked != 0;
}

ntfs_bridge_status ntfs_bridge_read(ntfs_bridge *bridge, const char *path, uint64_t offset,
                                    void *buffer, size_t length, size_t *out_read)
{
    if (!bridge || !buffer) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    if (out_read) {
        *out_read = 0;
    }
    ntfs_bridge_status status;
    ntfs_inode *ni = open_inode(bridge, path, &status);
    if (!ni) {
        return status;
    }
    if (is_directory_inode(ni)) {
        ntfs_inode_close(ni);
        return NTFS_BRIDGE_ERR_IS_DIRECTORY;
    }
    if (unsupported_shape(ni)) {
        ntfs_inode_close(ni);
        return NTFS_BRIDGE_ERR_NOT_SUPPORTED;
    }

    errno = 0;
    ntfs_attr *attribute = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!attribute) {
        status = status_from_errno(errno);
        ntfs_inode_close(ni);
        return status;
    }

    size_t total = 0;
    while (total < length) {
        s64 read = ntfs_attr_pread(attribute, (s64)(offset + total), (s64)(length - total),
                                   (char *)buffer + total);
        if (read < 0) {
            status = status_from_errno(errno);
            ntfs_attr_close(attribute);
            ntfs_inode_close(ni);
            return status;
        }
        if (read == 0) {
            break; /* end of file */
        }
        total += (size_t)read;
    }

    ntfs_attr_close(attribute);
    ntfs_inode_close(ni);
    if (out_read) {
        *out_read = total;
    }
    return NTFS_BRIDGE_OK;
}

ntfs_bridge_status ntfs_bridge_write(ntfs_bridge *bridge, const char *path, uint64_t offset,
                                     const void *buffer, size_t length, size_t *out_written)
{
    if (!bridge || !buffer) {
        return NTFS_BRIDGE_ERR_INVAL;
    }
    if (bridge->read_only) {
        return NTFS_BRIDGE_ERR_PERM;
    }
    if (out_written) {
        *out_written = 0;
    }
    ntfs_bridge_status status;
    ntfs_inode *ni = open_inode(bridge, path, &status);
    if (!ni) {
        return status;
    }
    if (is_directory_inode(ni)) {
        ntfs_inode_close(ni);
        return NTFS_BRIDGE_ERR_IS_DIRECTORY;
    }
    if (unsupported_shape(ni)) {
        ntfs_inode_close(ni);
        return NTFS_BRIDGE_ERR_NOT_SUPPORTED;
    }

    errno = 0;
    ntfs_attr *attribute = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!attribute) {
        status = status_from_errno(errno);
        ntfs_inode_close(ni);
        return status;
    }

    size_t total = 0;
    while (total < length) {
        s64 written = ntfs_attr_pwrite(attribute, (s64)(offset + total), (s64)(length - total),
                                       (const char *)buffer + total);
        if (written <= 0) {
            status = status_from_errno(errno);
            ntfs_attr_close(attribute);
            ntfs_inode_close(ni);
            return status;
        }
        total += (size_t)written;
    }

    NInoSetDirty(ni);
    ntfs_attr_close(attribute);
    ntfs_inode_close(ni);
    if (out_written) {
        *out_written = total;
    }
    return NTFS_BRIDGE_OK;
}

ntfs_bridge_status ntfs_bridge_truncate(ntfs_bridge *bridge, const char *path, uint64_t size)
{
    if (!bridge || bridge->read_only) {
        return NTFS_BRIDGE_ERR_PERM;
    }
    ntfs_bridge_status status;
    ntfs_inode *ni = open_inode(bridge, path, &status);
    if (!ni) {
        return status;
    }
    if (is_directory_inode(ni)) {
        ntfs_inode_close(ni);
        return NTFS_BRIDGE_ERR_IS_DIRECTORY;
    }
    if (unsupported_shape(ni)) {
        ntfs_inode_close(ni);
        return NTFS_BRIDGE_ERR_NOT_SUPPORTED;
    }

    errno = 0;
    ntfs_attr *attribute = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!attribute) {
        status = status_from_errno(errno);
        ntfs_inode_close(ni);
        return status;
    }

    if (size > (uint64_t)INT64_MAX) {
        ntfs_attr_close(attribute);
        ntfs_inode_close(ni);
        return NTFS_BRIDGE_ERR_INVAL;
    }

    status = NTFS_BRIDGE_OK;
    if (ntfs_attr_truncate(attribute, (s64)size)) {
        status = status_from_errno(errno);
    } else {
        NInoSetDirty(ni);
    }
    ntfs_attr_close(attribute);
    ntfs_inode_close(ni);
    return status;
}

ntfs_bridge_status ntfs_bridge_rename(ntfs_bridge *bridge, const char *from, const char *to)
{
    (void)bridge;
    (void)from;
    (void)to;
    /* Renaming (including fsync of both parent indexes) arrives with M3. */
    return NTFS_BRIDGE_ERR_NOT_SUPPORTED;
}

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
