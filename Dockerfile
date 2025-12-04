ARG VERSION=12

FROM debian:${VERSION}-slim

ARG DEBIAN_FRONTEND=noninteractive

# Install dependencies.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       aardvark-dns ca-certificates dbus docker-compose \
       fuse-overlayfs iproute2 iptables \
       netavark nftables podman procps python3 slirp4netns sudo \
       systemd systemd-sysv uidmap \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /usr/share/doc /usr/share/man /usr/share/locale/* /usr/share/i18n/* \
    && apt-get clean

# Make sure systemd doesn't start agettys on tty[1-6].
RUN rm -f /lib/systemd/system/multi-user.target.wants/getty.target

# Configure 1:1 subuid/subgid for podman and mount ability
RUN echo "root:0:65536" > /etc/subuid \
    && echo "root:0:65536" > /etc/subgid

# Configure podman for nested containers
RUN mkdir -p /etc/containers \
    && echo '[engine]' > /etc/containers/containers.conf \
    && echo 'cgroup_manager = "cgroupfs"' >> /etc/containers/containers.conf \
    && echo '[containers]' >> /etc/containers/containers.conf \
    && echo 'default_sysctls = []' >> /etc/containers/containers.conf \
    # Unprivileged mode runs in user namespace, netavark detects this and tries "systemd-run --user"
    # which fails without user dbus; hiding it forces direct aardvark-dns start, fixing compose DNS.
    && mv /usr/bin/systemd-run /usr/bin/systemd-run.bak

ENV ANSIBLE_USER=ansible \
    DOCKER_HOST=unix:///run/podman/podman.sock \
    SUDO_GROUP=sudo

# Create non-root user with sudo access
RUN set -xe \
    && groupadd -r ${ANSIBLE_USER} \
    && useradd -m -g ${ANSIBLE_USER} ${ANSIBLE_USER} \
    && usermod -aG ${SUDO_GROUP} ${ANSIBLE_USER} \
    && sed -i "/^%${SUDO_GROUP}/s/ALL\$/NOPASSWD:ALL/g" /etc/sudoers

CMD ["/lib/systemd/systemd"]
