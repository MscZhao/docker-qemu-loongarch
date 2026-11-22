# syntax=docker/dockerfile:1
# docker-loongnix — Loongnix Server 23.3 (loongarch64) VM in container
# 多阶段：builder 编 QEMU v10.2.0（gitee 镜像源），runtime 仅装运行时依赖
# 基础镜像 debian:trixie-slim：本地已有 + meson 1.x 满足 QEMU ≥9.2 的构建要求

# ── Stage 1: QEMU builder ─────────────────────────────────────
FROM debian:trixie-slim AS builder
ENV DEBIAN_FRONTEND=noninteractive
RUN sed -i 's|deb.debian.org|mirrors.ustc.edu.cn|g; s|security.debian.org|mirrors.ustc.edu.cn|g' \
      /etc/apt/sources.list.d/debian.sources \
 && apt-get update && apt-get install -y --no-install-recommends \
      build-essential ninja-build meson pkg-config python3 git flex bison \
      libglib2.0-dev libpixman-1-dev libslirp-dev ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# gitlab 直连实测可达且 tag 齐全；gitee 镜像已停在 v9.2.x 勿用；download.qemu.org 本环境被重置
RUN git clone --depth 1 --branch v10.2.0 https://gitlab.com/qemu-project/qemu.git /src/qemu
WORKDIR /src/qemu/build
RUN ../configure --target-list=loongarch64-softmmu --disable-docs \
 && ninja -j"$(nproc)"

# ── Stage 2: runtime ──────────────────────────────────────────
FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN sed -i 's|deb.debian.org|mirrors.ustc.edu.cn|g; s|security.debian.org|mirrors.ustc.edu.cn|g' \
      /etc/apt/sources.list.d/debian.sources \
 && apt-get update && apt-get install -y --no-install-recommends \
      nginx websockify socat cpio curl xorriso ca-certificates procps \
      libglib2.0-0 libpixman-1-0 libslirp0 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/qemu/build/qemu-system-loongarch64 /usr/local/bin/
COPY --from=builder /src/qemu/build/qemu-img /usr/local/bin/
COPY firmware/ /firmware/
COPY assets/web/ /opt/web/
COPY assets/kickstart/ks.cfg /opt/ks.cfg
COPY assets/scripts/firstboot_inject.py /opt/firstboot_inject.py
COPY entrypoint.sh /opt/entrypoint.sh

RUN mkdir -p /storage /run/docker-loongnix
EXPOSE 8006 22
VOLUME /storage
HEALTHCHECK --interval=30s --timeout=10s --start-period=10m --retries=3 \
  CMD socat - UNIX-CONNECT:/run/docker-loongnix/qmp.sock </dev/null 2>/dev/null | grep -q QMP || exit 1
ENTRYPOINT ["/opt/entrypoint.sh"]
