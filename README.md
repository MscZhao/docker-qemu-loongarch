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

任选其一，得到一个 qcow2/raw 磁盘镜像后挂载即可：

1. **官方预装盘（最快）**：<https://pkg.loongnix.cn/loongnix-server/23.3/isos/Loongnix-Server-23.3.loongarch64.qcow2>
   可直接挂载运行；注意其 root 为**空口令**（仅串口可免密登录，图形/noVNC 下请先经串口设置密码，或用下条方式装的镜像）
2. **自行安装**：下载同目录 DVD ISO，在任意 QEMU/龙芯机器上安装出系统盘
3. 也可以从本仓库历史版本的 `BOOT=install` 无人值守安装产物获得（已含 sshd/双控制台配置）

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
- 历史研发全过程与踩坑记录见 [HANDOFF.md](HANDOFF.md)
