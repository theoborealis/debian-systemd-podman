/*
 * timerfd_shim.c - Strip TFD_TIMER_CANCEL_ON_SET from timerfd_settime flags.
 *
 * gVisor's Sentry only accepts TFD_TIMER_ABSTIME; the CANCEL_ON_SET flag
 * (used by systemd to detect clock jumps) is not implemented and returns
 * EINVAL. Under gVisor, clock discontinuities never occur (virtual clock),
 * so stripping this flag is semantically safe.
 *
 * Build: gcc -shared -fPIC -o timerfd_shim.so timerfd_shim.c -ldl
 * Usage: LD_PRELOAD=/usr/local/lib/timerfd_shim.so /lib/systemd/systemd
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <sys/timerfd.h>
#include <stddef.h>

#ifndef TFD_TIMER_CANCEL_ON_SET
#define TFD_TIMER_CANCEL_ON_SET (1 << 1)
#endif

int timerfd_settime(int fd, int flags,
                    const struct itimerspec *new_value,
                    struct itimerspec *old_value) {
    static int (*real_fn)(int, int, const struct itimerspec *, struct itimerspec *) = NULL;
    if (!real_fn)
        real_fn = dlsym(RTLD_NEXT, "timerfd_settime");
    return real_fn(fd, flags & ~TFD_TIMER_CANCEL_ON_SET, new_value, old_value);
}
