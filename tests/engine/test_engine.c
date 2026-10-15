/*
 * Engine tests for the libntfs-3g bridge. Disposable images only; the runner
 * script creates them with scripts/make-test-image.sh. No FSKit involved.
 */

#include "../../bridge/ntfs_bridge.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;
static int checks = 0;

#define CHECK(condition, ...)                                     \
    do {                                                          \
        checks++;                                                 \
        if (!(condition)) {                                       \
            failures++;                                           \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);  \
            fprintf(stderr, __VA_ARGS__);                         \
            fprintf(stderr, "\n");                                \
        }                                                         \
    } while (0)

static void fill_pattern(uint8_t *buffer, size_t length, uint32_t seed)
{
    uint32_t state = seed ? seed : 1;
    for (size_t i = 0; i < length; i++) {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        buffer[i] = (uint8_t)(state & 0xff);
    }
}

static ntfs_bridge *open_expect(const char *image, bool read_only,
                                bool expect_downgraded, bool expect_dirty, bool expect_hibernated,
                                const char *label)
{
    ntfs_bridge_status status = NTFS_BRIDGE_ERR_IO;
    bool downgraded = false, dirty = false, hibernated = false;
    ntfs_bridge *bridge = ntfs_bridge_open(image, read_only, &status, &downgraded, &dirty, &hibernated);
    CHECK(bridge != NULL, "%s: open failed: %s", label, ntfs_bridge_strerror(status));
    if (!bridge) {
        return NULL;
    }
    CHECK(downgraded == expect_downgraded, "%s: downgraded=%d expected=%d", label, downgraded, expect_downgraded);
    CHECK(dirty == expect_dirty, "%s: dirty=%d expected=%d", label, dirty, expect_dirty);
    CHECK(hibernated == expect_hibernated, "%s: hibernated=%d expected=%d", label, hibernated, expect_hibernated);
    CHECK(ntfs_bridge_is_read_only(bridge) == (read_only || expect_downgraded),
          "%s: read-only state mismatch", label);
    return bridge;
}

struct list_context {
    char names[64][256];
    int count;
};

static bool collect_entry(void *context, const ntfs_bridge_dirent *entry)
{
    struct list_context *list = context;
    if (list->count < 64) {
        snprintf(list->names[list->count], sizeof(list->names[0]), "%s", entry->name);
        list->count++;
    }
    return true;
}

static bool list_contains(const struct list_context *list, const char *name)
{
    for (int i = 0; i < list->count; i++) {
        if (strcmp(list->names[i], name) == 0) {
            return true;
        }
    }
    return false;
}

static void test_read_write_cycle(const char *image)
{
    printf("== read/write cycle (%s)\n", image);
    const size_t pattern_size = 65536;
    uint8_t *pattern = malloc(pattern_size);
    uint8_t *readback = malloc(pattern_size);
    fill_pattern(pattern, pattern_size, 0x5eed);

    ntfs_bridge *bridge = open_expect(image, false, false, false, false, "rw-open");
    if (!bridge) {
        free(pattern);
        free(readback);
        return;
    }

    CHECK(ntfs_bridge_create(bridge, "/hello.txt", false) == NTFS_BRIDGE_OK, "create hello.txt");
    const char *hello = "hello, ntfs\n";
    size_t written = 0;
    CHECK(ntfs_bridge_write(bridge, "/hello.txt", 0, hello, strlen(hello), &written) == NTFS_BRIDGE_OK,
          "write hello.txt");
    CHECK(written == strlen(hello), "hello.txt written=%zu", written);

    CHECK(ntfs_bridge_create(bridge, "/dir", true) == NTFS_BRIDGE_OK, "create dir");

    ntfs_bridge_attrs attrs;
    CHECK(ntfs_bridge_getattr(bridge, "/dir", &attrs) == NTFS_BRIDGE_OK, "getattr dir");
    CHECK(attrs.is_directory, "dir reported as directory");

    CHECK(ntfs_bridge_create(bridge, "/dir/data.bin", false) == NTFS_BRIDGE_OK, "create data.bin");
    written = 0;
    CHECK(ntfs_bridge_write(bridge, "/dir/data.bin", 0, pattern, pattern_size, &written) == NTFS_BRIDGE_OK,
          "write data.bin");
    CHECK(written == pattern_size, "data.bin written=%zu", written);

    CHECK(ntfs_bridge_sync(bridge) == NTFS_BRIDGE_OK, "sync");
    CHECK(ntfs_bridge_close(bridge) == NTFS_BRIDGE_OK, "close after writes");

    bridge = open_expect(image, true, false, false, false, "ro-open");
    if (!bridge) {
        free(pattern);
        free(readback);
        return;
    }

    memset(readback, 0, pattern_size);
    size_t read_bytes = 0;
    CHECK(ntfs_bridge_read(bridge, "/hello.txt", 0, readback, pattern_size, &read_bytes) == NTFS_BRIDGE_OK,
          "read hello.txt");
    CHECK(read_bytes == strlen(hello) && memcmp(readback, hello, strlen(hello)) == 0,
          "hello.txt contents");

    memset(readback, 0, pattern_size);
    CHECK(ntfs_bridge_read(bridge, "/dir/data.bin", 0, readback, pattern_size, &read_bytes) == NTFS_BRIDGE_OK,
          "read data.bin");
    CHECK(read_bytes == pattern_size, "data.bin read=%zu", read_bytes);
    CHECK(memcmp(readback, pattern, pattern_size) == 0, "data.bin contents match");

    CHECK(ntfs_bridge_getattr(bridge, "/dir/data.bin", &attrs) == NTFS_BRIDGE_OK, "getattr data.bin");
    CHECK(attrs.size == pattern_size, "data.bin size=%" PRIu64, attrs.size);
    CHECK(!attrs.is_directory, "data.bin is not a directory");

    struct list_context root = { .count = 0 };
    CHECK(ntfs_bridge_readdir(bridge, "/", collect_entry, &root) == NTFS_BRIDGE_OK, "readdir /");
    CHECK(list_contains(&root, "hello.txt"), "root lists hello.txt");
    CHECK(list_contains(&root, "dir"), "root lists dir");

    struct list_context sub = { .count = 0 };
    CHECK(ntfs_bridge_readdir(bridge, "/dir", collect_entry, &sub) == NTFS_BRIDGE_OK, "readdir /dir");
    CHECK(list_contains(&sub, "data.bin"), "dir lists data.bin");

    CHECK(ntfs_bridge_close(bridge) == NTFS_BRIDGE_OK, "close ro");

    bridge = open_expect(image, false, false, false, false, "rw-truncate");
    if (bridge) {
        CHECK(ntfs_bridge_truncate(bridge, "/dir/data.bin", 4096) == NTFS_BRIDGE_OK, "truncate");
        CHECK(ntfs_bridge_sync(bridge) == NTFS_BRIDGE_OK, "sync truncate");
        CHECK(ntfs_bridge_close(bridge) == NTFS_BRIDGE_OK, "close truncate");
    }

    bridge = open_expect(image, true, false, false, false, "ro-verify-truncate");
    if (bridge) {
        CHECK(ntfs_bridge_getattr(bridge, "/dir/data.bin", &attrs) == NTFS_BRIDGE_OK, "getattr truncated");
        CHECK(attrs.size == 4096, "truncated size=%" PRIu64, attrs.size);
        memset(readback, 0, pattern_size);
        CHECK(ntfs_bridge_read(bridge, "/dir/data.bin", 0, readback, 4096, &read_bytes) == NTFS_BRIDGE_OK,
              "read truncated");
        CHECK(memcmp(readback, pattern, 4096) == 0, "truncated prefix intact");
        CHECK(ntfs_bridge_close(bridge) == NTFS_BRIDGE_OK, "close verify");
    }

    bridge = open_expect(image, false, false, false, false, "rw-unlink");
    if (bridge) {
        CHECK(ntfs_bridge_unlink(bridge, "/hello.txt") == NTFS_BRIDGE_OK, "unlink hello.txt");
        CHECK(ntfs_bridge_unlink(bridge, "/$MFT") == NTFS_BRIDGE_ERR_PERM, "metadata unlink refused");
        CHECK(ntfs_bridge_create(bridge, "/write-denied", false) != NTFS_BRIDGE_ERR_PERM, "create after unlink");
        CHECK(ntfs_bridge_sync(bridge) == NTFS_BRIDGE_OK, "sync unlink");
        CHECK(ntfs_bridge_close(bridge) == NTFS_BRIDGE_OK, "close unlink");
    }

    bridge = open_expect(image, true, false, false, false, "ro-verify-unlink");
    if (bridge) {
        CHECK(ntfs_bridge_getattr(bridge, "/hello.txt", &attrs) == NTFS_BRIDGE_ERR_NOT_FOUND,
              "hello.txt gone");
        CHECK(ntfs_bridge_write(bridge, "/dir/data.bin", 0, pattern, 16, &written) == NTFS_BRIDGE_ERR_PERM,
              "write on read-only bridge refused");
        CHECK(ntfs_bridge_close(bridge) == NTFS_BRIDGE_OK, "close final");
    }

    free(pattern);
    free(readback);
}

static void test_dirty_volume(const char *image)
{
    printf("== dirty volume (%s)\n", image);
    ntfs_bridge *bridge = open_expect(image, false, false, false, false, "dirty-initial");
    if (!bridge) {
        return;
    }
    CHECK(ntfs_bridge_test_mark_dirty(bridge) == NTFS_BRIDGE_OK, "mark dirty");
    CHECK(ntfs_bridge_close(bridge) == NTFS_BRIDGE_OK, "close dirty");

    bridge = open_expect(image, false, true, true, false, "dirty-rw-refused");
    if (bridge) {
        size_t written = 0;
        CHECK(ntfs_bridge_write(bridge, "/x", 0, "x", 1, &written) == NTFS_BRIDGE_ERR_PERM,
              "write refused on dirty volume");
        CHECK(ntfs_bridge_close(bridge) == NTFS_BRIDGE_OK, "close dirty ro");
    }

    bridge = open_expect(image, true, false, true, false, "dirty-ro-allowed");
    if (bridge) {
        CHECK(ntfs_bridge_close(bridge) == NTFS_BRIDGE_OK, "close dirty explicit ro");
    }
}

static void test_hibernated_volume(const char *image)
{
    printf("== hibernated volume (%s)\n", image);
    ntfs_bridge *bridge = open_expect(image, false, false, false, false, "hiber-initial");
    if (!bridge) {
        return;
    }
    CHECK(ntfs_bridge_create(bridge, "/hiberfil.sys", false) == NTFS_BRIDGE_OK, "create hiberfil.sys");
    uint8_t header[4096];
    memset(header, 0, sizeof(header));
    memcpy(header, "hibr", 4);
    size_t written = 0;
    CHECK(ntfs_bridge_write(bridge, "/hiberfil.sys", 0, header, sizeof(header), &written) == NTFS_BRIDGE_OK,
          "write hiberfil.sys");
    CHECK(ntfs_bridge_sync(bridge) == NTFS_BRIDGE_OK, "sync hiberfil");
    CHECK(ntfs_bridge_close(bridge) == NTFS_BRIDGE_OK, "close hiberfil");

    bridge = open_expect(image, false, true, false, true, "hiber-rw-refused");
    if (bridge) {
        CHECK(ntfs_bridge_close(bridge) == NTFS_BRIDGE_OK, "close hiber ro");
    }

    bridge = open_expect(image, true, false, false, true, "hiber-ro-allowed");
    if (bridge) {
        CHECK(ntfs_bridge_close(bridge) == NTFS_BRIDGE_OK, "close hiber explicit ro");
    }
}

static void test_lookup_rename_statfs(const char *image)
{
    printf("== lookup/rename/statfs (%s)\n", image);

    ntfs_bridge *bridge = open_expect(image, false, false, false, false, "extra-open");
    if (!bridge) {
        return;
    }

    ntfs_bridge_volume_stats fs;
    CHECK(ntfs_bridge_statfs(bridge, &fs) == NTFS_BRIDGE_OK, "statfs");
    CHECK(fs.total_bytes > 0 && fs.free_bytes <= fs.total_bytes && fs.cluster_size > 0,
          "statfs values sane");

    const char *aaa = "AAA";
    const char *bbbb = "BBBB";
    size_t written = 0;
    CHECK(ntfs_bridge_create(bridge, "/a.txt", false) == NTFS_BRIDGE_OK, "create a.txt");
    CHECK(ntfs_bridge_write(bridge, "/a.txt", 0, aaa, 3, &written) == NTFS_BRIDGE_OK && written == 3,
          "write a.txt");
    CHECK(ntfs_bridge_create(bridge, "/b.txt", false) == NTFS_BRIDGE_OK, "create b.txt");
    CHECK(ntfs_bridge_write(bridge, "/b.txt", 0, bbbb, 4, &written) == NTFS_BRIDGE_OK && written == 4,
          "write b.txt");

    uint64_t inode = 0;
    ntfs_bridge_attrs attrs;
    CHECK(ntfs_bridge_lookup(bridge, NTFS_BRIDGE_ROOT_INODE, "a.txt", &inode, &attrs) == NTFS_BRIDGE_OK,
          "lookup a.txt");
    CHECK(inode != 0 && attrs.size == 3 && !attrs.is_directory, "a.txt attrs");
    uint64_t missing = 0;
    CHECK(ntfs_bridge_lookup(bridge, NTFS_BRIDGE_ROOT_INODE, "missing.txt", &missing, &attrs) == NTFS_BRIDGE_ERR_NOT_FOUND,
          "lookup missing returns not found");
    CHECK(ntfs_bridge_lookup(bridge, NTFS_BRIDGE_ROOT_INODE, "bad/name", &missing, &attrs) == NTFS_BRIDGE_ERR_INVAL,
          "lookup invalid component refused");

    uint8_t buffer[8];
    memset(buffer, 0, sizeof(buffer));
    size_t got = 0;
    CHECK(ntfs_bridge_read_inode(bridge, inode, 0, buffer, sizeof(buffer), &got) == NTFS_BRIDGE_OK,
          "read_inode");
    CHECK(got == 3 && memcmp(buffer, aaa, 3) == 0, "read_inode content");

    CHECK(ntfs_bridge_rename(bridge, "/a.txt", "/c.txt") == NTFS_BRIDGE_OK, "rename a.txt to c.txt");
    CHECK(ntfs_bridge_getattr(bridge, "/a.txt", &attrs) == NTFS_BRIDGE_ERR_NOT_FOUND, "a.txt gone");
    CHECK(ntfs_bridge_getattr(bridge, "/c.txt", &attrs) == NTFS_BRIDGE_OK && attrs.size == 3, "c.txt present");

    CHECK(ntfs_bridge_rename(bridge, "/c.txt", "/b.txt") == NTFS_BRIDGE_OK, "rename c.txt over b.txt");
    CHECK(ntfs_bridge_getattr(bridge, "/c.txt", &attrs) == NTFS_BRIDGE_ERR_NOT_FOUND, "c.txt gone");
    memset(buffer, 0, sizeof(buffer));
    CHECK(ntfs_bridge_read(bridge, "/b.txt", 0, buffer, sizeof(buffer), &got) == NTFS_BRIDGE_OK,
          "read overwritten b.txt");
    CHECK(got == 3 && memcmp(buffer, aaa, 3) == 0, "overwritten b.txt contains AAA");

    CHECK(ntfs_bridge_create(bridge, "/dir2", true) == NTFS_BRIDGE_OK, "create dir2");
    CHECK(ntfs_bridge_rename(bridge, "/b.txt", "/dir2/moved.txt") == NTFS_BRIDGE_OK,
          "rename into subdirectory");

    struct list_context root = { .count = 0 };
    CHECK(ntfs_bridge_readdir_inode(bridge, NTFS_BRIDGE_ROOT_INODE, collect_entry, &root) == NTFS_BRIDGE_OK,
          "readdir_inode root");
    CHECK(!list_contains(&root, "b.txt"), "b.txt left the root");
    CHECK(list_contains(&root, "dir2"), "dir2 present in root");

    CHECK(ntfs_bridge_rename(bridge, "/$MFT", "/x") == NTFS_BRIDGE_ERR_PERM, "metadata rename refused");

    CHECK(ntfs_bridge_sync(bridge) == NTFS_BRIDGE_OK, "sync extra");
    CHECK(ntfs_bridge_close(bridge) == NTFS_BRIDGE_OK, "close extra");

    bridge = open_expect(image, true, false, false, false, "extra-ro");
    if (bridge) {
        uint64_t dir2_inode = 0;
        CHECK(ntfs_bridge_lookup(bridge, NTFS_BRIDGE_ROOT_INODE, "dir2", &dir2_inode, &attrs) == NTFS_BRIDGE_OK,
              "lookup dir2");
        CHECK(attrs.is_directory, "dir2 is a directory");
        CHECK(ntfs_bridge_lookup(bridge, dir2_inode, "moved.txt", &missing, &attrs) == NTFS_BRIDGE_OK,
              "lookup moved.txt");
        CHECK(attrs.size == 3, "moved.txt size");
        CHECK(ntfs_bridge_close(bridge) == NTFS_BRIDGE_OK, "close extra ro");
    }
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);

    /* Fixture modes used by scripts/m3-mount-test.sh. */
    if (argc == 3 && strcmp(argv[1], "--make-dirty") == 0) {
        ntfs_bridge_status status = NTFS_BRIDGE_ERR_IO;
        bool downgraded = false, dirty = false, hibernated = false;
        ntfs_bridge *bridge = ntfs_bridge_open(argv[2], false, &status, &downgraded, &dirty, &hibernated);
        if (!bridge) {
            fprintf(stderr, "cannot open %s: %s\n", argv[2], ntfs_bridge_strerror(status));
            return 1;
        }
        ntfs_bridge_status mark = ntfs_bridge_test_mark_dirty(bridge);
        ntfs_bridge_status close_status = ntfs_bridge_close(bridge);
        if (mark != NTFS_BRIDGE_OK || close_status != NTFS_BRIDGE_OK) {
            fprintf(stderr, "failed to mark dirty: %s\n", ntfs_bridge_strerror(mark));
            return 1;
        }
        printf("marked dirty: %s\n", argv[2]);
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "--make-hibernated") == 0) {
        ntfs_bridge_status status = NTFS_BRIDGE_ERR_IO;
        bool downgraded = false, dirty = false, hibernated = false;
        ntfs_bridge *bridge = ntfs_bridge_open(argv[2], false, &status, &downgraded, &dirty, &hibernated);
        if (!bridge) {
            fprintf(stderr, "cannot open %s: %s\n", argv[2], ntfs_bridge_strerror(status));
            return 1;
        }
        uint8_t header[4096];
        memset(header, 0, sizeof(header));
        memcpy(header, "hibr", 4);
        size_t written = 0;
        ntfs_bridge_status created = ntfs_bridge_create(bridge, "/hiberfil.sys", false);
        ntfs_bridge_status wrote = created == NTFS_BRIDGE_OK
            ? ntfs_bridge_write(bridge, "/hiberfil.sys", 0, header, sizeof(header), &written)
            : created;
        ntfs_bridge_status close_status = ntfs_bridge_close(bridge);
        if (created != NTFS_BRIDGE_OK || wrote != NTFS_BRIDGE_OK || close_status != NTFS_BRIDGE_OK) {
            fprintf(stderr, "failed to create hiberfil: %s\n", ntfs_bridge_strerror(wrote));
            return 1;
        }
        printf("made hibernated: %s\n", argv[2]);
        return 0;
    }

    if (argc != 5) {
        fprintf(stderr, "usage: %s <image1> <image2-dirty> <image3-hibernated> <image4-extra>\n", argv[0]);
        fprintf(stderr, "       %s --make-dirty|--make-hibernated <image>\n", argv[0]);
        return 2;
    }
    test_read_write_cycle(argv[1]);
    test_dirty_volume(argv[2]);
    test_hibernated_volume(argv[3]);
    test_lookup_rename_statfs(argv[4]);

    printf("\n%d checks, %d failures\n", checks, failures);
    if (failures) {
        printf("ENGINE TESTS: FAILED\n");
        return 1;
    }
    printf("ENGINE TESTS: PASSED\n");
    return 0;
}
