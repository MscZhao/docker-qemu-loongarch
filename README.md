# docker-qemu-loongarch

> Loongnix（loongarch64）虚拟机运行器 · 挂载镜像直跑 · noVNC 访问 · 对齐 [dockur/windows](https://github.com/dockur/windows) 体验

容器内置自编译 **QEMU 11.1.0**（TCG 跨架构模拟）+ EDK2 UEFI 固件。挂载一个现成的磁盘镜像（qcow2/raw），`docker compose up -d` 拉起龙芯 VM：浏览器 **8006** 进 noVNC 图形控制台，**22** 端口 SSH 直达 guest。

## 快速开始

```bash
git clone https://github.com/MscZhao/docker-qemu-loongarch.git
cd docker-qemu-loongarch

# 1. 准备磁盘镜像（放到仓库目录，见下方「镜像获取」）
# 2. 启动
docker compose up -d

# 浏览器打开 http://localhost:8006 （noVNC 控制台）
# ssh root@localhost （guest 内系统的口令）
```

`compose.yaml` 可配置 CPU、内存、挂载镜像等：

```yaml
services:
  loongarch-vm:
    image: docker-qemu-loongarch
    build: .
    restart: unless-stopped
    stop_grace_period: 2m
    ports:
      - "8006:8006"     # noVNC
      - "22:22"         # SSH → guest
    volumes:
      - ./data.qcow2:/storage/data.qcow2     # 换成你的镜像
    environment:
      RAM_SIZE: "4G"
      CPU_CORES: "2"
      CPU_MODEL: "la464"
      DISK_IMAGE: /storage/data.qcow2
      # VNC_PASSWORD: secret
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `DISK_IMAGE` | `/storage/data.qcow2` | 磁盘镜像路径（容器内），qcow2/raw 自动识别 |
| `RAM_SIZE` | `4G` | guest 内存 |
| `CPU_CORES` | `2` | guest vCPU 数 |
| `CPU_MODEL` | `la464` | QEMU CPU 型号（`la464` / `la664`） |
| `VNC_PASSWORD` | 空 | noVNC 的 VNC 层密码（空=免认证） |
| `ARGUMENTS` | 空 | 追加给 `qemu-system-loongarch64` 的额外参数 |

## 镜像获取

官方镜像站：<https://pkg.loongnix.cn/loongnix-server/23.3/isos/>

| 文件 | 大小 | md5 | 用途 |
|---|---|---|---|
| `Loongnix-Server-23.3.loongarch64.qcow2` | 1.2G | `4f958d74aad1f1f44741a141b31761fd` | 预装系统盘，挂载即用 |
| `Loongnix-Server-23.3-loongarch64-dvd.iso` | 3.5G | `7e2bf56015dd63b194966b1428e08701` | 安装介质（见下） |

### qcow2 预装盘：挂载即用

```bash
curl -O https://pkg.loongnix.cn/loongnix-server/23.3/isos/Loongnix-Server-23.3.loongarch64.qcow2
# compose 中 volumes 挂载该文件即可
```

注意：官方预装盘 root 为**空口令**（sshd 拒绝空密登录）。noVNC 图形控制台可直接登录后在终端里 `passwd` 设密码、`sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && systemctl restart sshd` 开启 SSH。

### DVD ISO：安装出自己的系统盘

ISO 不能直接挂载为磁盘，两种用法：

**① 本容器内图形安装（推荐）**——建空盘 + 挂 ISO，noVNC 里走安装向导：

```bash
# 1) 建空盘（一次性）
docker run --rm -v "$PWD:/storage" docker-qemu-loongarch \
  qemu-img create -f qcow2 /storage/data.qcow2 64G

# 2) 把 ISO 放到同目录，compose 里追加安装参数启动：
#    environment:
#      ARGUMENTS: "-cdrom /storage/install.iso -boot once=d"
#    volumes 中加一行: - ./Loongnix-Server-23.3-loongarch64-dvd.iso:/storage/install.iso:ro
docker compose up -d
# 3) 浏览器 8006 → anaconda 图形安装向导（分区时选自动即可）
# 4) 装完去掉 ARGUMENTS 的 -cdrom/-boot，重启容器即从磁盘引导
```

**② 龙芯真机/其他 QEMU 环境安装**：ISO 刻录或直接挂载安装出系统盘后，把产出的 qcow2/raw 拿来挂载。

### Live ISO：免安装直接体验

Loongnix 25.x 提供可直跑的 livecd（hybrid），同样用 `ARGUMENTS: "-cdrom /storage/live.iso -boot once=d"` 挂载启动，无需磁盘，noVNC 直接进桌面（TCG 下较慢）。

> 历史提示：本仓库曾内置 kickstart 无人值守自动安装（下载 ISO → 重制 → 全自动装），见 git 历史（`d3b34c4` 之前），需要无人值守场景可回溯。

## 与 dockur/windows 对齐的行为

- 一条命令拉起 VM；**主循环守护**——VM 意外退出自动重新拉起
- **优雅关机**：`docker stop -t 90`（compose 已配 `stop_grace_period: 2m`）→ QMP `system_powerdown`
- **KVM 自动探测**：真龙芯宿主透传 `--device /dev/kvm` 时硬加速，否则 TCG
- 8006 单端口 Web 控制台（noVNC）；22 SSH hostfwd
- 健康检查（QMP socket）；`/storage` 持久卷
- 排障串口日志全量落 `/storage/serial.log`

## 性能须知

x86_64 宿主跨架构为 **TCG 纯软件模拟（约原生 1/10）**：开机到登录 3-5 分钟属正常。真龙芯宿主加 `--device /dev/kvm` 可硬加速（需 loong64 版镜像构建）。

## 故障排查

- **8006 黑屏**：确认镜像可引导（UEFI + grub2-efi）；看 `docker logs` 与 `/storage/serial.log`
- **SSH 不通**：guest 需已配 sshd 且 root 允许密码登录（`PermitRootLogin yes`）
- **改配置**：compose 改 env 后 `docker compose up -d` 重建即生效

## 致谢

- [dockur/windows](https://github.com/dockur/windows) — 架构范本
- [QEMU LoongArch virt](https://www.qemu.org/docs/master/system/loongarch/virt.html) · [edk2 LoongArchVirt](https://github.com/tianocore/edk2/tree/master/OvmfPkg/LoongArchVirt)
- 研发全过程与踩坑记录保留在 git 历史提交信息中
