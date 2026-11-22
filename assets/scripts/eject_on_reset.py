#!/usr/bin/env python3
"""安装完成自动弹盘：监听 QMP RESET 事件（anaconda 装完重启），
立即 eject 光驱里的安装 ISO → qemu 复位后从磁盘引导。全程无需人工干预。"""
import json, socket, sys, time

QMP = sys.argv[1] if len(sys.argv) > 1 else "/run/docker-loongnix/qmp.sock"

s = None
for _ in range(60):
    try:
        s = socket.socket(socket.AF_UNIX)
        s.connect(QMP)
        break
    except OSError:
        time.sleep(2)    # 等 qemu 创建 QMP socket
assert s is not None, "无法连接 QMP"
s.settimeout(None)

def send(obj):
    s.sendall(json.dumps(obj).encode() + b"\n")

def recv_events():
    buf = b""
    while True:
        d = s.recv(65536)
        if not d:
            return
        buf += d
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            line = line.strip()
            if line:
                try:
                    yield json.loads(line)
                except ValueError:
                    pass

# 握手（跳过 greeting）
gen = recv_events()
send({"execute": "qmp_capabilities"})
time.sleep(1)

def find_cd_device():
    send({"execute": "query-block"})
    time.sleep(0.5)
    for msg in recv_events():
        if "return" in msg and isinstance(msg["return"], list):
            for b in msg["return"]:
                ins = b.get("inserted") or {}
                if b.get("removable") and ins.get("file", "").endswith(".iso"):
                    return b["device"], ins["file"]
    return None, None

print("[eject-watcher] 等待安装完成（guest RESET）…", flush=True)
for msg in recv_events():
    ev = msg.get("event")
    if ev in ("RESET", "SHUTDOWN", "POWERDOWN"):
        dev, iso = find_cd_device()
        if dev:
            send({"execute": "eject", "arguments": {"id": dev, "force": True}})
            time.sleep(1)
            print(f"[eject-watcher] {ev} → 已弹出 {iso}（{dev}），重启将从磁盘引导", flush=True)
        else:
            print(f"[eject-watcher] {ev}，未发现插入的 ISO，无需弹出", flush=True)
        sys.exit(0)
