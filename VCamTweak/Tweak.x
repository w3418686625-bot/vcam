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
// mediaserverd hook 暂时禁用（导致 SIGBUS 崩溃 + WatchdogTimeout）
// 等 Camera 进程 hook 稳定后再单独调试 mediaserverd
// ============================================================
// %hook BWFigCaptureDeviceVendor
// - (id)_createDevice:(void *)device clientPID:(int)pid {
//     VCamLog(@"[%@] BWFigCaptureDeviceVendor _createDevice: clientPID=%d device=%p", VCamProcessName(), pid, device);
//     return %orig;
// }
// %end
//
// %hook BWFigCaptureDevice
// - (id)initWithFigCaptureDevice:(void *)device {
//     VCamLog(@"[%@] BWFigCaptureDevice initWithFigCaptureDevice: device=%p", VCamProcessName(), device);
//     return %orig;
// }
// %end
