// VCamTweak - 系统级摄像头替换
// 注入点：mediaserverd 进程 - hook FigCaptureStream（底层私有 API，所有摄像头数据必经）
// mediaserverd 是系统进程，不受 roothide 应用黑名单影响，可实现全部 app 摄像头替换
//
// 关键设计（防止 WatchdogTimeout）：
// 1. %ctor 中只做 MSHookFunction，零文件 I/O，零 dispatch_async
// 2. 视频源延迟到第一次帧回调时初始化（此时 mediaserverd 已完全启动）
// 3. hook 函数中不写文件日志，只用 NSLog（os_log，不阻塞）
// 4. 文件日志改为周期性低频写入（每 300 帧）
#import <AVFoundation/AVFoundation.h>
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

// ============================================================
// 日志：NSLog 为主（不阻塞），文件日志低频写入
// ============================================================
static NSString *VCamLogPath1 = @"/var/mobile/vcam.log";

static void VCamWriteFile(NSString *path, NSString *line) {
    @try {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            NSString *parent = [path stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] createDirectoryAtPath:parent
                                  withIntermediateDirectories:YES attributes:nil error:nil];
            [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

// 只用 NSLog，不写文件（在 hook 函数和启动期间使用）
#define VCamLogNSLog(fmt, ...) NSLog(@"[VCam] " fmt, ##__VA_ARGS__)

// 写文件日志（只在低频场景使用，如每 300 帧一次）
#define VCamLogFile(fmt, ...) do { \
    NSString *_line = [NSString stringWithFormat:@"[%.0f] " fmt "\n", \
                       [NSDate date].timeIntervalSince1970 * 1000, ##__VA_ARGS__]; \
    NSLog(@"[VCam] " fmt, ##__VA_ARGS__); \
    VCamWriteFile(VCamLogPath1, _line); \
} while(0)

static NSString *VCamProcessName() {
    return [[NSProcessInfo processInfo] processName];
}

static BOOL VCamIsMediaServer() {
    return [VCamProcessName() isEqualToString:@"mediaserverd"];
}

// ============================================================
// 视频帧源：用 AVAssetReader 读取视频文件，循环输出 CMSampleBuffer
// ============================================================
@interface VCamVideoSource : NSObject
@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *output;
@property (nonatomic, strong) AVAsset *asset;
@property (nonatomic, assign) CMVideoFormatDescriptionRef formatDesc;
@property (nonatomic, assign) int videoWidth;
@property (nonatomic, assign) int videoHeight;
@property (nonatomic, strong) NSObject *lock;
- (instancetype)initWithURL:(NSURL *)url;
- (void)restart;
- (CMSampleBufferRef)copyNextSampleBuffer;
@end

@implementation VCamVideoSource

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        _lock = [[NSObject alloc] init];
        _asset = [AVAsset assetWithURL:url];
        NSArray<AVAssetTrack *> *videoTracks = [_asset tracksWithMediaType:AVMediaTypeVideo];
        if (videoTracks.count == 0) {
            VCamLogNSLog(@"[VideoSource] ERROR: no video tracks");
            return nil;
        }
        AVAssetTrack *track = videoTracks[0];
        CGSize naturalSize = track.naturalSize;
        _videoWidth = (int)naturalSize.width;
        _videoHeight = (int)naturalSize.height;
        VCamLogNSLog(@"[VideoSource] duration=%.2fs size=%dx%d tracks=%lu",
                CMTimeGetSeconds(_asset.duration), _videoWidth, _videoHeight,
                (unsigned long)videoTracks.count);
        [self restart];
    }
    return self;
}

- (void)restart {
    @synchronized(_lock) {
        if (_reader && _reader.status == AVAssetReaderStatusReading) {
            [_reader cancelReading];
        }
        NSDictionary *settings = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferWidthKey: @(_videoWidth),
            (id)kCVPixelBufferHeightKey: @(_videoHeight),
        };
        AVAssetTrack *track = [[_asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
        _output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
                                                            outputSettings:settings];
        _output.alwaysCopiesSampleData = NO;
        NSError *err = nil;
        _reader = [[AVAssetReader alloc] initWithAsset:_asset error:&err];
        if (err) {
            VCamLogNSLog(@"[VideoSource] reader init error: %@", err);
            return;
        }
        [_reader addOutput:_output];
        [_reader startReading];
        VCamLogNSLog(@"[VideoSource] reader started, status=%ld", (long)_reader.status);
    }
}

- (CMSampleBufferRef)copyNextSampleBuffer {
    @synchronized(_lock) {
        if (!_output) return NULL;
        CMSampleBufferRef sb = [_output copyNextSampleBuffer];
        if (!sb) {
            VCamLogNSLog(@"[VideoSource] EOF, restarting loop...");
            [self restart];
            sb = [_output copyNextSampleBuffer];
        }
        if (sb && _formatDesc == NULL) {
            CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
            if (fmt) {
                _formatDesc = (CMVideoFormatDescriptionRef)CFRetain(fmt);
                CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(_formatDesc);
                FourCharCode codec = CMFormatDescriptionGetMediaSubType(_formatDesc);
                VCamLogNSLog(@"[VideoSource] format: %dx%d codec=%c%c%c%c",
                        dims.width, dims.height,
                        (char)(codec >> 24), (char)(codec >> 16),
                        (char)(codec >> 8), (char)codec);
            }
        }
        return sb;
    }
}

@end

static VCamVideoSource *gVideoSource = nil;
static NSString *gVideoPath = @"/var/mobile/Media/vcam_replace.mp4";
static BOOL gReplaceEnabled = YES;
static volatile int32_t gFrameCount = 0;

// 视频源初始化标志：0=未初始化, 1=正在初始化, 2=已完成
static volatile int32_t gVideoSourceState = 0;

static void VCamInitVideoSource() {
    // 延迟初始化：在第一次帧回调时调用，此时 mediaserverd 已完全启动
    // 避免在 mediaserverd 启动期间创建 AVAssetReader（会依赖 mediaserverd 自己的服务导致死锁）
    if (__sync_bool_compare_and_swap(&gVideoSourceState, 0, 1)) {
        @autoreleasepool {
            if ([[NSFileManager defaultManager] fileExistsAtPath:gVideoPath]) {
                gVideoSource = [[VCamVideoSource alloc] initWithURL:[NSURL fileURLWithPath:gVideoPath]];
                if (gVideoSource) {
                    __sync_synchronize();
                    gVideoSourceState = 2;
                    VCamLogFile(@"[VCam] Video source loaded: %@", gVideoPath);
                } else {
                    gVideoSourceState = 0; // 允许重试
                    VCamLogNSLog(@"[VCam] Video source init failed, will retry");
                }
            } else {
                gVideoSourceState = 2; // 标记完成，不再重试
                VCamLogFile(@"[VCam] Video NOT found: %@", gVideoPath);
            }
        }
    }
}

// ============================================================
// FigCaptureStream C 函数 hook
// ============================================================
typedef void(*FigCaptureStreamOutputCallback)(void *ctx, CMSampleBufferRef sampleBuffer, void *stream);
static FigCaptureStreamOutputCallback orig_OutputCallback = NULL;

static void new_OutputCallback(void *ctx, CMSampleBufferRef sampleBuffer, void *stream) {
    int32_t count = __sync_add_and_fetch(&gFrameCount, 1);

    // 第一次帧回调时初始化视频源（此时 mediaserverd 已完全启动）
    if (gVideoSourceState == 0 && count == 1) {
        VCamInitVideoSource();
    }

    if (gReplaceEnabled && gVideoSourceState == 2 && gVideoSource && sampleBuffer) {
        // 低频日志：每 300 帧写一次文件日志
        BOOL doLog = (count % 300 == 1);
        if (doLog) {
            CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
            if (fmt) {
                CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fmt);
                FourCharCode codec = CMFormatDescriptionGetMediaSubType(fmt);
                VCamLogFile(@"[Frame#%d] orig %dx%d codec=%c%c%c%c, replacing...",
                        count, dims.width, dims.height,
                        (char)(codec >> 24), (char)(codec >> 16),
                        (char)(codec >> 8), (char)codec);
            }
        }
        CMSampleBufferRef newSb = [gVideoSource copyNextSampleBuffer];
        if (newSb) {
            orig_OutputCallback(ctx, newSb, stream);
            CFRelease(newSb);
            return;
        } else if (doLog) {
            VCamLogNSLog(@"[Frame#%d] video source empty, passing original", count);
        }
    }
    orig_OutputCallback(ctx, sampleBuffer, stream);
}

typedef void(*FigCaptureStreamSetSinkFunc)(void *stream, void *ctx, FigCaptureStreamOutputCallback callback);
static FigCaptureStreamSetSinkFunc orig_FigCaptureStreamSetSink = NULL;

static void new_FigCaptureStreamSetSink(void *stream, void *ctx, FigCaptureStreamOutputCallback callback) {
    // 不写文件日志！只用 NSLog（os_log 不阻塞）
    // 只在第一次调用时记录
    static volatile int32_t sinkCallCount = 0;
    int32_t callNum = __sync_add_and_fetch(&sinkCallCount, 1);
    if (callNum <= 3) {
        VCamLogNSLog(@"[Hook] FigCaptureStreamSetSink #%d: stream=%p ctx=%p callback=%p",
                     callNum, stream, ctx, callback);
    }

    if (callback) {
        orig_OutputCallback = callback;
        orig_FigCaptureStreamSetSink(stream, ctx, new_OutputCallback);
        if (callNum <= 3) {
            VCamLogNSLog(@"[Hook] Sink #%d replaced with new_OutputCallback", callNum);
        }
    } else {
        orig_FigCaptureStreamSetSink(stream, ctx, callback);
    }
}

// ============================================================
// %ctor: dylib 加载时立即执行
// 关键：只做 MSHookFunction，不做任何 I/O，不做 dispatch_async
// mediaserverd 启动期间零额外开销
// ============================================================
%ctor {
    // 第一件事：用底层系统调用写标记文件，验证 %ctor 是否执行
    // 不依赖 ObjC 运行时、不依赖 NSLog
    VCamWriteMarker("/var/mobile/Media/vcam_ctor_marker.txt", "CTOR_ENTERED");
    VCamWriteMarker("/var/containers/Shared/SystemGroup/systemgroup.com.apple.mediaserverd/vcam_ctor_marker.txt", "CTOR_ENTERED");

    @autoreleasepool {
        // 只用 NSLog，不写文件
        VCamLogNSLog(@"=== VCamTweak loaded: %@ (pid=%d) ===",
                VCamProcessName(), [[NSProcessInfo processInfo] processIdentifier]);

        if (VCamIsMediaServer()) {
            VCamWriteMarker("/var/mobile/Media/vcam_ctor_marker.txt", "IS_MEDIASERVERD");

            // 用 RTLD_DEFAULT 查找符号（mediaserverd 已加载 CoreMedia，无需 dlopen）
            // 避免 dlopen 在启动期间触发重复初始化
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
                VCamLogNSLog(@"[VCam] HOOKED FigCaptureStreamSetSink at %p", sym);
                VCamWriteMarker("/var/mobile/Media/vcam_ctor_marker.txt", "HOOK_DONE");
            } else {
                VCamLogNSLog(@"[VCam] WARNING: FigCaptureStreamSetSink not found!");
                VCamWriteMarker("/var/mobile/Media/vcam_ctor_marker.txt", "SYM_NOT_FOUND");
            }
        } else {
            VCamWriteMarker("/var/mobile/Media/vcam_ctor_marker.txt", "NOT_MEDIASERVERD");
        }
    }
}

// ============================================================
// 注意：不使用 ObjC %hook（Logos hook 在 dylib 加载时自动注册，
// 不受 %ctor 中 VCamIsMediaServer() 控制，若 plist 过滤失效会
// 导致 SpringBoard 等进程被注入后卡死 WatchdogTimeout）。
// 全部 hook 改用 MSHookFunction，仅在 %ctor 内 mediaserverd 进程中执行。
// ============================================================
