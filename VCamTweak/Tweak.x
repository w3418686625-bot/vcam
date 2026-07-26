// VCamTweak - 第一步：监控摄像头访问，验证 hook 注入链路
// 后续步骤会在此文件中扩展为视频帧替换
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

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

// ============================================================
// dylib 加载时立即触发（验证 ElleKit 是否真的注入了 dylib）
// ============================================================
%ctor {
    @autoreleasepool {
        VCamLog(@"=== VCamTweak dylib loaded into process: %@ (pid=%d) ===",
                [[NSProcessInfo processInfo] processName],
                [[NSProcessInfo processInfo] processIdentifier]);
    }
}

// ============================================================
// Hook 1: AVCaptureDevice - 监控 App 获取摄像头设备
// ============================================================
%hook AVCaptureDevice

// App 调用 +[AVCaptureDevice defaultDeviceWithMediaType:] 时触发
+ (AVCaptureDevice *)defaultDeviceWithMediaType:(NSString *)mediaType {
    AVCaptureDevice *device = %orig;
    if ([mediaType isEqualToString:AVMediaTypeVideo]) {
        VCamLog(@"defaultDeviceWithMediaType:video -> %@", device.localizedName);
    } else if ([mediaType isEqualToString:AVMediaTypeMuxed]) {
        VCamLog(@"defaultDeviceWithMediaType:muxed -> %@", device.localizedName);
    }
    return device;
}

// App 调用 +[AVCaptureDevice devicesWithMediaType:] 时触发
+ (NSArray *)devicesWithMediaType:(NSString *)mediaType {
    NSArray *devices = %orig;
    if ([mediaType isEqualToString:AVMediaTypeVideo]) {
        VCamLog(@"devicesWithMediaType:video -> count=%lu", (unsigned long)devices.count);
    }
    return devices;
}

%end

// ============================================================
// Hook 2: AVCaptureSession - 监控摄像头会话启停
// ============================================================
%hook AVCaptureSession

- (void)startRunning {
    VCamLog(@"AVCaptureSession startRunning (inputs=%lu)", (unsigned long)self.inputs.count);
    %orig;
}

- (void)stopRunning {
    VCamLog(@"AVCaptureSession stopRunning");
    %orig;
}

%end

// ============================================================
// Hook 3: AVCaptureVideoDataOutput - 监控视频帧输出回调设置
//   这是后续替换 sampleBuffer 的关键 hook 点
// ============================================================
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    VCamLog(@"setSampleBufferDelegate: delegate=%@ queue=%@", sampleBufferDelegate, sampleBufferCallbackQueue);
    %orig;
}

%end
