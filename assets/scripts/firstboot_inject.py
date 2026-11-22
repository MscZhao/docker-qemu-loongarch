#!/usr/bin/env python3
"""preinstalled 模式首启注入：官方 qcow2 root 为空口令且 sshd 禁空密登录，
串口登录后设置 ROOT_PASS、放开 PermitRootLogin、尽力扩容根分区。
用法: firstboot_inject.py <serial-host> <serial-port> <root-pass>"""
import socket, sys, time, re

HOST, PORT, PW = sys.argv[1], int(sys.argv[2]), sys.argv[3]
# 单引号安全转义（chpasswd 用单引号包裹）
PW_ESC = PW.replace("'", "'\\''")

s = None
for _ in range(60):
    try:
        s = socket.create_connection((HOST, PORT), timeout=10); break
    except OSError:
        time.sleep(2)
assert s is not None, "无法连接串口"
s.settimeout(2)
buf = b""

def pump(sec):
    global buf
    end = time.time() + sec
    while time.time() < end:
        try:
            d = s.recv(65536)
            if d:
                buf += d
                sys.stdout.write(d.decode("utf-8", "replace")); sys.stdout.flush()
        except socket.timeout:
            pass
        except OSError:
            print("\n[inject] 串口连接断开（qemu 已退出？）"); sys.exit(3)
    return

def wait_for(pat, timeout):
    rx = re.compile(pat.encode())
    end = time.time() + timeout
    while time.time() < end:
        if rx.search(buf[-4000:]):
            return True
        pump(2)
    return False

def send(line):
    s.sendall(line.encode() + b"\n"); time.sleep(1)

print(f"[inject] 等待 login 提示（TCG 首启较慢，最长 30 分钟）…", flush=True)
if not wait_for(r"login:", 1800):
    print("\n[inject] ❌ 超时未见 login"); sys.exit(2)

send("root")
# 空口令直接进 shell；保险起见处理可能出现的 Password:
if wait_for(r"Password:", 20):
    send("")
wait_for(r"[#]\s*$", 120)
print("\n[inject] 已登录，注入配置…", flush=True)

cmds = [
    f"echo 'root:{PW_ESC}' | chpasswd",
    "sed -i -e 's/^#\\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config"
    " && grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config",
    "systemctl restart sshd && systemctl is-active sshd",
    # 根分区尽力扩容（qcow2 已被 resize 时生效；工具缺失则跳过，无副作用）
    "(command -v growpart >/dev/null && ls /dev/vda* | grep -q vda && "
    "growpart /dev/vda $(( $(lsblk -nr -o NAME,TYPE | awk '$2==\"part\"{n=split($1,a,\"vda\");print a[n]+0}' | tail -1) )) "
    "&& resize2fs $(findmnt -n -o SOURCE /)) || echo growpart-skip",
    "touch /root/.docker-loongnix-injected && echo INJECT-DONE",
]
for c in cmds:
    send(c)
    pump(12)

if b"INJECT-DONE" in buf[-3000:]:
    print("\n[inject] ✅ 注入完成（root 口令已设置、sshd 已放开 root 登录）")
    s.close(); sys.exit(0)
print("\n[inject] ⚠️ 未确认 INJECT-DONE，请人工经串口/网页检查")
sys.exit(1)
