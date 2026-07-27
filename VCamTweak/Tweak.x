// VCamTweak - 系统级摄像头替换
// 注入点：
//   1. Camera app 进程 - hook AVCaptureDevice/Session（高层 Objective-C API）
//   2. mediaserverd 进程 - hook FigCaptureSession（底层私有 API，所有摄像头数据必经）
// mediaserverd 是系统进程，不受 roothide 应用黑名单影响
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

// ============================================================
// 文件日志：写到两处以确保能读到
//   1. /var/mobile/vcam.log （越狱 unsandbox 后可写）
//   2. App 沙盒 NSHomeDirectory()/vcam.log （必定可写）
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

// 获取当前进程名
static NSString *VCamProcessName() {
    return [[NSProcessInfo processInfo] processName];
}

// ============================================================
// dylib 加载时立即触发（验证注入链路 + 报告所在进程）
// ============================================================
%ctor {
    @autoreleasepool {
        VCamLog(@"=== VCamTweak dylib loaded into process: %@ (pid=%d) ===",
                VCamProcessName(),
                [[NSProcessInfo processInfo] processIdentifier]);
    }
}

// ============================================================
// Hook 1: AVCaptureDevice - Camera app 进程用
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

// ============================================================
// Hook 2: AVCaptureSession - Camera app 进程用
// ============================================================
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

// ============================================================
// Hook 3: AVCaptureVideoDataOutput - 帧输出回调设置
// ============================================================
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    VCamLog(@"[%@] setSampleBufferDelegate: delegate=%@ queue=%@", VCamProcessName(), sampleBufferDelegate, sampleBufferCallbackQueue);
    %orig;
}

%end

// ============================================================
// Hook 4: BWFigCaptureDeviceVendor - mediaserverd 进程 ObjC 类
//   mediaserverd 中管理摄像头设备的 ObjC 类（oslog 已确认存在）
//   用于验证 mediaserverd 中 ObjC hook 是否生效
// ============================================================
%hook BWFigCaptureDeviceVendor

- (id)_createDevice:(id)device clientPID:(pid_t)pid {
    VCamLog(@"[%@] BWFigCaptureDeviceVendor _createDevice: clientPID=%d", VCamProcessName(), pid);
    return %orig;
}

- (void)_invalidateAndReleaseDevice {
    VCamLog(@"[%@] BWFigCaptureDeviceVendor _invalidateAndReleaseDevice", VCamProcessName());
    %orig;
}

%end

// ============================================================
// Hook 5: BWFigCaptureDevice - mediaserverd 进程 ObjC 类
//   mediaserverd 中摄像头设备的 ObjC 包装类
// ============================================================
%hook BWFigCaptureDevice

- (id)initWithFigCaptureDevice:(id)device {
    VCamLog(@"[%@] BWFigCaptureDevice initWithFigCaptureDevice: %@", VCamProcessName(), [device class]);
    return %orig;
}

- (void)invalidate {
    VCamLog(@"[%@] BWFigCaptureDevice invalidate", VCamProcessName());
    %orig;
}

- (void)dealloc {
    VCamLog(@"[%@] BWFigCaptureDevice dealloc", VCamProcessName());
    %orig;
}

%end

// ============================================================
// Hook 6: FigCaptureStreamSetOutputSink - mediaserverd C 函数
//   这是 mediaserverd 中视频帧交付的核心回调注册点
//   所有摄像头帧都通过此回调交付（C 函数指针，非 ObjC）
//   用 %hookf 而非 %hook
//   FigCaptureStreamRef 是 CFTypeRef，callback 是帧交付函数指针
// ============================================================
// 注意：C 函数 hook 需要符号在链接时可用
// 如果符号在 CoreMedia 私有 framework 中，可能需要用 dlsym + MSHookFunction
// 先注释掉，等 ObjC hook 确认生效后再启用
// typedef void(*FigCaptureStreamOutputCallback)(void *ctx, void *sampleBuffer, void *stream);
// static FigCaptureStreamOutputCallback orig_FigCaptureStreamSetOutputSink = NULL;
// %hookf(void, FigCaptureStreamSetOutputSink, void *stream, void *ctx, FigCaptureStreamOutputCallback callback) {
//     VCamLog(@"[%@] FigCaptureStreamSetOutputSink: stream=%p ctx=%p callback=%p", VCamProcessName(), stream, ctx, (void *)callback);
//     %orig;
// }

// ============================================================
// Hook 7: FigCaptureStreamCreate - mediaserverd C 函数（暂注释）
// ============================================================
// %hookf(void *, FigCaptureStreamCreate, void *allocator) {
//     VCamLog(@"[%@] FigCaptureStreamCreate called", VCamProcessName());
//     void *result = %orig;
//     VCamLog(@"[%@] FigCaptureStreamCreate -> %p", VCamProcessName(), result);
//     return result;
// }

// ============================================================
// Hook 8: FigCaptureSessionCreate - mediaserverd C 函数（暂注释）
// ============================================================
// %hookf(void *, FigCaptureSessionCreate, void *allocator) {
//     VCamLog(@"[%@] FigCaptureSessionCreate called", VCamProcessName());
//     void *result = %orig;
//     VCamLog(@"[%@] FigCaptureSessionCreate -> %p", VCamProcessName(), result);
//     return result;
// }

// ============================================================
// Hook 9: FigCaptureSessionSetConfiguration - mediaserverd C 函数（暂注释）
// ============================================================
// %hookf(void, FigCaptureSessionSetConfiguration, void *session, void *configuration) {
//     VCamLog(@"[%@] FigCaptureSessionSetConfiguration: session=%p config=%p", VCamProcessName(), session, configuration);
//     %orig;
// }
