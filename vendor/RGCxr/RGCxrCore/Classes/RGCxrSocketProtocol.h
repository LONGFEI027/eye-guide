//
//  RGCxrSocketProtocol.h
//  RGCxrKit
//
//  Created by Ginger on 2025/4/7.
//

#import <Foundation/Foundation.h>
#import "RCaps.h"

NS_ASSUME_NONNULL_BEGIN

@protocol RGCXRSocketProtocolDelegate <NSObject>

- (void)onResponseWithReqId:(NSInteger)reqId args:(RCaps *)args;
- (void)onNotifyWithCmd:(NSString *)cmd args:(RCaps *)args;
- (void)onTransferWithCmd:(NSString *)cmd args:(RCaps *)args data:(NSData *)data;
- (void)onStartAudioStreamWithCodec:(int32_t)codec channels:(uint32_t)channels cmd:(NSString *)cmd args:(RCaps *)args;
- (void)onAudioStreamWithData:(NSData *)data timestamp:(uint64_t)timestamp;
- (void)onAudioStreamFinish;
- (void)onSendDataWithData:(NSData *)data;
- (void)onLogWithContent:(NSString *)content;
- (void)onAuthResultWithErrorCode:(NSInteger)code majorVersion:(NSInteger)majorVersion minorVersion:(NSInteger)minorVersion macAddress:(nullable NSString *)address;
- (void)onARTCFrameWithData:(NSData *)frameData;
@end

@interface RGCxrSocketProtocol : NSObject

// 存成static的，用于接收cpp的回调
@property (nonatomic, strong) id<RGCXRSocketProtocolDelegate> delegate;

/// socket握手
/// - Parameters:
///   - serviceRecord: 校验uuid
///   - extra: 194: RokidAI国内版 195: Hi Rokid海外版
- (void)verifyWithServiceRecord:(NSString *)serviceRecord extra:(uint32_t)extra;

/// 解析收到的Socket数据
/// - Parameter buffer: 数据
- (void)handleReadPacketWithBuffer:(NSData *)buffer;

/// APP主动通知眼镜，不需要眼镜返回数据
/// - Parameters:
///   - cmd: 命令
///   - args: 参数
- (int)notifyWithCmd:(NSString *)cmd args:(RCaps *)args;

/// APP请求眼镜数据
/// - Parameters:
///   - reqId: 请求id
///   - cmd: 命令
///   - args: 参数
- (int)requestWithReqId:(NSInteger)reqId cmd:(NSString *)cmd args:(RCaps *)args;

/// APP发送数据流给眼镜
/// - Parameters:
///   - cmd: 命令
///   - args: 参数
///   - stream: 数据
- (int)sendStreamWithCmd:(NSString *)cmd args:(RCaps *)args stream:(NSData *)stream;

/// 开启眼镜音频采集
/// 翻译全向： mode3，rokidDtlnAEC=false，rokidBF=false；
/// 字幕：mode6，rokidDtlnAEC=false，rokidBF=true；
/// - Parameters:
///   - codec: 音频编码
///   - cmd:
///   - denoiseMode:  0 - 弱降噪，保语音，适用于声纹等对语音质量要求高场景;
///                    1 - 中降噪
///                    2 - 强降噪
- (int)openAudioRecordWithCodec:(uint32_t)codec
                           mode:(uint32_t)mode
                         intent:(NSString *)intent
                    denoiseMode:(int)denoiseMode
                   rokidDtlnAEC:(BOOL)rokidDtlnAEC
                        rokidBF:(BOOL)rokidBF;

/// 停止眼镜音频采集
- (int)closeAudioRecordWithCmd:(NSString *)cmd;

/// 通知眼镜开始接收音频
- (bool)startPlayAudioWithId:(uint32_t)streamId prio:(int32_t)prio speed:(float)speed codec:(uint32_t)codec;

/// 发送音频给眼镜播放
- (int)sendAudioStreamWithId:(NSInteger)streamId data:(NSData *)data;

/// 停止眼镜音频播放
/// - Parameter streamId: 音频流id
- (void)cancelAudioPlayWithId:(NSInteger)streamId;

/// 告知眼镜音频发送完成了
/// - Parameter streamId: 音频流id
- (void)finishAudioStreamWithId:(NSInteger)streamId;

/// 变更眼镜的绑定账号
/// - Parameter account: 账号
- (void)changeRokidAccount:(NSString *)account;

/// 关闭
- (int)close;

/// 断开GATT
- (void)disconnectGATT;

@end

NS_ASSUME_NONNULL_END
