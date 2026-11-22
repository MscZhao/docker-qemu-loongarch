#!/usr/bin/env bash
# docker-loongnix — Loongnix-Server-23.3 (loongarch64) VM 容器入口
# 状态机（dockur/windows 风格）：
#   /storage/data.qcow2 存在 → 直接开机
#   BOOT=install（默认）      → DVD ISO + kickstart 无人值守安装后开机
#   BOOT=preinstalled         → 官方预装 qcow2 快路径
set -Eeuo pipefail

# ── 常量 ──────────────────────────────────────────────────────
QEMU=/usr/local/bin/qemu-system-loongarch64
QEMU_IMG=/usr/local/bin/qemu-img
FW_DIR=/firmware
WEB_DIR=/opt/web
STORAGE=/storage
RUN=/run/docker-loongnix

ISO_NAME="Loongnix-Server-23.3-loongarch64-dvd.iso"
ISO_URL="https://pkg.loongnix.cn/loongnix-server/23/isos/${ISO_NAME}"
ISO_MD5="7e2bf56015dd63b194966b1428e08701"
QCOW_NAME="Loongnix-Server-23.3.loongarch64.qcow2"
QCOW_URL="https://pkg.loongnix.cn/loongnix-server/23/isos/${QCOW_NAME}"
QCOW_MD5="4f958d74aad1f1f44741a141b31761fd"

# ── 环境变量（对齐 dockur/windows）────────────────────────────
RAM_SIZE="${RAM_SIZE:-4G}"
CPU_CORES="${CPU_CORES:-2}"
DISK_SIZE="${DISK_SIZE:-64G}"
BOOT="${BOOT:-install}"
ROOT_PASS="${ROOT_PASS:-lab}"
CPU_MODEL="${CPU_MODEL:-la464}"          # la464 保守 / la664 可选
ARGUMENTS="${ARGUMENTS:-}"

log() { printf '[docker-loongnix] %s %s\n' "$(date '+%F %T')" "$*"; }
err() { log "ERROR: $*" >&2; }

mkdir -p "$RUN" "$STORAGE"/{iso,install}

# ── QMP 控制（优雅关机/健康检查）──────────────────────────────
qmp() { # qmp <execute>
  printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"}\n' "$1" \
    | timeout 5 socat - "UNIX-CONNECT:$RUN/qmp.sock" 2>/dev/null | tail -n1 || true
}

qemu_pid=""
shutdown_vm() {
  [ -n "$qemu_pid" ] || return 0
  log "SIGTERM→QMP system_powerdown (pid $qemu_pid)"
  qmp system_powerdown
  for _ in $(seq 1 60); do
    kill -0 "$qemu_pid" 2>/dev/null || { log "guest 已优雅关机"; return 0; }
    sleep 1
  done
  err "30s 未退出，强杀"
  kill -9 "$qemu_pid" 2>/dev/null || true
}
trap shutdown_vm SIGTERM SIGINT EXIT

# ── Web 栈：nginx(8006) + websockify×2（VNC / 串口）────────────
start_web() {
  # VNC:    qemu :5900 ← websockify :5700 ← nginx /novnc/websockify
  # 串口:   qemu :5702 ← websockify :5701 ← nginx /serial/ws
  websockify -D 127.0.0.1:5700 127.0.0.1:5900 >/dev/null 2>&1
  websockify -D 127.0.0.1:5701 127.0.0.1:5702 >/dev/null 2>&1
  nginx -c "$WEB_DIR/nginx.conf" 2>/dev/null || nginx -s reload -c "$WEB_DIR/nginx.conf"
  log "web 就绪: http://0.0.0.0:8006 (noVNC + serial)"
}

# ── 下载 + md5 校验（断点续传）────────────────────────────────
fetch() { # fetch <url> <dest> <md5>
  local url=$1 dest=$2 want=$3 have
  [ -f "$dest" ] || curl -fL --retry 5 --retry-delay 3 -C - -o "$dest" "$url"
  have=$(md5sum "$dest" | awk '{print $1}')
  if [ "$have" != "$want" ]; then
    err "md5 不符: $dest ($have != $want)，删除重下"
    rm -f "$dest"
    curl -fL --retry 5 --retry-delay 3 -o "$dest" "$url"
    have=$(md5sum "$dest" | awk '{print $1}')
    [ "$have" = "$want" ] || { err "重下后 md5 仍不符"; return 1; }
  fi
}

# ── kickstart 渲染 + cpio 追加进 initrd（inst.ks=file:/ks.cfg）──
bake_initrd() { # bake_initrd <initrd> <out>
  local tmp; tmp=$(mktemp -d)
  sed "s|@ROOT_PASS@|${ROOT_PASS//&/\\&}|g" /opt/ks.cfg > "$tmp/ks.cfg"
  (cd "$tmp" && echo ks.cfg | cpio -o -H newc --quiet | gzip -9) > "$2"
  cat "$1" >> "$2"
  rm -rf "$tmp"
}

# ── 公共 QEMU 参数 ────────────────────────────────────────────
# 安装期与常态共用：串口 chardev(:5702) / VNC(:5900) / QMP / hostfwd 22
qemu_common_args() {
  cat <<EOF
-machine virt
-cpu ${CPU_MODEL}
-smp ${CPU_CORES}
-m ${RAM_SIZE}
-accel tcg,thread=multi
-device virtio-gpu-pci
-vnc 127.0.0.1:0
-chardev socket,id=ser0,host=127.0.0.1,port=5702,server=on,wait=off
-serial chardev:ser0
-qmp unix:$RUN/qmp.sock,server,nowait
-netdev user,id=n0,hostfwd=tcp::22-:22
-device virtio-net-pci,netdev=n0
EOF
}

# ── 阶段1：kickstart 安装（-kernel 直启，装完 guest reboot→qemu 退出）──
run_install() {
  log "install: 校验/下载 DVD ISO (~3G)…"
  fetch "$ISO_URL" "$STORAGE/iso/$ISO_NAME" "$ISO_MD5"

  log "install: 抽取 vmlinuz/initrd…"
  rm -rf "$STORAGE/install"; mkdir -p "$STORAGE/install"
  xorriso -osirrox on -indev "$STORAGE/iso/$ISO_NAME" \
    -extract /images/pxeboot "$STORAGE/install" >/dev/null 2>&1
  local kernel=$STORAGE/install/vmlinuz initrd=$STORAGE/install/initrd.img
  [ -f "$kernel" ] && [ -f "$initrd" ] || { err "ISO 中未找到 images/pxeboot/{vmlinuz,initrd.img}"; return 1; }

  log "install: 注入 kickstart (root 密码已按 ROOT_PASS 设置)"
  bake_initrd "$initrd" "$STORAGE/install/initrd-ks.img"

  log "install: 创建 ${DISK_SIZE} 数据盘"
  rm -f "$STORAGE/data.qcow2"
  "$QEMU_IMG" create -f qcow2 "$STORAGE/data.qcow2" "$DISK_SIZE" >/dev/null

  log "install: 启动 anaconda（串口文本模式，TCG 下预计 30-90 分钟）"
  # shellcheck disable=SC2086
  "$QEMU" $(qemu_common_args) \
    -drive file="$STORAGE/data.qcow2",if=virtio,format=qcow2 \
    -device virtio-scsi-pci,id=scsi0 \
    -drive file="$STORAGE/iso/$ISO_NAME",if=none,id=cd0,media=cdrom,format=raw,readonly=on \
    -device scsi-cd,drive=cd0 \
    -kernel "$kernel" -initrd "$STORAGE/install/initrd-ks.img" \
    -append "inst.ks=file:/ks.cfg inst.text inst.geoloc=0 console=ttyS0,115200" \
    -no-reboot $ARGUMENTS &
  qemu_pid=$!
  wait "$qemu_pid" || true
  qemu_pid=""
  log "install: 安装阶段结束（guest reboot 退出）"
}

# ── 阶段1'：官方预装 qcow2 ────────────────────────────────────
# 实测：官方 qcow2 root 为空口令（串口免密），sshd 拒空密 → 首启必须注入 ROOT_PASS
run_preinstalled() {
  log "preinstalled: 校验/下载官方 qcow2 (~1.2G)…"
  fetch "$QCOW_URL" "$STORAGE/iso/$QCOW_NAME" "$QCOW_MD5"
  log "preinstalled: 转换为数据盘"
  rm -f "$STORAGE/data.qcow2"
  "$QEMU_IMG" convert -O qcow2 "$STORAGE/iso/$QCOW_NAME" "$STORAGE/data.qcow2"
  # 扩容虚拟盘（分区由首启注入脚本尽力 growpart）
  local cur; cur=$("$QEMU_IMG" info -f qcow2 --output=json "$STORAGE/data.qcow2" | grep -o '"virtual-size": [0-9]*' | grep -o '[0-9]*')
  if "$QEMU_IMG" resize "$STORAGE/data.qcow2" "$DISK_SIZE" >/dev/null 2>&1; then
    log "preinstalled: 虚拟盘 ${cur}B → ${DISK_SIZE}"
  else
    log "preinstalled: 保持原始大小（DISK_SIZE 小于当前盘时不动）"
  fi
  INJECT=1
}

# ── 阶段2：UEFI 磁盘开机 ──────────────────────────────────────
run_boot() {
  [ -f "$STORAGE/vars.fd" ] || cp "$FW_DIR/QEMU_VARS.fd" "$STORAGE/vars.fd"
  log "boot: UEFI 启动 $STORAGE/data.qcow2"
  # shellcheck disable=SC2086
  "$QEMU" $(qemu_common_args) \
    -drive if=pflash,format=raw,readonly=on,file="$FW_DIR/QEMU_EFI.fd" \
    -drive if=pflash,format=raw,file="$STORAGE/vars.fd" \
    -drive file="$STORAGE/data.qcow2",if=virtio,format=qcow2 \
    $ARGUMENTS &
  qemu_pid=$!
  if [ "${INJECT:-0}" = 1 ]; then
    log "boot: 首启注入 ROOT_PASS/放开 sshd（约 3-5 分钟，期间串口视图被占用）"
    python3 /opt/firstboot_inject.py 127.0.0.1 5702 "$ROOT_PASS" || err "首启注入未确认成功，请人工检查"
    INJECT=0
  fi
  wait "$qemu_pid" || true
  qemu_pid=""
  log "boot: VM 已退出"
}

# ── 主流程 ────────────────────────────────────────────────────
start_web

if [ -f "$STORAGE/data.qcow2" ]; then
  log "检测到已有数据盘，跳过安装"
elif [ "${BOOT,,}" = "preinstalled" ]; then
  run_preinstalled
else
  run_install
fi

run_boot
