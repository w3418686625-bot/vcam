#!/usr/bin/env python3
"""检查设备上的 hook 框架和 dylib 依赖"""
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

    print("=" * 60)
    print(" [1] 检查 hook 框架 (substrate/ellekit/substitute)")
    print("=" * 60)
    # rootless substrate 路径
    run(c, "find /var/jb -name 'libsubstrate*' 2>/dev/null")
    run(c, "find /var/jb -name 'libellekit*' 2>/dev/null")
    run(c, "find /var/jb -name 'libsubstitute*' 2>/dev/null")
    run(c, "find /var/jb -name 'SubstrateFramework*' 2>/dev/null")
    # 检查 TweakInject 目录下的符号链接
    run(c, "ls -la /var/jb/usr/lib/TweakInject/.jbroot 2>/dev/null")
    run(c, "ls -la /var/jb/usr/lib/libsubstrate* 2>/dev/null")
    run(c, "ls -la /var/jb/usr/lib/libellekit* 2>/dev/null")
    # substrate.h 对应的 dylib
    run(c, "find /var/jb -name 'substrate' -type d 2>/dev/null")
    run(c, "ls -la /var/jb/usr/lib/substrate/ 2>/dev/null")

    print("=" * 60)
    print(" [2] 检查 systemhook (Dopamine 的注入机制)")
    print("=" * 60)
    run(c, "find /var/jb/basebin -name 'systemhook*' 2>/dev/null")
    run(c, "ls -la /var/jb/basebin/ 2>/dev/null")

    print("=" * 60)
    print(" [3] 检查 vcameracrack.dylib 的 plist")
    print("=" * 60)
    run(c, "cat /var/jb/usr/lib/TweakInject/vcameracrack.plist 2>&1")

    print("=" * 60)
    print(" [4] 用 dyld_info 检查 VCamTweak.dylib 依赖")
    print("=" * 60)
    DYLIB = "/var/jb/Library/MobileSubstrate/DynamicLibraries/VCamTweak.dylib.disabled"
    run(c, f"dyld_info {DYLIB} 2>&1 | head -50")
    # 如果没有 dyld_info，尝试用其他方式
    run(c, f"which dyld_info 2>/dev/null; which otool 2>/dev/null; which jtool 2>/dev/null; which jtool2 2>/dev/null")

    print("=" * 60)
    print(" [5] 用 strings 检查 dylib 中的框架引用")
    print("=" * 60)
    run(c, f"strings {DYLIB} 2>/dev/null | grep -iE 'AVFoundation|CoreMedia|CoreVideo|substrate|ellekit|/usr/lib' | head -30")

    print("=" * 60)
    print(" [6] 检查 mediaserverd 加载的 dylib（通过 /proc）")
    print("=" * 60)
    out = run(c, "launchctl list 2>&1 | grep mediaserverd")
    pid = ""
    for line in out.split("\n"):
        parts = line.strip().split()
        if parts and parts[0].isdigit():
            pid = parts[0]
            break
    if pid:
        run(c, f"cat /proc/{pid}/maps 2>/dev/null | grep -iE 'AVFoundation|CoreMedia|substrate|ellekit' | head -20")
        # 也尝试用 launchctl procinfo
        run(c, f"launchctl procinfo {pid} 2>&1 | head -50")

    print("=" * 60)
    print(" [7] 检查 mediaserverd 二进制位置和依赖")
    print("=" * 60)
    run(c, "ls -la /usr/libexec/mediaserverd 2>/dev/null")
    run(c, "ls -la /System/Library/Frameworks/MediaToolbox.framework/mediaserverd 2>/dev/null")
    run(c, "find /System -name 'mediaserverd' -type f 2>/dev/null | head -3")

    print("=" * 60)
    print(" [8] 检查 AVFoundation 是否在系统中存在")
    print("=" * 60)
    run(c, "ls -la /System/Library/Frameworks/AVFoundation.framework 2>/dev/null")
    run(c, "ls -la /System/Library/Frameworks/AVFoundation.framework/AVFoundation 2>/dev/null")

    print("=" * 60)
    print(" [9] 检查 tweak injection 开关")
    print("=" * 60)
    run(c, "ls -la /var/jb/.tweak_injection_enabled 2>&1")
    # Dopamine 可能用不同的方式控制
    run(c, "find /var/jb/basebin -maxdepth 1 -type f 2>/dev/null | head -20")
    run(c, "cat /var/jb/basebin/.tweak_injection_disabled 2>/dev/null; echo '---'")

    c.close()
    print("\n=== 诊断完成 ===")

if __name__ == "__main__":
    main()
