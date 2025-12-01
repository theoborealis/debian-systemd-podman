ARG VERSION=12

FROM debian:${VERSION}-slim

ARG DEBIAN_FRONTEND=noninteractive

# Install dependencies.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential ca-certificates docker-compose \
       fuse-overlayfs iproute2 libffi-dev libssl-dev \
       podman procps python3-dev slirp4netns sudo \
       systemd systemd-sysv uidmap wget \
    && rm -rf /var/lib/apt/lists/* \
    && rm -Rf /usr/share/doc && rm -Rf /usr/share/man \
    && apt-get clean

# Make sure systemd doesn't start agettys on tty[1-6].
RUN rm -f /lib/systemd/system/multi-user.target.wants/getty.target

# Configure subuid/subgid for rootless podman
RUN echo "root:100000:65536" >> /etc/subuid \
    && echo "root:100000:65536" >> /etc/subgid

# Configure podman for nested containers
RUN mkdir -p /etc/containers \
    && echo '[engine]' > /etc/containers/containers.conf \
    && echo 'cgroup_manager = "cgroupfs"' >> /etc/containers/containers.conf \
    && echo '[containers]' >> /etc/containers/containers.conf \
    && echo 'default_sysctls = []' >> /etc/containers/containers.conf

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
