# Systemd Debian Container Images For Ansible and Podman

Systemd Debian Container Images for testing Ansible roles with Molecule and Podman.
Supports nested rootless podman-in-podman without `--privileged`.

Supported Debian versions:

* `13` - Trixie
* `12` - Bookworm

## Available Images

Images are built weekly via GitHub Actions and can be downloaded from the
GitHub Package Registry.

* `ghcr.io/theoborealis/debian-systemd-podman:13`
* `ghcr.io/theoborealis/debian-systemd-podman:12`

## How to Use

```bash
podman run -it --systemd=true \
    --cap-add SYS_ADMIN \
    --device /dev/net/tun \
    --security-opt seccomp=seccomp-hardened.json \
    -v /proc/sys/net:/proc/sys/net:rw \
    ghcr.io/theoborealis/debian-systemd-podman:13
```

The included `seccomp-hardened.json` blocks ptrace, bpf, kernel modules, kexec,
open_by_handle_at, and userfaultfd while allowing nested container operations.

### Host Requirements

Extend subuid/subgid for nested user namespaces (at least 200000):

```
# /etc/subuid and /etc/subgid
youruser:100000:200000
```

Run `podman system migrate` after changes.

### Nested Containers

The `ansible` user can run containers directly without extra flags:

```bash
podman exec --user ansible <container> podman run --rm alpine echo hello
```

Inner containers default to `--pid=host` and VFS storage via
`/etc/containers/containers.conf` and `/etc/containers/storage.conf`.

## Molecule

```yaml
---
driver:
  name: podman
platforms:
  - name: instance
    image: ghcr.io/theoborealis/debian-systemd-podman:13
    systemd: true
    command: /lib/systemd/systemd
    capabilities:
      - SYS_ADMIN
    devices:
      - /dev/net/tun
    volumes:
      - /proc/sys/net:/proc/sys/net:rw
    security_opts:
      - seccomp=seccomp-hardened.json
    pre_build_image: true
provisioner:
  name: ansible
verifier:
  name: ansible
```

## What's Included

- systemd (PID 1)
- podman + docker-compose
- Non-root `ansible` user with sudo access
- `/etc/subuid`, `/etc/subgid` configured for ansible user
- VFS storage driver, cgroupfs manager
- `seccomp-hardened.json` for blocking container escape vectors

Forked from <https://github.com/hifis-net/debian-systemd>
