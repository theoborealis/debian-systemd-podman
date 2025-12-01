# Systemd Debian Container Images For Ansible and Podman

Systemd Debian Container Images for testing Ansible roles with Molecule and Podman.
Supported Debian versions:

* `13` - Trixie
* `12` - Bookworm

## Available Images

Images are built weekly via GitHub Actions and can be downloaded from the
GitHub Package Registry.

These tags are available. They are updated on changes to the `main` branch
and are automatically rebuilt once a week.

* `ghcr.io/theoborealis/debian-systemd-podman:13`
* `ghcr.io/theoborealis/debian-systemd-podman:12`

## Container Features

| Feature | Status | Notes |
|---------|--------|-------|
| systemd | ✅ | Runs as PID 1 |
| ansible systemd module | ✅ | Full support |
| podman | ✅ | Full support |
| docker-compose | ✅ | Run compose files inside container via podman socket |
| bridge networking | ✅ | Via volume mount `/proc/sys/net` |

## How to Use

* [Install Podman](https://podman.io/getting-started/installation)
* Run the container via Podman (unprivileged):

  ```bash
  podman run -it --systemd=true \
      --cap-add SYS_ADMIN,NET_ADMIN \
      --device /dev/fuse \
      -v /proc/sys/net:/proc/sys/net:rw \
      ghcr.io/theoborealis/debian-systemd-podman:12
  ```

- `--cap-add SYS_ADMIN,NET_ADMIN` - required for nested containers
- `--device /dev/fuse` - required for fuse-overlayfs
- `-v /proc/sys/net:/proc/sys/net:rw` - network sysctl access (isolated in container network namespace)

## Molecule Testing

This image is designed for testing Ansible roles with Molecule.

### Example molecule.yml

```yaml
---
driver:
  name: podman
platforms:
  - name: instance
    image: ghcr.io/theoborealis/debian-systemd-podman:12
    systemd: true
    command: /lib/systemd/systemd
    capabilities:
      - SYS_ADMIN
      - NET_ADMIN
    devices:
      - /dev/fuse
    volumes:
      - /proc/sys/net:/proc/sys/net:rw
    pre_build_image: true
provisioner:
  name: ansible
verifier:
  name: ansible
```

### What's Included

- systemd (PID 1)
- podman + docker-compose (run compose files inside container)
- Non-root `ansible` user with sudo access

For podman-in-podman support:
- `/etc/subuid`, `/etc/subgid` configured for user namespaces
- `cgroup_manager = "cgroupfs"` in `/etc/containers/containers.conf`
- `DOCKER_HOST=unix:///run/podman/podman.sock` for docker-compose compatibility

## Debugging

```bash
# Enter the container
podman exec -it <container_name> bash

# Check systemd
systemctl status

# Check podman
podman run --rm alpine echo hello

# Check docker-compose
docker-compose version
```

Forked from <https://github.com/hifis-net/debian-systemd>
