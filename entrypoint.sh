#!/usr/bin/env bash
# docker-qemu-loongarch — Loongnix(loongarch64) VM 运行器
# 精简模型（对齐 dockur/windows 的运行期行为）：
#   - 挂载现成磁盘镜像直跑（DISK_IMAGE 指定，qcow2/raw 自动识别）
#   - 主循环守护：VM 意外退出自动拉起
#   - SIGTERM → QMP system_powerdown 优雅关机（建议 docker stop -t 90）
#   - KVM 自动探测（真龙芯宿主透传 /dev/kvm 时硬加速，回落 TCG）
#   - 8006 仅 noVNC；串口全量日志落 /storage/serial.log 备排障
set -Eeuo pipefail

# ── 常量 ──────────────────────────────────────────────────────
QEMU=/usr/local/bin/qemu-system-loongarch64
QEMU_IMG=/usr/local/bin/qemu-img
FW_DIR=/firmware
WEB_DIR=/opt/web
STORAGE=/storage
RUN=/run/docker-loongnix

# ── 环境变量 ──────────────────────────────────────────────────
RAM_SIZE="${RAM_SIZE:-4G}"
CPU_CORES="${CPU_CORES:-2}"
CPU_MODEL="${CPU_MODEL:-la464}"          # la464 / la664
DISK_IMAGE="${DISK_IMAGE:-/storage/data.qcow2}"
VNC_PASSWORD="${VNC_PASSWORD:-}"         # 空 = 免认证
ARGUMENTS="${ARGUMENTS:-}"

ts() { date '+%F %T'; }
info() { printf '[loongarch] I %s %s\n' "$(ts)" "$*"; }
warn() { printf '[loongarch] W %s %s\n' "$(ts)" "$*" >&2; }
error() { printf '[loongarch] E %s %s\n' "$(ts)" "$*" >&2; }

mkdir -p "$RUN"

# ── 磁盘检查与格式识别 ────────────────────────────────────────
if [ ! -f "$DISK_IMAGE" ]; then
  error "磁盘镜像不存在: $DISK_IMAGE"
  error "请在 compose 中挂载镜像，例如:  - ./data.qcow2:/storage/data.qcow2"
  error "镜像获取：官方预装盘 https://pkg.loongnix.cn/loongnix-server/23.3/isos/Loongnix-Server-23.3.loongarch64.qcow2（可直接挂载，root 为空口令）"
  exit 1
fi
DISK_FMT=$("$QEMU_IMG" info "$DISK_IMAGE" | awk -F': *' '/^file format:/{print $2; exit}')
[ "$DISK_FMT" = qcow2 ] || [ "$DISK_FMT" = raw ] || { error "不支持的镜像格式: $DISK_FMT（支持 qcow2/raw）"; exit 1; }
info "磁盘: $DISK_IMAGE ($DISK_FMT, $(du -h "$DISK_IMAGE" | cut -f1))"

# ── UEFI vars（可写副本，与镜像同目录）────────────────────────
VARS="${DISK_IMAGE%/*}/vars.fd"
[ -f "$VARS" ] || cp "$FW_DIR/QEMU_VARS.fd" "$VARS"

# ── KVM 探测 ──────────────────────────────────────────────────
ACCEL="tcg,thread=multi"
if [ -c /dev/kvm ] && [ "$(uname -m)" = "loongarch64" ]; then
  ACCEL="kvm:tcg,thread=multi"
  info "检测到 /dev/kvm，启用 KVM（回落 TCG）"
else
  info "TCG 纯软件模拟（x86 宿主跨架构正常路径，性能约为原生 1/10）"
fi

# ── QMP（优雅关机/VNC 密码）───────────────────────────────────
qmp() { # qmp <execute> [extra-json]
  printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"%s}\n' "$1" "${2:-}" \
    | timeout 5 socat - "UNIX-CONNECT:$RUN/qmp.sock" 2>/dev/null | tail -n1 || true
}

qemu_pid=""
stopping=0
shutdown_vm() {
  stopping=1
  [ -n "$qemu_pid" ] || return 0
  info "SIGTERM → QMP system_powerdown (pid $qemu_pid)"
  qmp system_powerdown
  for _ in $(seq 1 90); do
    kill -0 "$qemu_pid" 2>/dev/null || { info "guest 已优雅关机"; return 0; }
    sleep 1
  done
  error "90s 未退出，强杀"
  kill -9 "$qemu_pid" 2>/dev/null || true
}
trap 'shutdown_vm' SIGTERM SIGINT
trap 'stopping=1; [ -n "$qemu_pid" ] && kill "$qemu_pid" 2>/dev/null || true' EXIT

set_vnc_password() {
  [ -n "$VNC_PASSWORD" ] || return 0
  qmp set_password "{\"arguments\":{\"protocol\":\"vnc\",\"password\":\"${VNC_PASSWORD//\"/\\\"}\"}}"
  qmp expire_password '{"arguments":{"protocol":"vnc","time":"never"}}'
}

# ── Web 栈：nginx(8006) + websockify（仅 noVNC）───────────────
start_web() {
  websockify -D 127.0.0.1:5700 127.0.0.1:5900 >/dev/null 2>&1
  nginx -c "$WEB_DIR/nginx.conf" 2>/dev/null || nginx -s reload -c "$WEB_DIR/nginx.conf"
  info "noVNC 就绪: http://0.0.0.0:8006"
}

# ── VM 启动 ───────────────────────────────────────────────────
run_vm() {
  info "开机: $DISK_IMAGE (${CPU_MODEL}×${CPU_CORES}, ${RAM_SIZE})"
  local vnc_args="-vnc 127.0.0.1:0"
  [ -n "$VNC_PASSWORD" ] && vnc_args="-vnc 127.0.0.1:0,password=on"
  # 串口仅落盘排障（/storage/serial.log），无 web 视图
  # shellcheck disable=SC2086
  "$QEMU" \
    -machine virt -cpu "$CPU_MODEL" -smp "$CPU_CORES" -m "$RAM_SIZE" \
    -accel "$ACCEL" \
    -drive if=pflash,format=raw,readonly=on,file="$FW_DIR/QEMU_EFI.fd" \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive file="$DISK_IMAGE",if=virtio,format="$DISK_FMT" \
    -device virtio-gpu-pci \
    -device nec-usb-xhci -device usb-tablet -device usb-kbd \
    $vnc_args \
    -chardev socket,id=ser0,path=$RUN/serial.sock,server=on,wait=off,logfile=$STORAGE/serial.log,logappend=on \
    -serial chardev:ser0 \
    -qmp unix:$RUN/qmp.sock,server,nowait \
    -netdev user,id=n0,hostfwd=tcp::22-:22 \
    -device virtio-net-pci,netdev=n0 \
    -device virtio-rng-pci \
    $ARGUMENTS &
  qemu_pid=$!
  set_vnc_password
  wait "$qemu_pid" || true
  qemu_pid=""
}

# ── 主循环（dockur 模型）：守护开机 ───────────────────────────
start_web
while [ "$stopping" = 0 ]; do
  run_vm
  if [ "$stopping" = 0 ]; then
    warn "VM 意外退出，3 秒后自动拉起（docker stop -t 90 优雅关机）"
    sleep 3
  fi
done
info "容器退出"
