// TestTweak.x - 极简测试 dylib
// 不链接任何外部库（无 AVFoundation, 无 substrate）
// 只验证 %ctor 是否在 opainject dlopen 后执行
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <sys/errno.h>
#import <objc/runtime.h>

// 尝试写入多个路径，记录哪些成功哪些失败
static void writeMarker(const char *path, const char *msg) {
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        char buf[256];
        int len = snprintf(buf, sizeof(buf), "%s (fd=%d)\n", msg, fd);
        write(fd, buf, len);
        close(fd);
    } else {
        // 如果失败，尝试写到一个已知可写的路径
        int efd = open("/var/mobile/Media/test_fail.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (efd >= 0) {
            char buf[256];
            int len = snprintf(buf, sizeof(buf), "FAIL open(%s) errno=%d\n", path, errno);
            write(efd, buf, len);
            close(efd);
        }
    }
}

// ObjC +load 方法（由 ObjC 运行时在 dylib 加载时调用）
@interface TestLoader : NSObject
@end

@implementation TestLoader
+ (void)load {
    writeMarker("/var/mobile/Media/test_load.txt", "LOAD_CALLED");
}
@end

%ctor {
    // 第一件事：写标记文件
    writeMarker("/var/mobile/Media/test_ctor.txt", "CTOR_ENTERED");
    writeMarker("/var/mobile/Media/test_ctor2.txt", "CTOR_ENTERED_2");
    writeMarker("/tmp/test_ctor.txt", "CTOR_TMP");
    writeMarker("/var/tmp/test_ctor.txt", "CTOR_VAR_TMP");
    writeMarker("/var/containers/Shared/SystemGroup/systemgroup.com.apple.mediaserverd/test_ctor.txt", "CTOR_SG");
}
