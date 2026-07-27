#!/usr/bin/env python3
"""诊断 VCamTweak.dylib 加载阶段崩溃的原因"""
import paramiko
import sys

HOST = "192.168.1.9"
PORT = 22
USER = "root"
PASSWORD = "1"

def run(c, cmd, timeout=30):
    print(f"\n>>> {cmd}")
    try:
        stdin, stdout, stderr = c.exec_command(cmd, timeout=timeout, get_pty=True)
        out = stdout.read().decode("utf-8", errors="replace")
        print(out[:4000])
        return out
    except Exception as e:
        print(f"[ERROR] {e}")
        return ""

def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        c.connect(HOST, port=PORT, username=USER, password=PASSWORD,
                  look_for_keys=False, allow_agent=False, timeout=10)
    except Exception as e:
        print(f"[连接失败] {e}")
        sys.exit(1)

    DYLIB = "/var/jb/Library/MobileSubstrate/DynamicLibraries/VCamTweak.dylib.disabled"

    print("=" * 60)
    print(" [1] 检查 dylib 架构")
    print("=" * 60)
    run(c, f"file {DYLIB}")
    run(c, f"otool -hv {DYLIB} 2>&1")

    print("=" * 60)
    print(" [2] 检查 dylib 依赖的框架（关键！）")
    print("=" * 60)
    run(c, f"otool -L {DYLIB} 2>&1")

    print("=" * 60)
    print(" [3] 检查 mediaserverd 的架构")
    print("=" * 60)
    run(c, "file /usr/libexec/mediaserverd 2>/dev/null || file $(which mediaserverd 2>/dev/null) 2>/dev/null")
    run(c, "find / -name mediaserverd -type f 2>/dev/null | head -3")

    print("=" * 60)
    print(" [4] 检查 dylib 签名")
    print("=" * 60)
    run(c, f"ldid -e {DYLIB} 2>&1 | head -30")
    run(c, f"codesign -dvvv {DYLIB} 2>&1 | head -20")

    print("=" * 60)
    print(" [5] 检查 roothidepatch AutoPatches.dylib")
    print("=" * 60)
    run(c, "ls -la /usr/lib/DynamicPatches/AutoPatches.dylib 2>&1")
    run(c, "file /usr/lib/DynamicPatches/AutoPatches.dylib 2>&1")
    run(c, "otool -L /usr/lib/DynamicPatches/AutoPatches.dylib 2>&1")

    print("=" * 60)
    print(" [6] 检查 mediaserverd 已加载的 dylib")
    print("=" * 60)
    run(c, "launchctl list 2>&1 | grep mediaserverd")
    # 获取 mediaserverd PID
    out = run(c, "launchctl list 2>&1 | grep mediaserverd")
    pid = ""
    for line in out.split("\n"):
        parts = line.strip().split()
        if parts and parts[0].isdigit():
            pid = parts[0]
            break
    if pid:
        run(c, f"vmmap {pid} 2>/dev/null | grep -i vcam | head -5")
        # 检查 mediaserverd 加载的 substrate 相关 dylib
        run(c, f"vmmap {pid} 2>/dev/null | grep -iE 'substrate|mobilesubstate|tweakinject' | head -10")

    print("=" * 60)
    print(" [7] 检查 substrate/systemhook 状态")
    print("=" * 60)
    run(c, "ls -la /var/jb/usr/lib/substrate 2>/dev/null")
    run(c, "ls -la /var/jb/usr/lib/TweakInject/ 2>/dev/null | head -20")
    run(c, "find /var/jb -name 'systemhook*' 2>/dev/null")
    run(c, "find /var/jb -name 'substrate*' 2>/dev/null | head -10")

    print("=" * 60)
    print(" [8] 检查 tweak injection 开关文件")
    print("=" * 60)
    run(c, "find /var/jb -name '.tweak_injection_enabled' 2>/dev/null")
    run(c, "find /var/jb -name '*tweak_inject*' 2>/dev/null")
    run(c, "cat /var/jb/basebin/.tweak_injection_disabled 2>/dev/null; echo '---'")

    print("=" * 60)
    print(" [9] 检查是否有 crash 日志")
    print("=" * 60)
    run(c, "find /var/mobile/Library/Logs/CrashReporter -name '*.ips' 2>/dev/null | tail -10")
    run(c, "find /var/mobile/Library/Logs/CrashReporter -name 'mediaserverd*' 2>/dev/null | tail -5")
    # 也检查系统日志目录
    run(c, "find /var/log -name '*.crash' 2>/dev/null | tail -5")

    c.close()
    print("\n=== 诊断完成 ===")

if __name__ == "__main__":
    main()
