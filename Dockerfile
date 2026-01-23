ARG VERSION=13

FROM debian:${VERSION}-slim

ARG DEBIAN_FRONTEND=noninteractive

# Install dependencies.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       aardvark-dns ca-certificates dbus dbus-user-session docker-compose \
       fuse-overlayfs iproute2 iptables libpam-systemd \
       netavark nftables passt podman procps python3 slirp4netns strace sudo \
       systemd systemd-sysv uidmap \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /usr/share/doc /usr/share/man /usr/share/locale/* /usr/share/i18n/* \
    && apt-get clean

# Make sure systemd doesn't start agettys on tty[1-6].
RUN rm -f /lib/systemd/system/multi-user.target.wants/getty.target

# Configure subuid/subgid for podman nested containers
RUN echo "ansible:1001:65536" > /etc/subuid \
    && echo "ansible:1001:65536" > /etc/subgid

# Configure podman for nested containers
RUN mkdir -p /etc/containers \
    && printf '[engine]\ncgroup_manager = "cgroupfs"\nruntime = "crun-gvisor"\n\n[engine.runtimes]\ncrun-gvisor = ["/usr/local/bin/crun-gvisor"]\n\n[containers]\ndefault_sysctls = []\npidns = "host"\nnetns = "host"\ncgroupns = "host"\n' \
       > /etc/containers/containers.conf \
    && printf '[storage]\ndriver = "vfs"\nrunroot = "/run/containers/storage"\ngraphroot = "/var/lib/containers/storage"\n' \
       > /etc/containers/storage.conf

ENV ANSIBLE_USER=ansible \
    DOCKER_HOST=unix:///run/podman/podman.sock \
    SUDO_GROUP=sudo \
    XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus

# Create non-root user with sudo access
RUN set -xe \
    && groupadd -r ${ANSIBLE_USER} \
    && useradd -m -g ${ANSIBLE_USER} ${ANSIBLE_USER} \
    && usermod -aG ${SUDO_GROUP} ${ANSIBLE_USER} \
    && sed -i "/^%${SUDO_GROUP}/s/ALL\$/NOPASSWD:ALL/g" /etc/sudoers \
    && mkdir -p /var/lib/systemd/linger \
    && touch /var/lib/systemd/linger/${ANSIBLE_USER}

# Disable systemd service/mount sandboxing (gVisor doesn't support
# open_tree/fsopen/MS_MOVE/CLONE_NEWNS for services).
# This is safe because gVisor's Sentry provides the security boundary.
RUN mkdir -p /etc/systemd/system/service.d /etc/systemd/system/mount.d \
    && printf '[Service]\nPrivateMounts=no\nProtectSystem=no\nProtectHome=no\nProtectHostname=no\nPrivateTmp=no\nNoNewPrivileges=no\nProtectKernelTunables=no\nProtectKernelModules=no\nProtectKernelLogs=no\nProtectControlGroups=no\nProtectClock=no\nRestrictNamespaces=no\nMountAPIVFS=no\nMemoryDenyWriteExecute=no\nRestrictRealtime=no\nRestrictSUIDSGID=no\nLockPersonality=no\nPrivateDevices=no\nPrivateNetwork=no\nPrivateUsers=no\nRuntimeDirectoryPreserve=no\nSystemCallFilter=\nImportCredential=\nLoadCredential=\nSetCredential=\nLoadCredentialEncrypted=\nSetCredentialEncrypted=\nSmackProcessLabel=\n' \
       > /etc/systemd/system/service.d/00-gvisor.conf \
    && printf '[Mount]\nPrivateMounts=no\nProtectSystem=no\nProtectHome=no\nPrivateTmp=no\nNoNewPrivileges=no\nProtectKernelTunables=no\nProtectKernelModules=no\nProtectKernelLogs=no\nProtectControlGroups=no\nProtectClock=no\nRestrictNamespaces=no\nMountAPIVFS=no\nPrivateDevices=no\nPrivateNetwork=no\nPrivateUsers=no\nSystemCallFilter=\nImportCredential=\nLoadCredential=\nSetCredential=\nLoadCredentialEncrypted=\nSetCredentialEncrypted=\n' \
       > /etc/systemd/system/mount.d/00-gvisor.conf \
    && rm -rf /etc/credstore /etc/credstore.encrypted \
    && systemctl mask systemd-remount-fs.service tmp.mount \
       systemd-machine-id-commit.service systemd-sysctl.service \
       run-lock.mount user@.service

# Build gVisor compatibility shim (timerfd + tmpfs mount + cgroup overlay)
# Uses /etc/ld.so.preload so ALL processes (including systemd-executor) load it
COPY gvisor_shim.c /tmp/gvisor_shim.c
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc libc6-dev \
    && gcc -shared -fPIC -o /usr/local/lib/gvisor_shim.so /tmp/gvisor_shim.c -ldl \
    && echo /usr/local/lib/gvisor_shim.so > /etc/ld.so.preload \
    && apt-get purge -y gcc libc6-dev \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* /tmp/gvisor_shim.c

COPY crun-gvisor.sh /usr/local/bin/crun-gvisor
RUN chmod +x /usr/local/bin/crun-gvisor

# Install netavark wrapper for gVisor (fakes bridge network setup/teardown
# since gVisor doesn't support netlink ops for bridge/veth creation)
COPY netavark-gvisor.py /usr/lib/podman/netavark-gvisor.py
RUN mv /usr/lib/podman/netavark /usr/lib/podman/netavark.real \
    && chmod +x /usr/lib/podman/netavark-gvisor.py \
    && ln -s /usr/lib/podman/netavark-gvisor.py /usr/lib/podman/netavark

# Enable podman socket for docker-compose compatibility.
# Allow sudo group (ansible user) to access the socket.
# The /run/podman directory is created 0700 by netavark-dhcp-proxy; fix via tmpfiles.
RUN systemctl enable podman.socket \
    && mkdir -p /etc/systemd/system/podman.socket.d \
    && printf '[Socket]\nSocketMode=0660\nSocketGroup=sudo\n' \
       > /etc/systemd/system/podman.socket.d/10-permissions.conf \
    && printf 'd /run/podman 0755 root root -\n' \
       > /etc/tmpfiles.d/podman-socket.conf

COPY init-wrapper.sh /usr/local/bin/init-wrapper.sh

CMD ["/usr/local/bin/init-wrapper.sh"]
