#!/bin/sh
# crun wrapper for gVisor: patches OCI config to work around device creation
# and networking issues caused by gVisor's limited syscall support.
#
# Fixes:
# 1. Device nodes: gVisor's mount/fd semantics break crun's mknodat() calls.
#    Fix: add bind mounts for /dev/null, /dev/zero etc. after /dev tmpfs.
# 2. Network namespace: gVisor doesn't support netlink ops for bridge/veth.
#    Fix: remove network namespace from OCI config (force host networking).

REAL_CRUN=/usr/bin/crun

# Only patch for 'create' command
case "$*" in
    *create*)
        # Find --bundle argument
        BUNDLE=""
        PREV=""
        for arg in "$@"; do
            case "$PREV" in
                --bundle|-b) BUNDLE="$arg" ;;
            esac
            PREV="$arg"
        done

        if [ -n "$BUNDLE" ] && [ -f "$BUNDLE/config.json" ]; then
            python3 -c "
import json, os, sys

bundle = sys.argv[1]
with open(bundle + '/config.json', 'r') as f:
    config = json.load(f)

default_devices = ['/dev/null', '/dev/zero', '/dev/full', '/dev/random', '/dev/urandom', '/dev/tty']
extra_devices = config.get('linux', {}).pop('devices', [])
for dev in extra_devices:
    path = dev.get('path', '')
    if path and path not in default_devices:
        default_devices.append(path)

# Fix device mounts: add bind mounts for default devices after /dev tmpfs
mounts = config.get('mounts', [])
new_mounts = []
for m in mounts:
    new_mounts.append(m)
    if m.get('destination') == '/dev' and m.get('type') == 'tmpfs':
        for dev_path in default_devices:
            new_mounts.append({'destination': dev_path, 'source': dev_path, 'type': 'bind', 'options': ['bind', 'rw']})
config['mounts'] = new_mounts

# Remove network namespace to force host networking
# (gVisor does not support netlink for bridge/veth creation)
namespaces = config.get('linux', {}).get('namespaces', [])
config['linux']['namespaces'] = [ns for ns in namespaces if ns.get('type') != 'network']

# Ensure rootfs has device touch targets for bind mounts
rootfs = config.get('root', {}).get('path', '')
if rootfs:
    dev_dir = os.path.join(rootfs, 'dev')
    os.makedirs(dev_dir, exist_ok=True)
    for dev_path in default_devices:
        target = os.path.join(rootfs, dev_path.lstrip('/'))
        target_dir = os.path.dirname(target)
        os.makedirs(target_dir, exist_ok=True)
        if not os.path.exists(target):
            open(target, 'w').close()

with open(bundle + '/config.json', 'w') as f:
    json.dump(config, f)
" "$BUNDLE" 2>/dev/null
        fi
        ;;
esac

exec "$REAL_CRUN" "$@"
