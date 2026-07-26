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
// Hook 4: FigCaptureSession - mediaserverd 进程用（私有 API）
//   mediaserverd 是系统进程，所有摄像头数据必经
//   FigCaptureSession 是 CoreMedia 私有类，处理实际捕获
//   如果类不存在（非 mediaserverd 进程），hook 静默失败
// ============================================================
%hook FigCaptureSession

- (void)startRunning {
    VCamLog(@"[%@] FigCaptureSession startRunning", VCamProcessName());
    %orig;
}

- (void)stopRunning {
    VCamLog(@"[%@] FigCaptureSession stopRunning", VCamProcessName());
    %orig;
}

- (void)setConfiguration:(id)configuration {
    VCamLog(@"[%@] FigCaptureSession setConfiguration: %@", VCamProcessName(), [configuration class]);
    %orig;
}

%end

// ============================================================
// Hook 5: FigCaptureVideoDataOutput - mediaserverd 帧输出
//   适用于 mediaserverd 中处理视频帧的私有类
// ============================================================
%hook FigCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    VCamLog(@"[%@] FigCaptureVideoDataOutput setSampleBufferDelegate: %@ queue=%@", VCamProcessName(), delegate, queue);
    %orig;
}

%end
