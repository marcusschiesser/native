#import "audio_capture.h"

/* Zig 0.16 diagnoses inconsistencies in older Apple SDK umbrella headers as
 * errors. Keep those SDK-owned diagnostics isolated from this translation
 * unit without suppressing warnings in the implementation below. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>
#pragma clang diagnostic pop
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* These ordinals intentionally mirror platform/types.zig. */
enum { NS_CAPTURE_STARTED = 0, NS_CAPTURE_STOPPED = 1, NS_CAPTURE_FAILED = 2, NS_CAPTURE_REJECTED = 3 };
enum {
    NS_REASON_NONE = 0, NS_REASON_INVALID_OPTIONS = 1, NS_REASON_PERMISSION_MISSING = 2,
    NS_REASON_PERMISSION_REQUIRED = 3, NS_REASON_ALREADY_RECORDING = 4,
    NS_REASON_DEVICE_NOT_FOUND = 5, NS_REASON_DEVICE_DISCONNECTED = 6,
    NS_REASON_OUTPUT_EXISTS = 7, NS_REASON_IO_FAILED = 8, NS_REASON_CAPTURE_FAILED = 9,
    NS_REASON_NO_AUDIO = 10, NS_REASON_UNSUPPORTED = 11,
};
enum { NS_DEVICE = 0, NS_DEVICES_COMPLETED = 1, NS_DEVICES_FAILED = 2, NS_DEVICES_REJECTED = 3 };
enum {
    NS_ACCESS_AUTHORIZED = 0, NS_ACCESS_NOT_AUTHORIZED = 1, NS_ACCESS_NOT_DETERMINED = 2,
    NS_ACCESS_DENIED = 3, NS_ACCESS_RESTRICTED = 4, NS_ACCESS_UNAVAILABLE = 5,
};

API_AVAILABLE(macos(15.0))
@interface NativeSdkAudioCapture : NSObject <SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>
@property(nonatomic, assign) native_sdk_audio_capture_callback_t callback;
@property(nonatomic, assign) void *callbackContext;
@property(nonatomic, strong) dispatch_queue_t sampleQueue;
@property(nonatomic, strong) SCStream *screenStream;
@property(nonatomic, strong) AVCaptureSession *microphoneSession;
@property(nonatomic, strong) AVCaptureAudioDataOutput *microphoneOutput;
@property(nonatomic, strong) NSString *selectedMicrophoneID;
@property(nonatomic, strong) NSString *destinationPath;
@property(nonatomic, strong) NSString *wavTemporaryPath;
@property(nonatomic, strong) NSString *mixTemporaryPath;
@property(nonatomic, assign) int mixFD;
@property(nonatomic, assign) uint32_t sampleRate;
@property(nonatomic, assign) uint8_t channelCount;
@property(nonatomic, assign) BOOL combined;
@property(nonatomic, assign) BOOL active;
@property(nonatomic, assign) BOOL terminalEmitted;
@property(nonatomic, assign) BOOL observingDevices;
@property(nonatomic, assign) BOOL hasBasePTS;
@property(nonatomic, assign) CMTime basePTS;
@property(nonatomic, assign) uint64_t maxFrame;
@property(nonatomic, assign) uint64_t sampleBufferCount;
@property(nonatomic, assign) int publishFailureReason;
@property(nonatomic, strong) id connectedObserver;
@property(nonatomic, strong) id disconnectedObserver;
@property(nonatomic, strong) dispatch_semaphore_t finalizationSemaphore;
- (int)startPath:(NSString *)path systemAudio:(BOOL)systemAudio microphoneKind:(int)microphoneKind microphoneID:(NSString *)microphoneID sampleRate:(uint32_t)sampleRate channels:(uint8_t)channels excludeCurrentProcessAudio:(BOOL)exclude;
- (void)stopCapture;
- (void)finishWithState:(int)state reason:(int)reason;
@end

static void NativeSdkWriteLE16(uint8_t *out, uint16_t value) {
    out[0] = (uint8_t)(value & 0xff); out[1] = (uint8_t)(value >> 8);
}
static void NativeSdkWriteLE32(uint8_t *out, uint32_t value) {
    out[0] = (uint8_t)(value & 0xff); out[1] = (uint8_t)((value >> 8) & 0xff);
    out[2] = (uint8_t)((value >> 16) & 0xff); out[3] = (uint8_t)(value >> 24);
}

static NSArray<AVCaptureDevice *> *NativeSdkMicrophones(void) API_AVAILABLE(macos(15.0));
static NSArray<AVCaptureDevice *> *NativeSdkMicrophones(void) {
    AVCaptureDeviceDiscoverySession *session = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeMicrophone ]
        mediaType:AVMediaTypeAudio position:AVCaptureDevicePositionUnspecified];
    return session.devices;
}

static AVCaptureDevice *NativeSdkMicrophone(NSString *identifier, BOOL useDefault) API_AVAILABLE(macos(15.0));
static AVCaptureDevice *NativeSdkMicrophone(NSString *identifier, BOOL useDefault) {
    if (useDefault) return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    for (AVCaptureDevice *device in NativeSdkMicrophones()) {
        if ([device.uniqueID isEqualToString:identifier]) return device;
    }
    return nil;
}

/* Xcode 15's macOS 14 SDK does not declare ScreenCaptureKit's macOS 15
 * microphone additions. Resolve the setters dynamically so applications can
 * still build with that SDK while using the capability when running on 15+. */
static BOOL NativeSdkConfigureScreenCaptureMicrophone(SCStreamConfiguration *configuration, NSString *deviceID) API_AVAILABLE(macos(15.0));
static BOOL NativeSdkConfigureScreenCaptureMicrophone(SCStreamConfiguration *configuration, NSString *deviceID) {
    SEL captureSelector = NSSelectorFromString(@"setCaptureMicrophone:");
    SEL deviceSelector = NSSelectorFromString(@"setMicrophoneCaptureDeviceID:");
    if (![configuration respondsToSelector:captureSelector] || ![configuration respondsToSelector:deviceSelector]) return NO;
    [configuration setValue:@YES forKey:@"captureMicrophone"];
    [configuration setValue:deviceID forKey:@"microphoneCaptureDeviceID"];
    return YES;
}

/* SCStreamOutputType is an ABI-stable NS_ENUM: screen=0, audio=1, and the
 * microphone case added in macOS 15 is 2. */
static SCStreamOutputType NativeSdkMicrophoneOutputType(void) API_AVAILABLE(macos(15.0));
static SCStreamOutputType NativeSdkMicrophoneOutputType(void) { return (SCStreamOutputType)2; }

@implementation NativeSdkAudioCapture

- (instancetype)initWithCallback:(native_sdk_audio_capture_callback_t)callback context:(void *)context {
    self = [super init];
    if (!self) return nil;
    _callback = callback;
    _callbackContext = context;
    _sampleQueue = dispatch_queue_create("dev.native-sdk.audio-capture", DISPATCH_QUEUE_SERIAL);
    _mixFD = -1;
    return self;
}

- (void)dealloc {
    [self stopDeviceObservers];
    if (_screenStream) [_screenStream stopCaptureWithCompletionHandler:nil];
    if (_microphoneSession.running) [_microphoneSession stopRunning];
    if (_mixFD >= 0) close(_mixFD);
}

- (void)emit:(native_sdk_audio_capture_event_t)event {
    if ([NSThread isMainThread]) {
        native_sdk_audio_capture_callback_t callback = self.callback;
        if (callback) callback(self.callbackContext, &event);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        native_sdk_audio_capture_callback_t callback = self.callback;
        if (callback) callback(self.callbackContext, &event);
    });
}

- (void)emitCaptureState:(int)state reason:(int)reason duration:(uint64_t)duration bytes:(uint64_t)bytes committed:(BOOL)committed {
    native_sdk_audio_capture_event_t event = { .kind = NATIVE_SDK_AUDIO_CAPTURE_EVENT_CAPTURE,
        .state = state, .reason = reason, .duration_ms = duration,
        .bytes_written = bytes, .output_committed = committed ? 1 : 0 };
    [self emit:event];
}

- (void)startDeviceObservers {
    if (self.connectedObserver || self.disconnectedObserver) return;
    __weak NativeSdkAudioCapture *weakSelf = self;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    self.connectedObserver = [center addObserverForName:AVCaptureDeviceWasConnectedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        (void)note; NativeSdkAudioCapture *strongSelf = weakSelf; if (!strongSelf) return;
        native_sdk_audio_capture_event_t event = { .kind = NATIVE_SDK_AUDIO_CAPTURE_EVENT_DEVICES_CHANGED };
        [strongSelf emit:event];
    }];
    self.disconnectedObserver = [center addObserverForName:AVCaptureDeviceWasDisconnectedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        NativeSdkAudioCapture *strongSelf = weakSelf; if (!strongSelf) return;
        AVCaptureDevice *device = note.object;
        if (strongSelf.active && strongSelf.selectedMicrophoneID.length > 0 && [device.uniqueID isEqualToString:strongSelf.selectedMicrophoneID]) {
            [strongSelf finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_DEVICE_DISCONNECTED];
        }
        native_sdk_audio_capture_event_t event = { .kind = NATIVE_SDK_AUDIO_CAPTURE_EVENT_DEVICES_CHANGED };
        [strongSelf emit:event];
    }];
}

- (void)stopDeviceObservers {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    if (self.connectedObserver) [center removeObserver:self.connectedObserver];
    if (self.disconnectedObserver) [center removeObserver:self.disconnectedObserver];
    self.connectedObserver = nil; self.disconnectedObserver = nil;
}

- (int)prepareFilesAtPath:(NSString *)path {
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return 3;
    NSString *directory = [path stringByDeletingLastPathComponent];
    if (directory.length == 0) directory = @".";
    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:directory isDirectory:&isDirectory] || !isDirectory) return 7;
    NSString *nonce = NSUUID.UUID.UUIDString;
    self.wavTemporaryPath = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.%@.tmp", path.lastPathComponent, nonce]];
    self.mixTemporaryPath = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.%@.mix", path.lastPathComponent, nonce]];
    self.mixFD = open(self.mixTemporaryPath.fileSystemRepresentation, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (self.mixFD < 0) return 7;
    return 0;
}

- (int)startPath:(NSString *)path systemAudio:(BOOL)systemAudio microphoneKind:(int)microphoneKind microphoneID:(NSString *)microphoneID sampleRate:(uint32_t)sampleRate channels:(uint8_t)channels excludeCurrentProcessAudio:(BOOL)exclude {
    if (self.active) return 2;
    if (@available(macOS 15.0, *)) {} else { return 6; }
    if (path.length == 0 || (!systemAudio && microphoneKind == 0) || (channels != 1 && channels != 2)) return 1;
    if (sampleRate != 16000 && sampleRate != 24000 && sampleRate != 44100 && sampleRate != 48000) return 1;
    if (systemAudio && !CGPreflightScreenCaptureAccess()) return 4;
    if (microphoneKind != 0 && [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized) return 4;
    AVCaptureDevice *device = nil;
    if (microphoneKind != 0) {
        device = NativeSdkMicrophone(microphoneID, microphoneKind == 1);
        if (!device) return 5;
    }
    int fileResult = [self prepareFilesAtPath:path];
    if (fileResult != 0) return fileResult;
    self.destinationPath = path;
    self.selectedMicrophoneID = device.uniqueID;
    self.sampleRate = sampleRate;
    self.channelCount = channels;
    self.combined = systemAudio && microphoneKind != 0;
    self.active = YES; self.terminalEmitted = NO; self.hasBasePTS = NO;
    self.maxFrame = 0; self.sampleBufferCount = 0;
    self.finalizationSemaphore = dispatch_semaphore_create(0);
    [self startDeviceObservers];

    if (systemAudio) {
        [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES completionHandler:^(SCShareableContent *content, NSError *error) {
            if (!self.active) return;
            if (error || content.displays.count == 0) { [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_CAPTURE_FAILED]; return; }
            NSArray<SCRunningApplication *> *excluded = @[];
            if (exclude) {
                NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
                if (bundleID.length > 0) {
                    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(SCRunningApplication *application, NSDictionary *bindings) {
                        (void)bindings; return [application.bundleIdentifier isEqualToString:bundleID];
                    }];
                    excluded = [content.applications filteredArrayUsingPredicate:predicate];
                }
            }
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:content.displays.firstObject excludingApplications:excluded exceptingWindows:@[]];
            SCStreamConfiguration *configuration = [SCStreamConfiguration new];
            configuration.width = 2; configuration.height = 2; configuration.minimumFrameInterval = CMTimeMake(1, 1);
            configuration.showsCursor = NO; configuration.capturesAudio = YES;
            configuration.sampleRate = sampleRate; configuration.channelCount = channels;
            configuration.excludesCurrentProcessAudio = exclude;
            if (microphoneKind != 0 && !NativeSdkConfigureScreenCaptureMicrophone(configuration, device.uniqueID)) {
                [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_UNSUPPORTED]; return;
            }
            SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:self];
            NSError *addError = nil;
            if (![stream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:self.sampleQueue error:&addError] ||
                (microphoneKind != 0 && ![stream addStreamOutput:self type:NativeSdkMicrophoneOutputType() sampleHandlerQueue:self.sampleQueue error:&addError])) {
                [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_CAPTURE_FAILED]; return;
            }
            self.screenStream = stream;
            [stream startCaptureWithCompletionHandler:^(NSError *startError) {
                if (startError) [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_CAPTURE_FAILED];
                else if (self.active && !self.terminalEmitted) [self emitCaptureState:NS_CAPTURE_STARTED reason:NS_REASON_NONE duration:0 bytes:0 committed:NO];
            }];
        }];
        return 0;
    }

    dispatch_async(self.sampleQueue, ^{
        NSError *inputError = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&inputError];
        if (!input) { [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_DEVICE_NOT_FOUND]; return; }
        AVCaptureSession *session = [AVCaptureSession new];
        AVCaptureAudioDataOutput *output = [AVCaptureAudioDataOutput new];
        [output setSampleBufferDelegate:self queue:self.sampleQueue];
        [session beginConfiguration];
        if (![session canAddInput:input] || ![session canAddOutput:output]) {
            [session commitConfiguration]; [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_CAPTURE_FAILED]; return;
        }
        [session addInput:input]; [session addOutput:output]; [session commitConfiguration];
        self.microphoneSession = session; self.microphoneOutput = output;
        [session startRunning];
        if (!session.running) [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_CAPTURE_FAILED];
        else [self emitCaptureState:NS_CAPTURE_STARTED reason:NS_REASON_NONE duration:0 bytes:0 committed:NO];
    });
    return 0;
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream; (void)error;
    if (self.active && !self.terminalEmitted) [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_CAPTURE_FAILED];
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    (void)stream; (void)type; [self consumeSampleBuffer:sampleBuffer];
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    (void)output; (void)connection; [self consumeSampleBuffer:sampleBuffer];
}

- (void)consumeSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.active || !CMSampleBufferDataIsReady(sampleBuffer)) return;
    CMAudioFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *asbd = description ? CMAudioFormatDescriptionGetStreamBasicDescription(description) : NULL;
    if (!asbd) return;
    size_t listSize = 0;
    OSStatus sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, &listSize, NULL, 0, NULL, NULL, 0, NULL);
    if (sizeStatus != noErr || listSize == 0) return;
    AudioBufferList *list = malloc(listSize);
    if (!list) { [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_IO_FAILED]; return; }
    CMBlockBufferRef block = NULL;
    OSStatus listStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, NULL, list, listSize, NULL, NULL, 0, &block);
    if (listStatus != noErr) { free(list); return; }
    AVAudioFormat *inputFormat = [[AVAudioFormat alloc] initWithStreamDescription:asbd];
    AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:inputFormat bufferListNoCopy:list deallocator:^(const AudioBufferList *bufferList) {
        (void)bufferList; if (block) CFRelease(block); free(list);
    }];
    if (!input) { if (block) CFRelease(block); free(list); return; }
    input.frameLength = (AVAudioFrameCount)CMSampleBufferGetNumSamples(sampleBuffer);
    AVAudioFormat *outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:self.sampleRate channels:self.channelCount interleaved:NO];
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:outputFormat];
    if (!converter) return;
    AVAudioFrameCount capacity = (AVAudioFrameCount)ceil((double)input.frameLength * self.sampleRate / inputFormat.sampleRate) + 32;
    AVAudioPCMBuffer *converted = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outputFormat frameCapacity:capacity];
    __block BOOL supplied = NO;
    NSError *conversionError = nil;
    AVAudioConverterOutputStatus status = [converter convertToBuffer:converted error:&conversionError withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount requested, AVAudioConverterInputStatus *inputStatus) {
        (void)requested;
        if (supplied) { *inputStatus = AVAudioConverterInputStatus_EndOfStream; return nil; }
        supplied = YES; *inputStatus = AVAudioConverterInputStatus_HaveData; return input;
    }];
    if (status == AVAudioConverterOutputStatus_Error || converted.frameLength == 0) return;
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (!self.hasBasePTS) { self.basePTS = pts; self.hasBasePTS = YES; }
    double offsetSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, self.basePTS));
    uint64_t startFrame = offsetSeconds > 0 ? (uint64_t)llround(offsetSeconds * self.sampleRate) : 0;
    [self mixFloatChannels:converted.floatChannelData frames:converted.frameLength atFrame:startFrame];
}

- (void)mixFloatChannels:(float *const *)channels frames:(AVAudioFrameCount)frames atFrame:(uint64_t)startFrame {
    if (self.mixFD < 0 || frames == 0) return;
    const size_t samples = (size_t)frames * self.channelCount;
    int32_t *mixed = calloc(samples, sizeof(int32_t));
    if (!mixed) { [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_IO_FAILED]; return; }
    const off_t offset = (off_t)(startFrame * self.channelCount * sizeof(int32_t));
    ssize_t readCount = pread(self.mixFD, mixed, samples * sizeof(int32_t), offset);
    if (readCount < 0 && errno != 0) { free(mixed); [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_IO_FAILED]; return; }
    const float gain = self.combined ? 16384.0f : 32767.0f;
    for (AVAudioFrameCount frame = 0; frame < frames; frame++) {
        for (uint8_t channel = 0; channel < self.channelCount; channel++) {
            float sample = channels[channel][frame];
            if (!isfinite(sample)) sample = 0;
            int64_t value = (int64_t)mixed[(size_t)frame * self.channelCount + channel] + (int64_t)lrintf(fmaxf(-1.0f, fminf(1.0f, sample)) * gain);
            mixed[(size_t)frame * self.channelCount + channel] = (int32_t)MAX(INT32_MIN, MIN(INT32_MAX, value));
        }
    }
    if (pwrite(self.mixFD, mixed, samples * sizeof(int32_t), offset) != (ssize_t)(samples * sizeof(int32_t))) {
        free(mixed); [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_IO_FAILED]; return;
    }
    free(mixed);
    self.maxFrame = MAX(self.maxFrame, startFrame + frames);
    self.sampleBufferCount += 1;
}

- (void)stopCapture {
    if (!self.active || self.terminalEmitted) return;
    self.active = NO;
    SCStream *stream = self.screenStream;
    self.screenStream = nil;
    if (stream) {
        [stream stopCaptureWithCompletionHandler:^(NSError *error) {
            (void)error; [self finishWithState:NS_CAPTURE_STOPPED reason:NS_REASON_NONE];
        }];
        return;
    }
    AVCaptureSession *session = self.microphoneSession;
    self.microphoneSession = nil; self.microphoneOutput = nil;
    dispatch_async(self.sampleQueue, ^{ if (session.running) [session stopRunning]; [self finishWithState:NS_CAPTURE_STOPPED reason:NS_REASON_NONE]; });
}

- (BOOL)publishWavBytes:(uint64_t *)bytes duration:(uint64_t *)duration {
    self.publishFailureReason = NS_REASON_IO_FAILED;
    if (self.mixFD < 0 || self.sampleBufferCount == 0 || self.maxFrame == 0) return NO;
    int wavFD = open(self.wavTemporaryPath.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY, 0600);
    if (wavFD < 0) return NO;
    uint64_t dataBytes64 = self.maxFrame * self.channelCount * sizeof(int16_t);
    if (dataBytes64 > UINT32_MAX - 36) { close(wavFD); return NO; }
    uint8_t header[44] = {0};
    memcpy(header, "RIFF", 4); NativeSdkWriteLE32(header + 4, (uint32_t)dataBytes64 + 36); memcpy(header + 8, "WAVEfmt ", 8);
    NativeSdkWriteLE32(header + 16, 16); NativeSdkWriteLE16(header + 20, 1); NativeSdkWriteLE16(header + 22, self.channelCount);
    NativeSdkWriteLE32(header + 24, self.sampleRate); NativeSdkWriteLE32(header + 28, self.sampleRate * self.channelCount * 2);
    NativeSdkWriteLE16(header + 32, self.channelCount * 2); NativeSdkWriteLE16(header + 34, 16); memcpy(header + 36, "data", 4); NativeSdkWriteLE32(header + 40, (uint32_t)dataBytes64);
    if (write(wavFD, header, sizeof(header)) != sizeof(header)) { close(wavFD); return NO; }
    const size_t chunkSamples = 16384;
    int32_t *source = calloc(chunkSamples, sizeof(int32_t));
    int16_t *target = malloc(chunkSamples * sizeof(int16_t));
    if (!source || !target) { free(source); free(target); close(wavFD); return NO; }
    uint64_t remaining = self.maxFrame * self.channelCount;
    off_t inputOffset = 0;
    while (remaining > 0) {
        size_t count = (size_t)MIN((uint64_t)chunkSamples, remaining);
        memset(source, 0, count * sizeof(int32_t));
        ssize_t got = pread(self.mixFD, source, count * sizeof(int32_t), inputOffset);
        if (got < 0) { free(source); free(target); close(wavFD); return NO; }
        for (size_t index = 0; index < count; index++) target[index] = (int16_t)MAX(INT16_MIN, MIN(INT16_MAX, source[index]));
        if (write(wavFD, target, count * sizeof(int16_t)) != (ssize_t)(count * sizeof(int16_t))) { free(source); free(target); close(wavFD); return NO; }
        inputOffset += (off_t)(count * sizeof(int32_t)); remaining -= count;
    }
    free(source); free(target);
    if (fsync(wavFD) != 0) { close(wavFD); return NO; }
    close(wavFD);
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.destinationPath]) {
        self.publishFailureReason = NS_REASON_OUTPUT_EXISTS;
        return NO;
    }
    if (renamex_np(self.wavTemporaryPath.fileSystemRepresentation, self.destinationPath.fileSystemRepresentation, RENAME_EXCL) != 0) {
        if (errno == EEXIST) self.publishFailureReason = NS_REASON_OUTPUT_EXISTS;
        return NO;
    }
    *bytes = 44 + dataBytes64;
    *duration = (self.maxFrame * 1000) / self.sampleRate;
    return YES;
}

- (void)finishWithState:(int)state reason:(int)reason {
    @synchronized (self) {
        if (self.terminalEmitted) return;
        self.terminalEmitted = YES; self.active = NO;
    }
    SCStream *stream = self.screenStream; self.screenStream = nil;
    if (stream) [stream stopCaptureWithCompletionHandler:nil];
    AVCaptureSession *session = self.microphoneSession; self.microphoneSession = nil; self.microphoneOutput = nil;
    dispatch_async(self.sampleQueue, ^{
        if (session.running) [session stopRunning];
        uint64_t bytes = 0, duration = 0;
        BOOL committed = [self publishWavBytes:&bytes duration:&duration];
        if (self.mixFD >= 0) { close(self.mixFD); self.mixFD = -1; }
        if (self.mixTemporaryPath) unlink(self.mixTemporaryPath.fileSystemRepresentation);
        if (!committed && self.wavTemporaryPath) unlink(self.wavTemporaryPath.fileSystemRepresentation);
        int terminalReason = reason;
        if (self.sampleBufferCount == 0 && reason == NS_REASON_NONE) terminalReason = NS_REASON_NO_AUDIO;
        else if (!committed && self.sampleBufferCount > 0 && reason == NS_REASON_NONE) terminalReason = self.publishFailureReason;
        int terminalState = state;
        if (terminalReason != NS_REASON_NONE && state == NS_CAPTURE_STOPPED) terminalState = NS_CAPTURE_FAILED;
        [self emitCaptureState:terminalState reason:terminalReason duration:duration bytes:bytes committed:committed];
        self.destinationPath = nil; self.wavTemporaryPath = nil; self.mixTemporaryPath = nil; self.selectedMicrophoneID = nil;
        if (!self.observingDevices) [self stopDeviceObservers];
        dispatch_semaphore_t semaphore = self.finalizationSemaphore;
        self.finalizationSemaphore = nil;
        if (semaphore) dispatch_semaphore_signal(semaphore);
    });
}

@end

struct native_sdk_audio_capture { void *object; };

native_sdk_audio_capture_t *native_sdk_audio_capture_create(native_sdk_audio_capture_callback_t callback, void *context) {
    native_sdk_audio_capture_t *handle = calloc(1, sizeof(*handle));
    if (!handle) return NULL;
    if (@available(macOS 15.0, *)) {
        NativeSdkAudioCapture *object = [[NativeSdkAudioCapture alloc] initWithCallback:callback context:context];
        if (!object) { free(handle); return NULL; }
        handle->object = (__bridge_retained void *)object;
        return handle;
    }
    free(handle);
    return NULL;
}

void native_sdk_audio_capture_destroy(native_sdk_audio_capture_t *capture) {
    if (!capture) return;
    if (@available(macOS 15.0, *)) {
        NativeSdkAudioCapture *object = (__bridge_transfer NativeSdkAudioCapture *)capture->object;
        object.callback = NULL;
        object.callbackContext = NULL;
        dispatch_semaphore_t semaphore = object.finalizationSemaphore;
        [object stopCapture];
        if (semaphore) {
            (void)dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        }
    }
    free(capture);
}

int native_sdk_audio_capture_start(native_sdk_audio_capture_t *capture, const char *path, size_t path_len, int system_audio, int microphone_kind, const char *microphone_id, size_t microphone_id_len, uint32_t sample_rate_hz, uint8_t channel_count, int exclude_current_process_audio) {
    if (!capture || !capture->object) return 6;
    if (@available(macOS 15.0, *)) {
        NativeSdkAudioCapture *object = (__bridge NativeSdkAudioCapture *)capture->object;
        NSString *pathString = [[NSString alloc] initWithBytes:path length:path_len encoding:NSUTF8StringEncoding];
        NSString *deviceID = [[NSString alloc] initWithBytes:microphone_id length:microphone_id_len encoding:NSUTF8StringEncoding] ?: @"";
        if (!pathString) return 1;
        return [object startPath:pathString systemAudio:(system_audio != 0) microphoneKind:microphone_kind microphoneID:deviceID sampleRate:sample_rate_hz channels:channel_count excludeCurrentProcessAudio:(exclude_current_process_audio != 0)];
    }
    return 6;
}

void native_sdk_audio_capture_stop(native_sdk_audio_capture_t *capture) {
    if (!capture || !capture->object) return;
    if (@available(macOS 15.0, *)) [(__bridge NativeSdkAudioCapture *)capture->object stopCapture];
}

void native_sdk_audio_capture_list_microphones(native_sdk_audio_capture_t *capture) {
    if (!capture || !capture->object) return;
    if (@available(macOS 15.0, *)) {
        NativeSdkAudioCapture *object = (__bridge NativeSdkAudioCapture *)capture->object;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray<AVCaptureDevice *> *devices = NativeSdkMicrophones();
            AVCaptureDevice *defaultDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
            uint32_t total = (uint32_t)MIN((NSUInteger)UINT32_MAX, devices.count);
            [devices enumerateObjectsUsingBlock:^(AVCaptureDevice *device, NSUInteger index, BOOL *stop) {
                (void)stop;
                const char *identifier = device.uniqueID.UTF8String ?: "";
                const char *name = device.localizedName.UTF8String ?: "";
                native_sdk_audio_capture_event_t event = { .kind = NATIVE_SDK_AUDIO_CAPTURE_EVENT_DEVICE, .state = NS_DEVICE,
                    .device_id = identifier, .device_id_len = strlen(identifier), .device_name = name, .device_name_len = strlen(name),
                    .device_is_default = [device.uniqueID isEqualToString:defaultDevice.uniqueID] ? 1 : 0, .device_index = (uint32_t)index, .device_total = total };
                [object emit:event];
            }];
            native_sdk_audio_capture_event_t completed = { .kind = NATIVE_SDK_AUDIO_CAPTURE_EVENT_DEVICE, .state = NS_DEVICES_COMPLETED, .device_index = total, .device_total = total };
            [object emit:completed];
        });
    }
}

void native_sdk_audio_capture_access(native_sdk_audio_capture_t *capture, int source, int action) {
    if (!capture || !capture->object) return;
    if (@available(macOS 15.0, *)) {
        NativeSdkAudioCapture *object = (__bridge NativeSdkAudioCapture *)capture->object;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (source == 0) {
                BOOL before = CGPreflightScreenCaptureAccess();
                BOOL granted = before;
                if (action == 1 && !before) granted = CGRequestScreenCaptureAccess();
                BOOL after = CGPreflightScreenCaptureAccess();
                int status = (before || after || granted) ? NS_ACCESS_AUTHORIZED : NS_ACCESS_NOT_AUTHORIZED;
                native_sdk_audio_capture_event_t event = { .kind = NATIVE_SDK_AUDIO_CAPTURE_EVENT_ACCESS, .access_source = source,
                    .access_status = status, .restart_required = (granted && !after) ? 1 : 0 };
                [object emit:event];
                return;
            }
            AVAuthorizationStatus auth = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
            void (^emitStatus)(AVAuthorizationStatus) = ^(AVAuthorizationStatus value) {
                int status = NS_ACCESS_DENIED;
                switch (value) { case AVAuthorizationStatusAuthorized: status = NS_ACCESS_AUTHORIZED; break;
                    case AVAuthorizationStatusNotDetermined: status = NS_ACCESS_NOT_DETERMINED; break;
                    case AVAuthorizationStatusRestricted: status = NS_ACCESS_RESTRICTED; break;
                    case AVAuthorizationStatusDenied: default: status = NS_ACCESS_DENIED; break; }
                native_sdk_audio_capture_event_t event = { .kind = NATIVE_SDK_AUDIO_CAPTURE_EVENT_ACCESS, .access_source = source, .access_status = status };
                [object emit:event];
            };
            if (action == 1 && auth == AVAuthorizationStatusNotDetermined) {
                [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                    (void)granted; emitStatus([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]);
                }];
            } else emitStatus(auth);
        });
    }
}

void native_sdk_audio_capture_observe_microphones(native_sdk_audio_capture_t *capture, int enabled) {
    if (!capture || !capture->object) return;
    if (@available(macOS 15.0, *)) {
        NativeSdkAudioCapture *object = (__bridge NativeSdkAudioCapture *)capture->object;
        object.observingDevices = enabled != 0;
        if (enabled) [object startDeviceObservers]; else if (!object.active) [object stopDeviceObservers];
    }
}
