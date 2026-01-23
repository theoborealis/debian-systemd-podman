#!/bin/sh
# Workaround gVisor compatibility gaps for systemd boot:
# 1. gVisor's tmpfs rejects nr_inodes option (systemd 257 passes it)
# 2. gVisor mounts /sys/fs/cgroup read-only (systemd needs writable root)
# 3. gVisor rejects TFD_TIMER_CANCEL_ON_SET flag (used by sd-event)

# Pre-mount /run without nr_inodes
if ! mountpoint -q /run 2>/dev/null; then
    mount -t tmpfs -o mode=755,size=512M tmpfs /run
    mkdir -p /run/lock
fi

# Pre-create podman socket directory with group-accessible permissions.
# systemd creates it 0700 by default; ansible user needs 0755 to reach the socket.
mkdir -p /run/podman
chmod 755 /run/podman

# Make gVisor's cgroup hierarchy writable and pre-mount the systemd controller.
# gVisor mounts /sys/fs/cgroup as read-only tmpfs but the individual
# controller mounts (cpu, memory, pids, etc.) are already read-write.
# Pre-mounting name=systemd ensures PID 1 is in the hierarchy from the start,
# preventing "Cannot migrate to cgroup" errors when systemd-executor runs.
if ! test -w /sys/fs/cgroup 2>/dev/null; then
    mount -o remount,rw /sys/fs/cgroup
fi
if ! mountpoint -q /sys/fs/cgroup/systemd 2>/dev/null; then
    mkdir -p /sys/fs/cgroup/systemd
    mount -t cgroup -o none,name=systemd cgroup /sys/fs/cgroup/systemd
fi

# gVisor compatibility shim is loaded via /etc/ld.so.preload (system-wide):
# - Strips TFD_TIMER_CANCEL_ON_SET from timerfd_settime (virtual clock)
# - Strips nr_inodes= and size=XX% from tmpfs mounts (unsupported options)
# - Suppresses EINVAL from cgroup.procs writes (virtual cgroup hierarchy)

exec /lib/systemd/systemd "$@"
