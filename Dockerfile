# docker-loongnix — Loongnix Server 23.3 (loongarch64) VM in container
# 多阶段：builder 编 QEMU v11.1.0（文章路线验证版本），runtime 仅装运行时依赖
# 基础镜像 debian:trixie-slim：本地已有 + meson 1.x 满足 QEMU ≥9.2 的构建要求
# （勿加 syntax=docker/dockerfile:1 —— 会去 docker.io 拉前端镜像，本环境被墙）

# ── Stage 1: QEMU builder ─────────────────────────────────────
FROM debian:trixie-slim AS builder
ENV DEBIAN_FRONTEND=noninteractive
RUN sed -i 's|deb.debian.org|mirrors.ustc.edu.cn|g; s|security.debian.org|mirrors.ustc.edu.cn|g' \
      /etc/apt/sources.list.d/debian.sources \
 && apt-get update && apt-get install -y --no-install-recommends \
      build-essential ninja-build meson pkg-config python3 python3-venv python3-pip \
      git flex bison libglib2.0-dev libpixman-1-dev libslirp-dev ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# QEMU configure 会自建 python venv；pip 走清华源防 pypi 被墙
ENV PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
# gitlab 直连实测可达且 tag 齐全；gitee 镜像已停在 v9.2.x 勿用；download.qemu.org 本环境被重置
RUN git clone --depth 1 --branch v11.1.0 https://gitlab.com/qemu-project/qemu.git /src/qemu
WORKDIR /src/qemu/build
RUN ../configure --target-list=loongarch64-softmmu --disable-docs \
 && ninja -j"$(nproc)"

# ── Stage 2: runtime ──────────────────────────────────────────
FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN sed -i 's|deb.debian.org|mirrors.ustc.edu.cn|g; s|security.debian.org|mirrors.ustc.edu.cn|g' \
      /etc/apt/sources.list.d/debian.sources \
 && apt-get update && apt-get install -y --no-install-recommends \
      nginx websockify socat cpio curl xorriso mtools ca-certificates procps \
      libglib2.0-0 libpixman-1-0 libslirp0 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/qemu/build/qemu-system-loongarch64 /usr/local/bin/
COPY --from=builder /src/qemu/build/qemu-img /usr/local/bin/
# pc-bios：virtio-net-pci 等设备需要 option rom（efi-virtio.rom 等）
COPY --from=builder /src/qemu/pc-bios/ /usr/local/share/qemu/
COPY firmware/ /firmware/
COPY assets/web/ /opt/web/
COPY assets/kickstart/ks.cfg /opt/ks.cfg
COPY assets/scripts/firstboot_inject.py /opt/firstboot_inject.py
COPY assets/scripts/serial_mux.py /opt/serial_mux.py
COPY assets/scripts/remaster_iso.sh /opt/remaster_iso.sh
COPY entrypoint.sh /opt/entrypoint.sh

RUN chmod +x /opt/entrypoint.sh && mkdir -p /storage /run/docker-loongnix
EXPOSE 8006 22
VOLUME /storage
HEALTHCHECK --interval=30s --timeout=10s --start-period=10m --retries=3 \
  CMD socat - UNIX-CONNECT:/run/docker-loongnix/qmp.sock </dev/null 2>/dev/null | grep -q QMP || exit 1
ENTRYPOINT ["/opt/entrypoint.sh"]
