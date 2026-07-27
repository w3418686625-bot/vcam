// VCamTweak - 系统级摄像头替换
// 注入点：
//   1. Camera app 进程 - hook AVCaptureDevice/Session（高层 Objective-C API，验证用）
//   2. mediaserverd 进程 - hook FigCaptureStream（底层私有 API，所有摄像头数据必经）
// mediaserverd 是系统进程，不受 roothide 应用黑名单影响
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <substrate.h>

// ============================================================
// 日志：写到 /var/mobile/vcam.log + 沙盒 NSHomeDirectory()/vcam.log
// ============================================================
static NSString *VCamLogPath1 = @"/var/mobile/vcam.log";
static NSString *VCamLogPath2 = nil;

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

static void VCamLogImpl(NSString *msg) {
    NSString *line = [NSString stringWithFormat:@"[%.0f] %@\n",
                      [NSDate date].timeIntervalSince1970 * 1000, msg];
    NSLog(@"[VCam] %@", msg);
    VCamWriteFile(VCamLogPath1, line);
    if (VCamLogPath2 == nil) {
        VCamLogPath2 = [NSHomeDirectory() stringByAppendingPathComponent:@"vcam.log"];
    }
    VCamWriteFile(VCamLogPath2, line);
}

#define VCamLog(fmt, ...) VCamLogImpl([NSString stringWithFormat:fmt, ##__VA_ARGS__])

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
            VCamLog(@"[VideoSource] ERROR: no video tracks");
            return nil;
        }
        AVAssetTrack *track = videoTracks[0];
        CGSize naturalSize = track.naturalSize;
        _videoWidth = (int)naturalSize.width;
        _videoHeight = (int)naturalSize.height;
        VCamLog(@"[VideoSource] duration=%.2fs size=%dx%d tracks=%lu",
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
            VCamLog(@"[VideoSource] reader init error: %@", err);
            return;
        }
        [_reader addOutput:_output];
        [_reader startReading];
        VCamLog(@"[VideoSource] reader started, status=%ld", (long)_reader.status);
    }
}

- (CMSampleBufferRef)copyNextSampleBuffer {
    @synchronized(_lock) {
        if (!_output) return NULL;
        CMSampleBufferRef sb = [_output copyNextSampleBuffer];
        if (!sb) {
            VCamLog(@"[VideoSource] EOF, restarting loop...");
            [self restart];
            sb = [_output copyNextSampleBuffer];
        }
        if (sb && _formatDesc == NULL) {
            CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
            if (fmt) {
                _formatDesc = (CMVideoFormatDescriptionRef)CFRetain(fmt);
                CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(_formatDesc);
                FourCharCode codec = CMFormatDescriptionGetMediaSubType(_formatDesc);
                VCamLog(@"[VideoSource] format: %dx%d codec=%c%c%c%c",
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

static void VCamInitVideoSource() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if ([[NSFileManager defaultManager] fileExistsAtPath:gVideoPath]) {
            gVideoSource = [[VCamVideoSource alloc] initWithURL:[NSURL fileURLWithPath:gVideoPath]];
            VCamLog(@"[VCam] Video source loaded: %@", gVideoPath);
        } else {
            VCamLog(@"[VCam] Video NOT found: %@", gVideoPath);
        }
    });
}

// ============================================================
// FigCaptureStream C 函数 hook
// ============================================================
typedef void(*FigCaptureStreamOutputCallback)(void *ctx, CMSampleBufferRef sampleBuffer, void *stream);
static FigCaptureStreamOutputCallback orig_OutputCallback = NULL;

static void new_OutputCallback(void *ctx, CMSampleBufferRef sampleBuffer, void *stream) {
    int32_t count = __sync_add_and_fetch(&gFrameCount, 1);

    if (gReplaceEnabled && gVideoSource && sampleBuffer) {
        if (count % 60 == 1) {
            CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
            if (fmt) {
                CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fmt);
                FourCharCode codec = CMFormatDescriptionGetMediaSubType(fmt);
                VCamLog(@"[Frame#%d] orig %dx%d codec=%c%c%c%c, replacing...",
                        count, dims.width, dims.height,
                        (char)(codec >> 24), (char)(codec >> 16),
                        (char)(codec >> 8), (char)codec);
            }
        }
        CMSampleBufferRef newSb = [gVideoSource copyNextSampleBuffer];
        if (newSb) {
            if (count % 60 == 1) {
                VCamLog(@"[Frame#%d] replaced with video frame", count);
            }
            orig_OutputCallback(ctx, newSb, stream);
            CFRelease(newSb);
            return;
        } else if (count % 60 == 1) {
            VCamLog(@"[Frame#%d] video source empty, passing original", count);
        }
    }
    orig_OutputCallback(ctx, sampleBuffer, stream);
}

typedef void(*FigCaptureStreamSetSinkFunc)(void *stream, void *ctx, FigCaptureStreamOutputCallback callback);
static FigCaptureStreamSetSinkFunc orig_FigCaptureStreamSetSink = NULL;

static void new_FigCaptureStreamSetSink(void *stream, void *ctx, FigCaptureStreamOutputCallback callback) {
    VCamLog(@"[Hook] FigCaptureStreamSetSink: stream=%p ctx=%p callback=%p", stream, ctx, callback);
    if (callback) {
        orig_OutputCallback = callback;
        orig_FigCaptureStreamSetSink(stream, ctx, new_OutputCallback);
        VCamLog(@"[Hook] Sink replaced with new_OutputCallback");
    } else {
        orig_FigCaptureStreamSetSink(stream, ctx, callback);
    }
}

// ============================================================
// 探测：枚举 CoreMedia 中 FigCaptureStream* 符号
// ============================================================
static void VCamProbeSymbols() {
    void *handle = dlopen("/System/Library/Frameworks/CoreMedia.framework/CoreMedia", RTLD_LAZY);
    if (!handle) {
        VCamLog(@"[Probe] Failed to open CoreMedia.framework");
        return;
    }
    const char *symNames[] = {
        "FigCaptureStreamSetSink",
        "FigCaptureStreamSetOutputSink",
        "FigCaptureStreamSetSampleBufferSink",
        "FigCaptureStreamSetOutput",
        "FigCaptureStreamSetCallback",
        "FigCaptureStreamCopyNextSampleBuffer",
        "FigCaptureStreamGetNextSampleBuffer",
        "FigCaptureStreamCreate",
        "FigCaptureStreamCreateWithDevice",
        NULL
    };
    for (int i = 0; symNames[i] != NULL; i++) {
        void *sym = dlsym(handle, symNames[i]);
        if (sym) {
            VCamLog(@"[Probe] FOUND: %s at %p", symNames[i], sym);
        }
    }
}

static void VCamProbeObjCClasses() {
    const char *classNames[] = {
        "FigCaptureStream",
        "BWFigCaptureStream",
        "AVFigCaptureStream",
        "FigCaptureSession",
        "BWFigCaptureSession",
        "AVFigCaptureSession",
        "BWFigCaptureDevice",
        NULL
    };
    for (int i = 0; classNames[i] != NULL; i++) {
        Class cls = objc_getClass(classNames[i]);
        if (cls) {
            VCamLog(@"[Probe] FOUND ObjC class: %s", classNames[i]);
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(cls, &methodCount);
            if (methods) {
                for (unsigned int j = 0; j < methodCount && j < 40; j++) {
                    SEL sel = method_getName(methods[j]);
                    VCamLog(@"[Probe]   -[%s %s]", classNames[i], sel_getName(sel));
                }
                free(methods);
            }
        }
    }
}

// ============================================================
// %ctor: dylib 加载时立即执行
// ============================================================
%ctor {
    @autoreleasepool {
        VCamLog(@"=== VCamTweak loaded: %@ (pid=%d) ===",
                VCamProcessName(), [[NSProcessInfo processInfo] processIdentifier]);

        if (VCamIsMediaServer()) {
            VCamLog(@"[VCam] In mediaserverd, initializing...");
            VCamProbeSymbols();
            VCamProbeObjCClasses();
            VCamInitVideoSource();

            void *handle = dlopen("/System/Library/Frameworks/CoreMedia.framework/CoreMedia", RTLD_LAZY);
            if (handle) {
                const char *symNames[] = {
                    "FigCaptureStreamSetSink",
                    "FigCaptureStreamSetOutputSink",
                    "FigCaptureStreamSetSampleBufferSink",
                    NULL
                };
                BOOL hooked = NO;
                for (int i = 0; symNames[i] != NULL && !hooked; i++) {
                    void *sym = dlsym(handle, symNames[i]);
                    if (sym) {
                        MSHookFunction(sym,
                                      (void *)new_FigCaptureStreamSetSink,
                                      (void **)&orig_FigCaptureStreamSetSink);
                        VCamLog(@"[VCam] HOOKED %s at %p", symNames[i], sym);
                        hooked = YES;
                    }
                }
                if (!hooked) {
                    VCamLog(@"[VCam] WARNING: no FigCaptureStream sink symbol found!");
                }
            } else {
                VCamLog(@"[VCam] Failed to open CoreMedia.framework");
            }
        }
    }
}

// ============================================================
// ObjC hooks（Camera app 进程用，验证注入）
// ============================================================
%hook AVCaptureDevice

+ (AVCaptureDevice *)defaultDeviceWithMediaType:(NSString *)mediaType {
    AVCaptureDevice *device = %orig;
    if ([mediaType isEqualToString:AVMediaTypeVideo]) {
        VCamLog(@"[%@] defaultDeviceWithMediaType:video -> %@", VCamProcessName(), device.localizedName);
    } else if ([mediaType isEqualToString:AVMediaTypeMuxed]) {
        VCamLog(@"[%@] defaultDeviceWithMediaType:muxed -> %@", VCamProcessName(), device.localizedName);
    }
    return device;
}

+ (NSArray *)devicesWithMediaType:(NSString *)mediaType {
    NSArray *devices = %orig;
    if ([mediaType isEqualToString:AVMediaTypeVideo]) {
        VCamLog(@"[%@] devicesWithMediaType:video -> count=%lu", VCamProcessName(), (unsigned long)devices.count);
    }
    return devices;
}

%end

%hook AVCaptureSession

- (void)startRunning {
    VCamLog(@"[%@] AVCaptureSession startRunning (inputs=%lu)", VCamProcessName(), (unsigned long)self.inputs.count);
    %orig;
}

- (void)stopRunning {
    VCamLog(@"[%@] AVCaptureSession stopRunning", VCamProcessName());
    %orig;
}

%end

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    VCamLog(@"[%@] setSampleBufferDelegate: delegate=%@ queue=%@", VCamProcessName(), sampleBufferDelegate, sampleBufferCallbackQueue);
    %orig;
}

%end

%hook BWFigCaptureDevice

- (id)initWithFigCaptureDevice:(void *)device {
    @try {
        VCamLog(@"[%@] BWFigCaptureDevice initWithFigCaptureDevice: device=%p", VCamProcessName(), device);
    } @catch (NSException *e) {}
    return %orig;
}

%end
