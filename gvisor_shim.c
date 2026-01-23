/*
 * gvisor_shim.c - LD_PRELOAD shim for systemd under gVisor.
 *
 * Fixes gVisor compatibility gaps:
 * 1. timerfd_settime: strips TFD_TIMER_CANCEL_ON_SET flag (gVisor rejects it)
 * 2. mount(tmpfs): strips nr_inodes= and replaces size=XX% with fixed size
 *    (gVisor's tmpfs doesn't support nr_inodes or percentage-based sizes)
 * 3. mount(cgroup, name=systemd): overlays tmpfs on the systemd cgroup
 *    hierarchy so cgroup.procs writes succeed (gVisor rejects them with
 *    EINVAL for tasks not tracked in dynamically-mounted hierarchies).
 *    Also intercepts mkdir() to auto-create cgroup.procs in new subdirs.
 * 4. prctl: fakes PR_GET_SECUREBITS, PR_SET_SECUREBITS, PR_CAP_AMBIENT
 *    (gVisor returns EINVAL for these, causing EXIT_CAPABILITIES in executor)
 *
 * Under gVisor's Sentry these modifications are semantically safe:
 * - Clock discontinuities never occur (virtual clock)
 * - nr_inodes limiting is unnecessary (virtual tmpfs)
 * - Percentage sizes can be replaced with fixed sizes
 * - Cgroup migration is virtual (--ignore-cgroups mode)
 * - Securebits/ambient caps are no-ops (Sentry provides the security boundary)
 *
 * Build: gcc -shared -fPIC -o gvisor_shim.so gvisor_shim.c -ldl
 * Usage: LD_PRELOAD=/usr/local/lib/gvisor_shim.so /lib/systemd/systemd
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <sys/timerfd.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <linux/prctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stddef.h>
#include <stdio.h>
#include <stdarg.h>
#include <syscall.h>

#ifndef TFD_TIMER_CANCEL_ON_SET
#define TFD_TIMER_CANCEL_ON_SET (1 << 1)
#endif

/* --- timerfd_settime shim --- */
int timerfd_settime(int fd, int flags,
                    const struct itimerspec *new_value,
                    struct itimerspec *old_value) {
    static int (*real_fn)(int, int, const struct itimerspec *, struct itimerspec *) = NULL;
    if (!real_fn)
        real_fn = dlsym(RTLD_NEXT, "timerfd_settime");
    return real_fn(fd, flags & ~TFD_TIMER_CANCEL_ON_SET, new_value, old_value);
}

/* Path where we overlay tmpfs on the systemd cgroup hierarchy */
static const char *cgroup_systemd_path = "/sys/fs/cgroup/systemd";

/* Helper: create cgroup interface files in a directory on our tmpfs overlay */
static void create_cgroup_files(const char *dirpath) {
    char path[512];
    int fd;
    snprintf(path, sizeof(path), "%s/cgroup.procs", dirpath);
    fd = open(path, O_CREAT | O_WRONLY, 0644);
    if (fd >= 0) close(fd);
    snprintf(path, sizeof(path), "%s/tasks", dirpath);
    fd = open(path, O_CREAT | O_WRONLY, 0644);
    if (fd >= 0) close(fd);
}

/* --- mount shim: fix tmpfs options + overlay systemd cgroup --- */
int mount(const char *source, const char *target,
          const char *filesystemtype, unsigned long mountflags,
          const void *data) {
    static int (*real_mount)(const char *, const char *, const char *,
                             unsigned long, const void *) = NULL;
    if (!real_mount)
        real_mount = dlsym(RTLD_NEXT, "mount");

    /* Patch tmpfs mounts: strip nr_inodes, fix percentage sizes */
    if (filesystemtype && strcmp(filesystemtype, "tmpfs") == 0 &&
        data && (strstr((const char *)data, "nr_inodes") ||
                 strchr(strstr((const char *)data, "size=") ? strstr((const char *)data, "size=") : "", '%'))) {
        char buf[512];
        char *saveptr;
        char *token;
        char tmp[512];
        int pos = 0;

        strncpy(tmp, (const char *)data, sizeof(tmp) - 1);
        tmp[sizeof(tmp) - 1] = '\0';

        buf[0] = '\0';
        token = strtok_r(tmp, ",", &saveptr);
        while (token) {
            if (strncmp(token, "nr_inodes=", 10) == 0) {
                /* Skip nr_inodes option entirely */
            } else if (strncmp(token, "size=", 5) == 0 && strchr(token, '%')) {
                if (pos > 0) buf[pos++] = ',';
                pos += snprintf(buf + pos, sizeof(buf) - pos, "size=512M");
            } else {
                if (pos > 0) buf[pos++] = ',';
                pos += snprintf(buf + pos, sizeof(buf) - pos, "%s", token);
            }
            token = strtok_r(NULL, ",", &saveptr);
        }
        buf[pos] = '\0';
        return real_mount(source, target, filesystemtype, mountflags, buf);
    }

    /* Overlay tmpfs on cgroup name=systemd mounts.
     * Let the cgroup mount succeed (appears in mountinfo), then mount
     * tmpfs on top so writes to cgroup.procs go to regular files. */
    if (filesystemtype && strcmp(filesystemtype, "cgroup") == 0 &&
        data && strstr((const char *)data, "name=systemd") &&
        target) {
        int ret = real_mount(source, target, filesystemtype, mountflags, data);
        if (ret != 0) return ret;
        /* Overlay with tmpfs - writes will go to regular files */
        ret = real_mount("tmpfs", target, "tmpfs", 0, "mode=755,size=4M");
        if (ret == 0) {
            create_cgroup_files(target);
        }
        return ret;
    }

    return real_mount(source, target, filesystemtype, mountflags, data);
}

/* --- mkdir shim: auto-create cgroup.procs in new cgroup directories --- */
int mkdir(const char *pathname, mode_t mode) {
    static int (*real_mkdir)(const char *, mode_t) = NULL;
    if (!real_mkdir)
        real_mkdir = dlsym(RTLD_NEXT, "mkdir");

    int ret = real_mkdir(pathname, mode);
    if (ret == 0 && pathname &&
        strncmp(pathname, cgroup_systemd_path, strlen(cgroup_systemd_path)) == 0) {
        create_cgroup_files(pathname);
    }
    return ret;
}

/* --- prctl shim: fake securebits and ambient capabilities --- */
/* gVisor doesn't support PR_GET_SECUREBITS, PR_SET_SECUREBITS, or
 * PR_CAP_AMBIENT operations, returning EINVAL. The systemd executor
 * calls these during capability setup and treats failure as fatal
 * (EXIT_CAPABILITIES = 213). Since gVisor's Sentry provides the
 * actual security boundary, we can safely fake these operations. */
#ifndef PR_CAP_AMBIENT
#define PR_CAP_AMBIENT          47
#endif
#ifndef PR_CAP_AMBIENT_IS_SET
#define PR_CAP_AMBIENT_IS_SET   1
#define PR_CAP_AMBIENT_RAISE    2
#define PR_CAP_AMBIENT_LOWER    3
#define PR_CAP_AMBIENT_CLEAR_ALL 4
#endif

int prctl(int option, ...) {
    va_list ap;
    unsigned long arg2, arg3, arg4, arg5;

    va_start(ap, option);
    arg2 = va_arg(ap, unsigned long);
    arg3 = va_arg(ap, unsigned long);
    arg4 = va_arg(ap, unsigned long);
    arg5 = va_arg(ap, unsigned long);
    va_end(ap);

    switch (option) {
    case PR_GET_SECUREBITS:
        /* Return 0: no securebits set (default state) */
        return 0;
    case PR_SET_SECUREBITS:
        /* Pretend success - Sentry is the security boundary */
        return 0;
    case PR_CAP_AMBIENT:
        switch ((int)arg2) {
        case PR_CAP_AMBIENT_IS_SET:
            /* Report capability not in ambient set */
            return 0;
        case PR_CAP_AMBIENT_RAISE:
        case PR_CAP_AMBIENT_LOWER:
        case PR_CAP_AMBIENT_CLEAR_ALL:
            /* Pretend success */
            return 0;
        }
        break;
    }

    /* All other prctl operations: pass through to kernel */
    return (int)syscall(SYS_prctl, option, arg2, arg3, arg4, arg5);
}

/* --- mknodat shim: fix device creation under mounted tmpfs --- */
/* gVisor's mount semantics differ from Linux when using fds opened before
 * a mount. crun opens the rootfs /dev dir (fd), mounts tmpfs on it via
 * /proc/self/fd/N, then calls mknodat(fd, "null", ...). The node is created
 * in the underlying dir (below the mount) but invisible through the mount.
 * Fix: after mknodat succeeds for a char device, re-open the dir by path
 * (going through the mount) and create the node there too. */
int mknodat(int dirfd, const char *pathname, mode_t mode, dev_t dev) {
    static int (*real_mknodat)(int, const char *, mode_t, dev_t) = NULL;
    if (!real_mknodat)
        real_mknodat = dlsym(RTLD_NEXT, "mknodat");

    int ret = real_mknodat(dirfd, pathname, mode, dev);
    if (ret == 0 && S_ISCHR(mode)) {
        /* Re-open the directory by resolving the fd path (goes through mount) */
        char fd_link[64];
        char resolved[512];
        snprintf(fd_link, sizeof(fd_link), "/proc/self/fd/%d", dirfd);
        ssize_t len = readlink(fd_link, resolved, sizeof(resolved) - 1);
        if (len > 0) {
            resolved[len] = '\0';
            int new_dirfd = open(resolved, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
            if (new_dirfd >= 0) {
                /* Create node on the mounted filesystem too (ignore errors) */
                real_mknodat(new_dirfd, pathname, mode, dev);
                close(new_dirfd);
            }
        }
    }
    return ret;
}

/* --- bind shim: fix EISDIR on abstract Unix sockets --- */
/* gVisor incorrectly returns EISDIR when binding abstract Unix sockets
 * whose names contain '/' characters (e.g. sd-bus client addresses like
 * @"<hash>/bus/systemctl/"). Abstract sockets don't exist on the filesystem,
 * so EISDIR is never valid. The bind is optional for client sockets -
 * sd-bus uses it only for identification, not for operation. */
int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    static int (*real_bind)(int, const struct sockaddr *, socklen_t) = NULL;
    if (!real_bind)
        real_bind = dlsym(RTLD_NEXT, "bind");

    int ret = real_bind(sockfd, addr, addrlen);
    if (ret == -1 && errno == EISDIR &&
        addr && addr->sa_family == AF_UNIX && addrlen > sizeof(sa_family_t)) {
        const struct sockaddr_un *un = (const struct sockaddr_un *)addr;
        /* Abstract socket: sun_path[0] == '\0' */
        if (un->sun_path[0] == '\0') {
            /* Pretend success - the socket won't have a local name but
             * connect() will still work for the D-Bus connection */
            errno = 0;
            return 0;
        }
    }
    return ret;
}
