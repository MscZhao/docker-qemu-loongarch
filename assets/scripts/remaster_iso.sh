#!/usr/bin/env bash
# 重制安装 ISO：grub.cfg 第一项注入 console=ttyS0 + inst.ks=<KSURL>
# 同时改 ISO 内与 efiboot.img ESP 内两份 grub.cfg，复刻原引导布局（El Torito/GPT/system-area）
# 用法: remaster_iso.sh <原ISO> <输出ISO> <ks-url>
set -Eeuo pipefail
SRC=$(readlink -f "${1:?原ISO}") DST=$(readlink -f "${2:?输出ISO}") KSURL=${3:?ks-url}
T=$(mktemp -d /tmp/iso-tree.XXXX)

log() { echo "[remaster] $*"; }

log "解包 $(basename "$SRC")"
xorriso -osirrox on -indev "$SRC" -extract / "$T/tree" >/dev/null 2>&1
chmod -R u+w "$T/tree"

log "改写 grub.cfg（timeout=3 / default=0 / 第一项+console+ks）"
python3 - "$T/tree/EFI/BOOT/grub.cfg" "$KSURL" <<'PYEOF'
import sys
path, ksurl = sys.argv[1], sys.argv[2]
s = open(path).read()
s = s.replace('set timeout=60', 'set timeout=3')
s = s.replace('set default="1"', 'set default="0"')
anchor = 'inst.stage2=hd:LABEL=Loongnix-Server-23.3-loongarch64 ro '
# console=tty0 在前：内核日志镜像到图形控制台（noVNC 可见），ttyS0 在后为 anaconda 文本 UI 主界面
extra = f'console=tty0 console=ttyS0,115200 inst.ks={ksurl} '
assert anchor in s, 'grub.cfg 锚点未找到'
s = s.replace(anchor, anchor + extra, 1)
open(path, 'w').write(s)
PYEOF

log "回写 efiboot.img 内 grub.cfg"
mcopy -i "$T/tree/images/efiboot.img" -o "$T/tree/EFI/BOOT/grub.cfg" ::/EFI/BOOT/grub.cfg

log "重建 ISO（复刻原引导布局）"
xorriso -as mkisofs \
  -V 'Loongnix-Server-23.3-loongarch64' \
  --protective-msdos-label -partition_cyl_align off -partition_offset 0 \
  -G "--interval:local_fs:0s-15s:zero_mbrpt,zero_gpt:$SRC" \
  -efi-boot-part --efi-boot-image \
  -c /boot.catalog -e /images/efiboot.img \
  -no-emul-boot \
  -R -J -joliet-long -o "$DST" "$T/tree" >/dev/null 2>&1

rm -rf "$T"
log "完成: $DST ($(stat -c %s "$DST") B)"
