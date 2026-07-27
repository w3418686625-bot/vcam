// VCamTweak - 系统级摄像头替换 (极简版 - 验证 hook)
// 注入点：mediaserverd 进程 - hook FigCaptureStream（底层私有 API，所有摄像头数据必经）
//
// 关键设计（防止 WatchdogTimeout）：
// 1. 不链接 AVFoundation（mediaserverd 中加载 AVFoundation 会导致 dylib 在 %ctor 前崩溃）
// 2. %ctor 中只做 MSHookFunction，零文件 I/O，零 dispatch_async
// 3. hook 函数中只用 NSLog（os_log，不阻塞）
// 4. 写标记文件验证 %ctor 执行（用底层系统调用，不依赖 ObjC 运行时）
//
// 此版本只验证 hook 是否工作，不做视频帧替换
// 视频帧替换将在 hook 验证成功后用 VideoToolbox 实现（不依赖 AVFoundation）
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <substrate.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>

// ============================================================
// 标记文件写入：用底层系统调用，不依赖 ObjC 运行时
// 用于验证 %ctor 是否真的执行
// ============================================================
static void VCamWriteMarker(const char *path, const char *msg) {
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        write(fd, msg, strlen(msg));
        write(fd, "\n", 1);
        close(fd);
    }
}

// 只用 NSLog（os_log，不阻塞，不依赖文件系统）
#define VCamLog(fmt, ...) NSLog(@"[VCam] " fmt, ##__VA_ARGS__)

static NSString *VCamProcessName() {
    return [[NSProcessInfo processInfo] processName];
}

static BOOL VCamIsMediaServer() {
    return [VCamProcessName() isEqualToString:@"mediaserverd"];
}

// ============================================================
// FigCaptureStream C 函数 hook
// ============================================================
typedef void(*FigCaptureStreamOutputCallback)(void *ctx, CMSampleBufferRef sampleBuffer, void *stream);
static FigCaptureStreamOutputCallback orig_OutputCallback = NULL;

static volatile int32_t gFrameCount = 0;

static void new_OutputCallback(void *ctx, CMSampleBufferRef sampleBuffer, void *stream) {
    int32_t count = __sync_add_and_fetch(&gFrameCount, 1);

    // 只在前 5 帧和每 1000 帧记录日志
    if (count <= 5 || (count % 1000) == 0) {
        if (sampleBuffer) {
            CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
            if (fmt) {
                CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fmt);
                FourCharCode codec = CMFormatDescriptionGetMediaSubType(fmt);
                VCamLog(@"[Frame#%d] %dx%d codec=%c%c%c%c",
                        count, dims.width, dims.height,
                        (char)(codec >> 24), (char)(codec >> 16),
                        (char)(codec >> 8), (char)codec);
            } else {
                VCamLog(@"[Frame#%d] no format desc", count);
            }
        } else {
            VCamLog(@"[Frame#%d] NULL sampleBuffer", count);
        }
    }

    // 传递原始帧（不做替换，只验证 hook 工作）
    if (orig_OutputCallback) {
        orig_OutputCallback(ctx, sampleBuffer, stream);
    }
}

typedef void(*FigCaptureStreamSetSinkFunc)(void *stream, void *ctx, FigCaptureStreamOutputCallback callback);
static FigCaptureStreamSetSinkFunc orig_FigCaptureStreamSetSink = NULL;

static void new_FigCaptureStreamSetSink(void *stream, void *ctx, FigCaptureStreamOutputCallback callback) {
    static volatile int32_t sinkCallCount = 0;
    int32_t callNum = __sync_add_and_fetch(&sinkCallCount, 1);

    if (callNum <= 3) {
        VCamLog(@"[Hook] FigCaptureStreamSetSink #%d: stream=%p ctx=%p callback=%p",
                 callNum, stream, ctx, callback);
    }

    if (callback) {
        orig_OutputCallback = callback;
        orig_FigCaptureStreamSetSink(stream, ctx, new_OutputCallback);
        if (callNum <= 3) {
            VCamLog(@"[Hook] Sink #%d replaced with new_OutputCallback", callNum);
            // 写标记文件确认 hook 触发
            VCamWriteMarker("/var/mobile/Media/vcam_hook_triggered.txt", "SINK_REPLACED");
        }
    } else {
        orig_FigCaptureStreamSetSink(stream, ctx, callback);
    }
}

// ============================================================
// %ctor: dylib 加载时立即执行
// 关键：只做 MSHookFunction，不做任何 I/O，不做 dispatch_async
// ============================================================
%ctor {
    // 第一件事：用底层系统调用写标记文件，验证 %ctor 是否执行
    VCamWriteMarker("/var/mobile/Media/vcam_ctor_marker.txt", "CTOR_ENTERED");

    @autoreleasepool {
        VCamLog(@"=== VCamTweak loaded: %@ (pid=%d) ===",
                VCamProcessName(), [[NSProcessInfo processInfo] processIdentifier]);

        if (VCamIsMediaServer()) {
            VCamWriteMarker("/var/mobile/Media/vcam_ctor_marker.txt", "IS_MEDIASERVERD");

            // 用 RTLD_DEFAULT 查找符号（mediaserverd 已加载 CoreMedia，无需 dlopen）
            void *sym = dlsym(RTLD_DEFAULT, "FigCaptureStreamSetSink");
            if (!sym) {
                // 回退：尝试多个可能的符号名
                const char *symNames[] = {
                    "FigCaptureStreamSetOutputSink",
                    "FigCaptureStreamSetSampleBufferSink",
                    NULL
                };
                for (int i = 0; symNames[i] != NULL && !sym; i++) {
                    sym = dlsym(RTLD_DEFAULT, symNames[i]);
                }
            }
            if (sym) {
                VCamWriteMarker("/var/mobile/Media/vcam_ctor_marker.txt", "SYM_FOUND");
                MSHookFunction(sym,
                              (void *)new_FigCaptureStreamSetSink,
                              (void **)&orig_FigCaptureStreamSetSink);
                VCamLog(@"[VCam] HOOKED FigCaptureStreamSetSink at %p", sym);
                VCamWriteMarker("/var/mobile/Media/vcam_ctor_marker.txt", "HOOK_DONE");
            } else {
                VCamLog(@"[VCam] WARNING: FigCaptureStreamSetSink not found!");
                VCamWriteMarker("/var/mobile/Media/vcam_ctor_marker.txt", "SYM_NOT_FOUND");
            }
        } else {
            VCamWriteMarker("/var/mobile/Media/vcam_ctor_marker.txt", "NOT_MEDIASERVERD");
        }
    }
}
