ARG VERSION=13

FROM debian:${VERSION}-slim

ARG DEBIAN_FRONTEND=noninteractive

# Install dependencies.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       aardvark-dns ca-certificates dbus dbus-user-session docker-compose \
       fuse-overlayfs iproute2 iptables libpam-systemd \
       netavark nftables passt podman procps python3 slirp4netns sudo \
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
    && printf '[engine]\ncgroup_manager = "cgroupfs"\n\n[containers]\ndefault_sysctls = []\npidns = "host"\n' \
       > /etc/containers/containers.conf \
    && printf '[storage]\ndriver = "vfs"\n' \
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

CMD ["/lib/systemd/systemd"]
