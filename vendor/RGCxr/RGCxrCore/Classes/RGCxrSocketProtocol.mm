//
//  RGCxrSocketProtocol.m
//  RGCxrKit
//
//  Created by Ginger on 2025/4/7.
//

#import "RGCxrSocketProtocol.h"
#import "cxr-proto.h"
#import "RCaps+internal.h"

using namespace std;

static id<RGCXRSocketProtocolDelegate> cxrDelegate;


void printLogCallback(const char* format, ...) {
    va_list args;
    va_start(args, format);
    char buffer[1024]; // 假设最大日志长度为 1024，可以根据需要调整
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    if (cxrDelegate != nil && [cxrDelegate respondsToSelector:@selector(onLogWithContent:)]) {
        [cxrDelegate onLogWithContent:[NSString stringWithUTF8String:buffer]];
    }
}

void onResponseCallback(uint32_t reqId, Caps& args) {
    if (cxrDelegate != nil && [cxrDelegate respondsToSelector:@selector(onResponseWithReqId:args:)]) {
        [cxrDelegate onResponseWithReqId:reqId args:[[RCaps alloc] initWithCaps:args]];
    }
}

void onNotifyCallback(const string& cmd, Caps& args) {
    if (cxrDelegate != nil && [cxrDelegate respondsToSelector:@selector(onNotifyWithCmd:args:)]) {
        [cxrDelegate onNotifyWithCmd:[NSString stringWithUTF8String:cmd.c_str()] args:[[RCaps alloc] initWithCaps:args]];
    }
}

void onTransferCallback(const string& cmd, Caps& args, const uint8_t* data, uint32_t totalSize) {
    if (cxrDelegate != nil && [cxrDelegate respondsToSelector:@selector(onTransferWithCmd:args:data:)]) {
        [cxrDelegate onTransferWithCmd:[NSString stringWithUTF8String:cmd.c_str()] args:[[RCaps alloc] initWithCaps:args] data:[NSData dataWithBytes:data length:totalSize]];
    }
}

void onStartAudioStreamCallback(uint32_t ID, uint32_t codec, uint32_t channels, const string& cmd, Caps& args) {
    if (cxrDelegate != nil && [cxrDelegate respondsToSelector:@selector(onStartAudioStreamWithCodec:channels:cmd:args:)]) {
        [cxrDelegate onStartAudioStreamWithCodec:codec channels:channels cmd:[NSString stringWithUTF8String:cmd.c_str()] args:[[RCaps alloc] initWithCaps:args]];
    }
}

void onAudioStreamCallback(uint32_t ID, const uint8_t* data, uint32_t dataSize, uint64_t timestamp) {
    if (cxrDelegate != nil && [cxrDelegate respondsToSelector:@selector(onAudioStreamWithData:timestamp:)]) {
        [cxrDelegate onAudioStreamWithData:[NSData dataWithBytes:data length:dataSize] timestamp:timestamp];
    }
}

void onAudioStreamFinishCallback(uint32_t ID) {
    if (cxrDelegate != nil && [cxrDelegate respondsToSelector:@selector(onAudioStreamFinish)]) {
        [cxrDelegate onAudioStreamFinish];
    }
}

void onSendDataCallback(const uint8_t* data, uint32_t size) {
    if (cxrDelegate != nil && [cxrDelegate respondsToSelector:@selector(onSendDataWithData:)]) {
        [cxrDelegate onSendDataWithData:[NSData dataWithBytes:data length:size]];
    }
}

void onLogCallback(const string& content) {
    if (cxrDelegate != nil && [cxrDelegate respondsToSelector:@selector(onLogWithContent:)]) {
        [cxrDelegate onLogWithContent:[NSString stringWithUTF8String:content.c_str()]];
    }
}

void onAuthResultCallback(int32_t code, uint16_t majorVersion, uint16_t minorVersion,  const string& macAddress) {
    if (cxrDelegate != nil && [cxrDelegate respondsToSelector:@selector(onAuthResultWithErrorCode:majorVersion:minorVersion:macAddress:)]) {
        [cxrDelegate onAuthResultWithErrorCode:code majorVersion:majorVersion minorVersion:minorVersion macAddress:[NSString stringWithUTF8String:macAddress.c_str()]];
    }
}

void onARTCFrameCallback(const uint8_t* frame, uint32_t size, uint64_t timestamp) {
    if (cxrDelegate != nil && [cxrDelegate respondsToSelector:@selector(onARTCFrameWithData:)]) {
        [cxrDelegate onARTCFrameWithData:[NSData dataWithBytes:frame length:size]];
    }
}


@interface RGCxrSocketProtocol () {
    CXRProtocol *socketProtocol;
    CXRProtocol::Callback cb;
}
@end

@implementation RGCxrSocketProtocol

- (instancetype)init
{
    self = [super init];
    if (self) {
        
        logFunc = printLogCallback;
        
        socketProtocol = new CXRProtocol("RGCxrSocketProtocol");
        cb.onResponse = onResponseCallback;
        cb.onNotify = onNotifyCallback;
        cb.onTransfer = onTransferCallback;
        cb.onStartAudioStream = onStartAudioStreamCallback;
        cb.onAudioStream = onAudioStreamCallback;
        cb.onAuthResult = onAuthResultCallback;
        cb.onARTCFrame = onARTCFrameCallback;
        cb.onAudioStreamFinish = onAudioStreamFinishCallback;
        
        socketProtocol->initialize(cb, onSendDataCallback, 500);
    }
    return self;
}

- (void)setDelegate:(id<RGCXRSocketProtocolDelegate>)delegate {
    cxrDelegate = delegate;
}

- (void)verifyWithServiceRecord:(NSString *)serviceRecord extra:(uint32_t)extra {
    socketProtocol->auth(serviceRecord.UTF8String, "", extra);
}

- (void)handleReadPacketWithBuffer:(NSData *)buffer {
    const void *dataPointer = [buffer bytes];
    uint8_t *uint8Pointer = (uint8_t *)dataPointer;
    int32_t res;
    socketProtocol->handleReadPacket(uint8Pointer, (uint32_t)buffer.length, &res);
}

- (int)notifyWithCmd:(NSString *)cmd args:(RCaps *)args {
    socketProtocol->notify(cmd.UTF8String, args.caps, [](){});
    return 0;
}

- (int)requestWithReqId:(NSInteger)reqId cmd:(NSString *)cmd args:(RCaps *)args {
    socketProtocol->request((uint32_t)reqId, cmd.UTF8String, args.caps);
    return 0;
}

- (int)sendStreamWithCmd:(NSString *)cmd args:(RCaps *)args stream:(NSData *)stream {
    const void *dataPointer = [stream bytes];
    uint8_t *uint8Pointer = (uint8_t *)dataPointer;
    socketProtocol->send(cmd.UTF8String, args.caps, uint8Pointer, (uint32_t)stream.length);
    return 0;
}

- (int)openAudioRecordWithCodec:(uint32_t)codec
                           mode:(uint32_t)mode
                         intent:(NSString *)intent
                    denoiseMode:(int)denoiseMode
                   rokidDtlnAEC:(BOOL)rokidDtlnAEC
                        rokidBF:(BOOL)rokidBF {
    CXRProtocol::AudioRecordParam arp;
    arp.denoiseMode = denoiseMode;                 // 0/1/2，其他值走默认(当前默认2)
    arp.rokidDtlnAEC = rokidDtlnAEC ? 1 : 0;       // uint8_t
    arp.rokidBF = rokidBF ? 1 : 0;                 // uint8_t
    socketProtocol->openAudioRecord(codec, mode, intent.UTF8String, arp);
    return 0;
}

- (int)closeAudioRecordWithCmd:(NSString *)cmd {
    socketProtocol->closeAudioRecord(cmd.UTF8String);
    return 0;
}

- (bool)startPlayAudioWithId:(uint32_t)streamId prio:(int32_t)prio speed:(float)speed codec:(uint32_t)codec {
    return socketProtocol->startPlayAudio(streamId, prio, speed, codec);
}

- (int)sendAudioStreamWithId:(NSInteger)streamId data:(NSData *)data {
    const void *dataPointer = [data bytes];
    uint8_t *uint8Pointer = (uint8_t *)dataPointer;
    return socketProtocol->sendAudioStream((uint32_t)streamId, uint8Pointer, (uint32_t)data.length);
}

- (void)cancelAudioPlayWithId:(NSInteger)streamId {
    socketProtocol->cancelAudioPlay((uint32_t)streamId);
}

- (void)finishAudioStreamWithId:(NSInteger)streamId {
    socketProtocol->finishAudioStream((uint32_t)streamId);
}

- (void)changeRokidAccount:(NSString *)account {
    socketProtocol->changeRokidAccount(account.UTF8String);
}

- (int)close {
    socketProtocol->close();
    return 0;
}

- (void)disconnectGATT {
    socketProtocol->disconnect();
}

@end
