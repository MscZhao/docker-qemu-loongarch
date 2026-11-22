#!/usr/bin/env python3
"""串口复用器：QEMU chardev(unix sock) 单客户端 → TCP :5702 多客户端。
- 桥接双向数据（guest 输出广播给所有客户端；客户端输入透传给 guest）
- 内存 256KB 环形缓冲：新客户端接入先回放历史，再实时流
- QEMU 重启后自动重连（entrypoint 两阶段 qemu 之间无缝衔接）
QEMU 侧另用 chardev logfile= 全量落盘 /storage/serial.log，互不冲突。
"""
import collections
import socket
import sys
import threading
import time

QEMU_SOCK = sys.argv[1] if len(sys.argv) > 1 else "/run/docker-loongnix/serial.sock"
LISTEN_HOST = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
LISTEN_PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 5702

RING = collections.deque()      # 每项是一个 bytes 块（注意：不能 extend(bytes)，那会散成 int）
RING_BYTES = 0
RING_MAX = 256 * 1024
lock = threading.Lock()
clients = set()
qsock = None            # 唯一的 QEMU chardev 连接
qlock = threading.Lock()

log = lambda msg: print(f"[mux] {msg}", flush=True)


def ring_append(d: bytes):
    global RING_BYTES
    RING.append(d)
    RING_BYTES += len(d)
    while RING_BYTES > RING_MAX and len(RING) > 1:
        RING_BYTES -= len(RING.popleft())


def qemu_connect():
    """维护到 QEMU chardev 的唯一连接，guest 输出 → 广播。"""
    global qsock
    while True:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(QEMU_SOCK)
        except OSError:
            time.sleep(2)
            continue
        with qlock:
            qsock = s
        log("已连接 QEMU 串口")
        try:
            while True:
                d = s.recv(65536)
                if not d:
                    break
                with lock:
                    ring_append(d)
                    dead = []
                    for c in clients:
                        try:
                            c.sendall(d)
                        except OSError:
                            dead.append(c)
                    for c in dead:
                        clients.discard(c)
        except OSError:
            pass
        with qlock:
            qsock = None
        try:
            s.close()
        except OSError:
            pass
        log("QEMU 串口断开，2s 后重连")
        time.sleep(2)


def client_loop(c):
    c.settimeout(None)
    while True:
        try:
            d = c.recv(65536)
        except OSError:
            break
        if not d:
            break
        with qlock:
            if qsock is not None:
                try:
                    qsock.sendall(d)
                except OSError:
                    pass
    with lock:
        clients.discard(c)
    try:
        c.close()
    except OSError:
        pass


def main():
    threading.Thread(target=qemu_connect, daemon=True).start()
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((LISTEN_HOST, LISTEN_PORT))
    srv.listen(8)
    log(f"监听 {LISTEN_HOST}:{LISTEN_PORT} ← {QEMU_SOCK}")
    while True:
        try:
            c, _ = srv.accept()
            with lock:
                c.sendall(b"".join(RING))   # 先回放历史
                clients.add(c)
            threading.Thread(target=client_loop, args=(c,), daemon=True).start()
        except Exception as e:
            log(f"accept 异常: {e!r}")


if __name__ == "__main__":
    main()
