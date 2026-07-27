#!/usr/bin/env python3
"""恢复脚本：禁用 VCamTweak 注入，防止 mediaserverd 崩溃循环"""
import paramiko
import time
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
        print(out[:3000])
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
    print(" [1] 检查 tweak injection 当前状态")
    print("=" * 60)
    run(c, "ls -la /var/jb/.tweak_injection_enabled 2>&1; echo '---'")
    run(c, "cat /var/jb/basebin/.tweak_injection_enabled 2>/dev/null; echo '---'")

    print("=" * 60)
    print(" [2] 检查 VCamTweak 文件位置")
    print("=" * 60)
    # roothide 环境下 plist 和 dylib 的实际位置
    run(c, "find /var/jb -name 'VCamTweak*' 2>/dev/null")
    run(c, "find /var/jb -name 'VCamTweak*' -type l 2>/dev/null")
    # 检查 TweakInject 目录
    run(c, "ls -la /var/jb/Library/MobileSubstrate/DynamicLibraries/VCamTweak* 2>&1")
    run(c, "ls -la /var/jb/usr/lib/TweakInject/VCamTweak* 2>&1")

    print("=" * 60)
    print(" [3] 禁用 VCamTweak 注入（改 plist 为不注入任何进程）")
    print("=" * 60)

    # 方法1：将 plist 内容改为不注入任何进程
    plist_paths = [
        "/var/jb/Library/MobileSubstrate/DynamicLibraries/VCamTweak.plist",
        "/var/jb/usr/lib/TweakInject/VCamTweak.plist",
    ]

    for pp in plist_paths:
        out = run(c, f"test -f {pp} && echo EXISTS || echo MISSING")
        if "EXISTS" in out:
            # 备份原 plist
            run(c, f"cp {pp} {pp}.bak 2>/dev/null; echo backed_up")
            # 写入新 plist：不注入任何进程
            run(c, f"echo '{{ Filter = {{ Executables = ( \"__none__\" ); }}; }}' > {pp}")
            run(c, f"cat {pp}")
            print(f"  ✅ 已禁用 {pp}")

    # 方法2：同时重命名 dylib 作为双保险
    dylib_paths = [
        "/var/jb/Library/MobileSubstrate/DynamicLibraries/VCamTweak.dylib",
        "/var/jb/usr/lib/TweakInject/VCamTweak.dylib",
    ]
    for dp in dylib_paths:
        out = run(c, f"test -f {dp} && echo EXISTS || echo MISSING")
        if "EXISTS" in out:
            run(c, f"mv {dp} {dp}.disabled 2>/dev/null; echo moved")
            print(f"  ✅ 已重命名 {dp} -> .disabled")

    # 检查 roothidepatch 重定向
    for dp in dylib_paths:
        run(c, f"ls -la {dp}.roothidepatch 2>/dev/null; echo '---'")
        run(c, f"mv {dp}.roothidepatch {dp}.roothidepatch.disabled 2>/dev/null; echo 'roothidepatch_disabled'")

    print("=" * 60)
    print(" [4] 检查 mediaserverd 状态")
    print("=" * 60)
    out = run(c, "launchctl list 2>&1 | grep mediaserverd")
    run(c, "ps aux 2>/dev/null | grep mediaserverd | grep -v grep")

    print("=" * 60)
    print(" [5] 检查标记文件（验证 %ctor 是否执行过）")
    print("=" * 60)
    run(c, "ls -la /var/mobile/Media/vcam_ctor_marker.txt 2>&1")
    run(c, "cat /var/mobile/Media/vcam_ctor_marker.txt 2>&1")
    run(c, "ls -la /var/containers/Shared/SystemGroup/systemgroup.com.apple.mediaserverd/vcam_ctor_marker.txt 2>&1")

    print("=" * 60)
    print(" [6] 检查 vcam.log（如果有）")
    print("=" * 60)
    run(c, "ls -la /var/mobile/vcam.log 2>&1")
    run(c, "tail -30 /var/mobile/vcam.log 2>/dev/null")

    print("=" * 60)
    print(" [7] 检查 crash 日志")
    print("=" * 60)
    run(c, "ls -lt /var/mobile/Library/Logs/CrashReporter/ 2>/dev/null | head -10")
    run(c, "find /var/mobile/Library/Logs/CrashReporter -name 'mediaserverd*' -newer /var/jb/.tweak_injection_enabled 2>/dev/null | head -5")

    print("=" * 60)
    print(" [8] 系统总体状态")
    print("=" * 60)
    run(c, "launchctl list 2>&1 | grep -iE 'mediaserverd|SpringBoard|backboardd|jailbreakd'")

    c.close()
    print("\n" + "=" * 60)
    print(" 恢复完成！现在可以安全地重新开启 tweak injection")
    print(" VCamTweak 已被禁用，不会再注入 mediaserverd")
    print("=" * 60)

if __name__ == "__main__":
    main()
