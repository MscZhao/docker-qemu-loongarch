# docker-loongnix

一条 `docker run` 拉起 **Loongnix Server 23.3（loongarch64）虚拟机**——容器内置自编译 QEMU v10.2.0 + EDK2 UEFI 固件，默认 **kickstart 无人值守全自动安装**，浏览器 8006 端口双视图（串口 + noVNC）看安装/使用全过程。参照 [dockur/windows](https://github.com/dockur/windows) 的龙芯版。

## 快速开始

```bash
docker build -t docker-loongnix .

# 默认 BOOT=install：首次启动自动下载 DVD ISO（~3.5G）并 kickstart 全自动安装
docker run -d --name loongnix \
  -p 8006:8006 -p 22:22 \
  -v loongnix-storage:/storage \
  docker-loongnix

# 浏览器打开 http://localhost:8006 —— 安装期看「串口」视图（anaconda 文本安装），
# TCG 纯软件模拟下安装约 30-90 分钟；装完自动重启进系统。
# 之后: ssh root@localhost -p 22 （口令默认 lab，可用 ROOT_PASS 自定义）
```

## 双视图 Web 控制台（:8006）

| 视图 | 内容 | 阶段 |
|---|---|---|
| 串口（默认） | xterm.js ↔ QEMU `ttyS0`，anaconda 安装进度 / systemd 启动日志 / 登录控制台 | 全程 |
| 图形 noVNC | virtio-gpu 图形控制台（UEFI/GRUB/图形界面） | 全程 |

单端口 nginx 入口，两条 websockify 通道（VNC / 串口），无外部依赖。

## 环境变量（对齐 dockur）

| 变量 | 默认 | 说明 |
|---|---|---|
| `RAM_SIZE` | `4G` | guest 内存 |
| `CPU_CORES` | `2` | guest vCPU 数 |
| `DISK_SIZE` | `64G` | 系统盘大小（install 模式生效；preinstalled 尽力扩容） |
| `BOOT` | `install` | `install`=kickstart 全自动安装；`preinstalled`=官方预装 qcow2 快路径（下载 1.2G，免安装） |
| `ROOT_PASS` | `lab` | root 口令（install 模式写入 kickstart；preinstalled 模式首启串口注入） |
| `CPU_MODEL` | `la464` | QEMU CPU 型号，可换 `la664` |
| `ARGUMENTS` | 空 | 追加给 qemu-system-loongarch64 的额外参数 |

## 两种引导模式

```
/storage/data.qcow2 已存在 ─────────→ 直接 UEFI 开机（秒起）
无盘 + BOOT=install（默认）→ 下载 DVD ISO（md5 校验）→ xorriso 抽 vmlinuz/initrd
                             → kickstart 经 cpio 追加进 initrd（inst.ks=file:/ks.cfg）
                             → -kernel 直启 anaconda 串口文本安装 → 装完 reboot 退出
                             → 转 UEFI 磁盘启动
无盘 + BOOT=preinstalled  → 下载官方 qcow2（md5 校验）→ convert/扩容
                             → UEFI 开机，首启串口注入 ROOT_PASS + 放开 sshd root 登录
```

官方预装镜像实测 root 为**空口令**（sshd 拒绝空密登录），故 preinstalled 模式必须首启注入。

## 性能说明（重要）

x86_64 宿主跨架构跑 loongarch64 只能 **TCG 纯软件模拟（无 KVM），慢约一个数量级**：

- kickstart 安装 30-90 分钟（属正常）
- preinstalled 快路径跳过安装，5 分钟内可用（推荐先体验）
- 真龙芯宿主可透传 `--device /dev/kvm`（当前镜像为 x86_64 构建，未来可出 loong64 版镜像 + `-cpu host`）

## 架构

```
容器
├─ entrypoint.sh            状态机（install / preinstalled / 已有盘直开）
├─ qemu-system-loongarch64  v10.2.0 源码自编译（-machine virt -cpu la464）
│   ├─ EDK2 QEMU_EFI.fd/QEMU_VARS.fd（pflash）
│   ├─ virtio-blk 数据盘 /storage/data.qcow2
│   ├─ slirp user-net，hostfwd tcp:22→guest:22
│   ├─ VNC :5900 + 串口 chardev tcp:5702 + QMP unix sock（优雅关机/健康检查）
│   └─ 安装期：-kernel/-initrd 直启 + DVD scsi-cd + -no-reboot（装完即退出转常态）
├─ nginx :8006              双视图入口 + 静态资产
├─ websockify :5700→5900    noVNC 通道
└─ websockify :5701→5702    串口通道（xterm.js）
```

## 常用操作

```bash
# 优雅关机（entrypoint 捕获 SIGTERM → QMP system_powerdown）
docker stop loongnix

# 重装（清空数据卷后重启容器即重新走安装）
docker rm -f loongnix && docker volume rm loongnix-storage

# 快路径体验
docker run -d -p 8006:8006 -p 22:22 -v lx-fast:/storage -e BOOT=preinstalled docker-loongnix
```

## 已知限制

- 仅本地构建，未推 registry（国内 docker.io 被墙，基础镜像 debian:trixie-slim 取自本地）
- TCG 慢（见上）；串口视图同一时刻单客户端（websockify 通道独占 QEMU chardev）
- 预装镜像根分区扩容依赖 guest 内 growpart，缺失时保持原始分区大小（多余空间闲置，无副作用）

## 来源

- 镜像: <https://pkg.loongnix.cn/loongnix-server/23/isos/>
- 固件: Debian `qemu-efi-loongarch64`（edk2 `OvmfPkg/LoongArchVirt`）
- [QEMU LoongArch virt 文档](https://www.qemu.org/docs/master/system/loongarch/virt.html)
