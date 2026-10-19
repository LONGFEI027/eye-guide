#pragma once

#include <inttypes.h>
#include <stdint.h>
#include <time.h>
#include <sys/mman.h>
#include <string>
#include <map>
#include <chrono>
#include <functional>
#include <list>
#include <mutex>
#include <condition_variable>
#include <vector>
#include "caps.h"
#include "thr-pool.h"
#include "artc-frame.h"
#include "cxr-config.h"
#include "audio-proc.h"

using namespace std;
using namespace std::chrono;
using namespace rokid;

class CXRProtocol {
public:
  typedef function<void()> NotifyConfirm;

  class ClientInfo {
  public:
    // -1: disconnected
    // 0: connected, inactive
    // 1: connected, active
    int32_t status;
    string mac;
    string customInfo;

    ClientInfo() : status{-1} {}

    ClientInfo(int32_t st, const string& m, const string& i)
      : status{st}, mac{m}, customInfo{i} {}
  };

  class AudioRecordParam {
  public:
    //~~ 适用蚂蚁近场sdk
    ///                    0 - 弱降噪，保语音，适用于声纹等对语音质量要求高场景;
    ///                    1 - 中降噪
    ///                    2 - 强降噪
    ///             <0 or >2 - 使用默认值, 当前默认值为2
    int32_t denoiseMode{2};

    //~~ 适用于rokid自研sdk
    // 开关: dtln抑制残留回声
    uint8_t rokidDtlnAEC{false};
    // 开关: 波束-消除佩戴者声音
    uint8_t rokidBF{false};
  };

private:
  typedef function<int32_t(Caps&)> CmdHandler;
  /// PacketHandler恰好和CmdHandler是一样类型
  typedef CmdHandler PacketHandler;

  class ShortMessage {
  public:
    virtual ~ShortMessage() = default;
    virtual void createPack(Caps& out) = 0;
    virtual const char* type() const = 0;

    // 此消息支持的cxr proto最小版本
    uint16_t minProtoMinorVersion{0};
  };

  class Request : public ShortMessage {
  public:
    Request() {}

    Request(uint32_t id, const string& c, Caps& a) {
      reqid = id;
      cmd = c;
      args = move(a);
    }

    bool create(Caps& pack) {
      try {
        reqid = pack[1];
        cmd = (const string&)pack[2];
        args = pack[3];
      } catch (exception& e) {
        return false;
      }
      return true;
    }

    void createPack(Caps& out) {
      out << CXR_CMD_REQUEST;
      out << reqid;
      out << cmd;
      out << args;
    }

    const char* type() const {
      return "request";
    }

  public:
    uint32_t reqid{0};
    string cmd;
    Caps args;
  };

  class Response : public ShortMessage {
  public:
    Response() {}

    Response(uint32_t id, Caps& a) {
      reqid = id;
      args = move(a);
    }

    bool create(Caps& pack) {
      try {
        reqid = pack[1];
        args = pack[2];
      } catch (exception& e) {
        return false;
      }
      return true;
    }

    void createPack(Caps& out) {
      out << CXR_CMD_RESPONSE;
      out << reqid;
      out << args;
    }

    const char* type() const {
      return "response";
    }

  public:
    uint32_t reqid{0};
    Caps args;
  };

  class Notify : public ShortMessage {
  public:
    Notify() {}

    Notify(const string& c, Caps& a, NotifyConfirm cb) {
      cmd = c;
      args = move(a);
      confirm = cb;
    }

    bool create(Caps& pack) {
      try {
        cmd = (const string&)pack[1];
        args = pack[2];
      } catch (exception& e ) {
        return false;
      }
      return true;
    }

    void createPack(Caps& out) {
      out << CXR_CMD_NOTIFY;
      out << cmd;
      out << args;
    }

    const char* type() const {
      return "notify";
    }

  public:
    string cmd;
    Caps args;
    NotifyConfirm confirm;
  };

  class AuthRequest : public ShortMessage {
  public:
    AuthRequest() {}

    AuthRequest(uint16_t major, uint16_t minor, const char* svcrec,
        const char* info, uint32_t extra) {
      majorVersion = major;
      minorVersion = minor;
      if (svcrec)
        serviceRecord = svcrec;
      if (info)
        customInfo = info;
      extraType = extra;
    }

    bool create(Caps& pack) {
      try {
        majorVersion = pack[1];
        minorVersion = pack[2];
        if (pack.size() > 3)
          serviceRecord = (const string&)pack[3];
        if (pack.size() > 4)
          clientTime = pack[4];
        if (pack.size() > 5)
          extraType = pack[5];
        if (pack.size() > 6)
          customInfo = (const string&)pack[6];
      } catch (exception& e) {
        return false;
      }
      return true;
    }

    void createPack(Caps& out) {
      out << CXR_CMD_AUTH_REQ;
      out << majorVersion;
      out << minorVersion;
      out << serviceRecord;
      auto dur = system_clock::now().time_since_epoch();
      out << (uint64_t)duration_cast<nanoseconds>(dur).count();
      out << extraType;
      out << customInfo;
    }

    const char* type() const {
      return "authRequest";
    }

  public:
    uint16_t majorVersion;
    uint16_t minorVersion;
    string serviceRecord;
    string customInfo;
    uint64_t clientTime{0};
    uint32_t extraType{0};
  };

  class AuthResponse : public ShortMessage {
  public:
    AuthResponse() {}

    AuthResponse(uint16_t major, uint16_t minor, int32_t r,
        const string& mac) {
      majorVersion = major;
      minorVersion = minor;
      retCode = r;
      clientMac = mac;
    }

    bool create(Caps& pack) {
      try {
        majorVersion = pack[1];
        minorVersion = pack[2];
        if (pack.size() > 3)
          retCode = pack[3];
        if (pack.size() > 4)
          clientMac = (const string&)pack[4];
      } catch (exception& e) {
        return false;
      }
      return true;
    }

    void createPack(Caps& out) {
      out << CXR_CMD_AUTH_RESP;
      out << majorVersion;
      out << minorVersion;
      out << retCode;
      out << clientMac;
    }

    const char* type() const {
      return "authResponse";
    }

  public:
    uint16_t majorVersion{0};
    uint16_t minorVersion{0};
    // 0: 认证成功, 活动连接
    // 1: 认证成功, 非活动连接
    // <0: 认证失败
    int32_t retCode{-1};
    string clientMac;
  };

  class RokidAccountRequest : public ShortMessage {
  public:
    RokidAccountRequest() {}

    explicit RokidAccountRequest(const string& acc) {
      account = acc;
    }

    bool create(Caps& pack) {
      try {
        account = (const string&)pack[1];
      } catch (exception& e) {
        return false;
      }
      return true;
    }

    void createPack(Caps& out) {
      out << CXR_CMD_CHANGE_ROKID_ACCOUNT;
      out << account;
    }

    const char* type() const {
      return "changeRokidAccount";
    }

  public:
    string account;
  };

  class DisconnectRequest : public ShortMessage {
  public:
    void createPack(Caps& out) {
      out << CXR_CMD_DISCONNECT;
    }

    const char* type() const {
      return "disconnect";
    }
  };

  class TransferInfo {
  public:
    TransferInfo(const string& c, Caps& a, uint8_t* d, uint32_t s) {
      cmd = c;
      args = move(a);
#ifdef CXR_PLATFORM_APPLE
      if (s > 0) {
        data = new uint8_t[s];
        memcpy(data, d, s);
      } else
        data = nullptr;
#else
      data = d;
#endif
      dataSize = s;
      writePos = 0;
      firstSend = 1;
    }

    ~TransferInfo() {
      if (data)
        delete[] data;
    }

    int32_t createPack(Caps& out) {
      if (firstSend) {
        firstSend = 0;
        out << CXRProtocol::CXR_CMD_TRANSFER_START;
        out << dataSize;
        out << cmd;
        out << args;
        return dataSize ? 2 : 0;
      }
      uint32_t packSize{MAX_PACKET_SIZE};
      auto remain = dataSize - writePos;
      if (remain == 0)
        return -1;
      if (packSize > remain)
        packSize = remain;
      if (writePos + packSize == dataSize)
        out << CXRProtocol::CXR_CMD_TRANSFER_LAST;
      else
        out << CXRProtocol::CXR_CMD_TRANSFER;
      out.write(data + writePos, packSize);
      writePos += packSize;
      return dataSize > writePos;
    }
      
    const char* getCommand() const {
      return cmd.c_str();
    }
      
    uint32_t remainBytes() const {
      return dataSize - writePos;
    }
      
    static constexpr uint32_t MAX_PACKET_SIZE = 480;

  private:
    string cmd;
    Caps args;
    uint8_t* data;
    uint32_t dataSize;
    uint32_t writePos:31;
    uint32_t firstSend:1;
  };

  class RecvTransfer {
  public:
    ~RecvTransfer() {
      if (data)
        delete[] data;
    }

    int32_t create(Caps& pack) {
      totalSize = pack[1];
      cmd = (const string&)pack[2];
      args = pack[3];
      if (totalSize == 0)
        data = nullptr;
      else
        data = new uint8_t[totalSize];
      writePos = 0;
      return 0;
    }

    int32_t write(Caps& pack, bool isLast) {
      auto size = pack[1].size();
      if (isLast) {
        if (writePos + size != totalSize) {
          KLOGE("cxr-client", "RecvTransfer incorrect size: recv bytes %u/%u",
              writePos + size, totalSize);
          return -102;
        }
      } else {
        if (writePos + size >= totalSize)
          return -103;
      }
      pack[1].read(data + writePos, size);
      writePos += size;
      return 0;
    }

  public:
    uint32_t totalSize{0};
    string cmd;
    Caps args;
    uint8_t* data;

  private:
    uint32_t writePos{0};
  };

  class AudioStreamBase {
  public:
    class AudioPacket {
    public:
      AudioPacket(const uint8_t* d, uint32_t s, uint64_t ts) {
        if (s) {
          data = new uint8_t[s];
          memcpy(data, d, s);
        } else
          data = nullptr;
        size = s;
        timestamp = ts;
      }

      ~AudioPacket() {
        if (data)
          delete[] data;
      }

      uint8_t* data;
      uint32_t size;
      uint64_t timestamp;
    };

    virtual ~AudioStreamBase() = default;
    /**
    virtual ~AudioStreamBase() {
      destroy();
    }
    */

    /**
    void init(uint32_t size) {
      if (size != audioBufsize)
        destroy();
      if (audioData == nullptr) {
        auto ptr = mmap(nullptr, size, PROT_WRITE | PROT_READ,
            MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
        if (ptr == (void*)-1)
          return;
        audioData = (uint8_t*)ptr;
        audioBufsize = size;
      }
    }
    */

    /**
    void destroy() {
      if (audioData) {
        munmap(audioData, audioBufsize);
        audioData = nullptr;
        audioBufsize = 0;
      }
    }
    */

    virtual int32_t write(const void* data, uint32_t size, uint64_t ts) {
      if (data == nullptr || size == 0)
        return -1;
      audioPackets.emplace_back((const uint8_t*)data, size, ts);
      return 0;
      /**
      if (writePos + size > audioBufsize)
        return -202;
      memcpy(audioData + writePos, data, size);
      writePos += size;
      return 0;
      */
    }

    /**
    inline uint32_t size() const {
      return writePos;
    }

    inline uint32_t capacity() const {
      return audioBufsize;
    }
    */

    int32_t read(void* out, uint32_t bufsize, uint64_t* timestamp) {
      /**
      uint32_t cpsz;
      if (writePos > bufsize)
        cpsz = bufsize;
      else
        cpsz = writePos;
      if (cpsz > 0) {
        memcpy(out, audioData, cpsz);
        if (cpsz < writePos)
          memmove(audioData, audioData + cpsz, writePos - cpsz);
        writePos -= cpsz;
      }
      return cpsz;
      */
      if (audioPackets.empty())
        return 0;
      auto it = audioPackets.begin();
      auto cpsz = it->size;
      if (cpsz > bufsize)
        cpsz = bufsize;
      memcpy(out, it->data, cpsz);
      if (timestamp)
        timestamp[0] = it->timestamp;
      audioPackets.erase(it);
      return cpsz;
    }

    int32_t read(Caps& out, uint32_t maxSize, uint64_t* timestamp) {
      /**
      uint32_t cpsz;
      if (writePos > maxSize)
        cpsz = maxSize;
      else
        cpsz = writePos;
      if (cpsz > 0) {
        out.write(audioData, cpsz);
        if (cpsz < writePos)
          memmove(audioData, audioData + cpsz, writePos - cpsz);
        writePos -= cpsz;
      }
      return cpsz;
      */
      if (audioPackets.empty())
        return 0;
      auto it = audioPackets.begin();
      auto cpsz = it->size;
      if (cpsz > maxSize)
        cpsz = maxSize;
      out.write(it->data, cpsz);
      if (timestamp)
        timestamp[0] = it->timestamp;
      audioPackets.erase(it);
      return cpsz;
    }

    inline void clear() {
      audioPackets.clear();
    }

    inline bool empty() const {
      // return writePos == 0;
      return audioPackets.empty();
    }
      
    inline uint32_t audioPacketCount() const {
      return audioPackets.size();
    }
      
  protected:
    /**
    uint8_t* audioData{nullptr};
    uint32_t audioBufsize{0};
    uint32_t writePos{0};
    */
    list<AudioPacket> audioPackets;
  };

  class SendAudioStream : public AudioStreamBase {
  public:
    SendAudioStream(const char* tag, uint16_t major, uint16_t minor) {
      TAG = tag;
      majorVersion = major;
      minorVersion = minor;
      oggCallback = [this](const uint8_t* data, uint32_t size) {
        writeRet = writeWithMTU(data, size, curTimestamp);
      };
      activeTime = system_clock::now();
    }

    void start(uint32_t id, uint32_t codec, uint32_t chn, const string& intent,
        Caps& args, bool autoEncode) {
      streamId = id;
      audioIntent = intent;
      audioArgs = move(args);
      audioChannels = chn;
      startFlag = 1;
      if (oggEncoder) {
        delete oggEncoder;
        oggEncoder = nullptr;
      }
      uint32_t tcodec;
      if (autoEncode)
        tcodec = getTransferCodec(codec);
      else
        tcodec = codec;
      if (codec != tcodec) {
        KLOGI(TAG, "SendAudioStream auto encode ogg-opus: originCodec %u, transferCodec %u",
            codec, tcodec);
        originAudioCodec = codec;
        audioCodec = tcodec;
        oggEncoder = new OggEncodeProcessor(30, chn);
        oggEncoder->setOutput(oggCallback);
      } else {
        originAudioCodec = codec;
        audioCodec = codec;
      }
    }

    void stop() {
      stopFlag = 1;
      if (oggEncoder)
        oggEncoder->finish();
    }

    int32_t write(const void* data, uint32_t size, uint64_t timestamp) {
      activeTime = system_clock::now();
      if (oggEncoder) {
        curTimestamp = timestamp;
        writeRet = 0;
        oggEncoder->process((const uint8_t*)data, size);
        return writeRet;
      }
      return writeWithMTU((const uint8_t*)data, size, timestamp);
    }

    bool empty() const {
      return startFlag + stopFlag == 0 && AudioStreamBase::empty();
    }

    bool isMatch(uint32_t id) const {
      return id == streamId;
    }

    bool isFinished() const {
      return finishFlag;
    }

    bool isTimeout() const {
      auto nowtp = system_clock::now();
      auto t = duration_cast<std::chrono::seconds>(nowtp - activeTime);
      return t.count() >= TIMEOUT_SEC;
    }

    uint32_t getId() const {
      return streamId;
    }

    int32_t createPack(Caps& out) {
      int32_t res{0};
      if (startFlag) {
        if (minorVersion <= 5) {
          Caps empty;
          int32_t priority{0};
          float playbackSpeed{1.0};
          if (audioArgs.size() > 0)
            priority = audioArgs[0];
          if (audioArgs.size() > 1)
            playbackSpeed = audioArgs[1];
          out << CXRProtocol::CXR_CMD_START_AUDIO_STREAM;
          out << audioCodec;
          out << audioIntent;
          out << empty;
          out << streamId;
          out << priority;
          out << playbackSpeed;
          out << originAudioCodec;
        } else {
          out << CXRProtocol::CXR_CMD_START_AUDIO_STREAM;
          out << audioCodec;
          out << audioIntent;
          out << audioArgs;
          out << streamId;
          out << originAudioCodec;
          out << audioChannels;
        }
        startFlag = 0;
        res = 1;
      } else if (!AudioStreamBase::empty()) {
        uint64_t timestamp;
        out << CXRProtocol::CXR_CMD_AUDIO_STREAM;
        AudioStreamBase::read(out, CXRConfig::audio.send_audio_stream_mtu, &timestamp);
        out << streamId;
        out << timestamp;
        res = 2;
      } else if (stopFlag) {
        out << CXRProtocol::CXR_CMD_AUDIO_STREAM_FINISH;
        out << streamId;
        stopFlag = 0;
        finishFlag = 1;
        res = 3;
      }
      if (res)
        activeTime = system_clock::now();
      return res;
    }

    void clear() {
      AudioStreamBase::clear();
      startFlag = 0;
      stopFlag = 0;
      finishFlag = 0;
    }

  private:
    int32_t writeWithMTU(const uint8_t* data, uint32_t size, uint64_t timestamp) {
      uint32_t off{0};
      uint32_t remain;
      uint32_t wsz;
      int32_t r{0};
      while (off < size) {
        remain = size - off;
        if (remain > CXRConfig::audio.send_audio_stream_mtu)
          wsz = CXRConfig::audio.send_audio_stream_mtu;
        else
          wsz = remain;
        r = AudioStreamBase::write(data + off, wsz, timestamp);
        if (r < 0)
          break;
        off += wsz;
      }
      return r;
    }

    uint32_t getTransferCodec(uint32_t codec) {
      auto tcodec{codec};
      if (isProtoCompatible()) {
        if (codec == CXR_AUDIO_CODEC_PCM)
          tcodec = CXR_AUDIO_CODEC_OGGOPUS;
      }
      return tcodec;
    }

    // remote protocol version 1.5以上才支持codec 3, 5的自动解码
    inline bool isProtoCompatible() {
      return majorVersion == 1 && minorVersion >= 5;
    }

  private:
    uint32_t streamId{0};
    uint32_t audioCodec{0};
    uint32_t audioChannels{1};
    string audioIntent;
    Caps audioArgs;
    uint32_t originAudioCodec{0};
    uint8_t startFlag{0};
    uint8_t stopFlag{0};
    uint8_t finishFlag{0};
    uint16_t majorVersion;
    uint16_t minorVersion;
    const char* TAG;
    OggEncodeProcessor* oggEncoder{nullptr};
    AudioCallback oggCallback;
    system_clock::time_point activeTime;
    int32_t writeRet;
    uint64_t curTimestamp;
    static constexpr uint32_t TIMEOUT_SEC = 15;
  };

  class RecvAudioStream : public AudioStreamBase {
  public:
    RecvAudioStream(const char* tag) {
      TAG = tag;
      oggCallback = [this](const uint8_t* data, uint32_t size) {
        writeRet = AudioStreamBase::write(data, size, curTimestamp);
      };
      activeTime = system_clock::now();
    }

    void start(uint32_t id, uint32_t codec, uint32_t chn, const string& intent,
        Caps& args, uint32_t originCodec) {
      streamId = id;
      audioCodec = originCodec;
      audioIntent = intent;
      audioArgs = move(args);
      audioChannels = chn;
      startFlag = 1;
      if (oggDecoder) {
        delete oggDecoder;
        oggDecoder = nullptr;
      }
      if (codec != originCodec) {
        KLOGI(TAG, "RecvAudioStream auto decode ogg-opus: originCodec %u, transferCodec %u",
            originCodec, codec);
        oggDecoder = new OggDecodeProcessor(chn);
        oggDecoder->setOutput(oggCallback);
      }
    }

    void stop() {
      stopFlag = 1;
    }

    int32_t write(const void* data, uint32_t size, uint64_t timestamp) {
      activeTime = system_clock::now();
      if (oggDecoder) {
        curTimestamp = timestamp;
        oggDecoder->process((const uint8_t*)data, size);
        return writeRet;
      }
      return AudioStreamBase::write(data, size, timestamp);
    }

    void clearStartFlag() {
      startFlag = 0;
    }

    void clear() {
      AudioStreamBase::clear();
      startFlag = 0;
      stopFlag = 0;
    }

    inline bool isStart() const {
      return startFlag;
    }

    inline bool isStop() const {
      return stopFlag;
    }

    inline bool empty() const {
      return !startFlag && !stopFlag && AudioStreamBase::empty();
    }

    inline bool isMatch(uint32_t id) const {
      return streamId == id;
    }

    bool isTimeout() const {
      auto nowtp = system_clock::now();
      auto t = duration_cast<std::chrono::seconds>(nowtp - activeTime);
      return t.count() >= TIMEOUT_SEC;
    }

  public:
    uint32_t streamId{0};
    uint32_t audioCodec{0};
    uint32_t audioChannels{1};
    string audioIntent;
    Caps audioArgs;

  private:
    uint8_t startFlag{0};
    uint8_t stopFlag{0};
    AudioCallback oggCallback;
    OggDecodeProcessor* oggDecoder{nullptr};
    system_clock::time_point activeTime;
    const char* TAG;
    int32_t writeRet;
    uint64_t curTimestamp;
    static constexpr uint32_t TIMEOUT_SEC = 15;
  };

  class ActiveRequest : public ShortMessage {
  public:
    ActiveRequest() {
      // cxr proto最低1.9
      minProtoMinorVersion = 9;
    }

    explicit ActiveRequest(const string& m) : mac{m} {}

    void createPack(Caps& out) {
      out << CXR_CMD_ACTIVE_REQ;
      auto dur = system_clock::now().time_since_epoch();
      out << (uint64_t)duration_cast<nanoseconds>(dur).count();
      out << mac;
    }

    void create(Caps& pack, uint16_t majorVersion, uint16_t minorVersion) {
      clientTime = pack[1];
      if (minorVersion >= 10)
        mac = (const string&)pack[2];
    }

    const char* type() const {
      return "active";
    }

    string mac;
    uint64_t clientTime;
  };

  class ActiveStatusNotify : public ShortMessage {
  public:
    explicit ActiveStatusNotify(int32_t st, const string& m, const string& c)
      : status{st}, mac{m}, customInfo{c} {
      minProtoMinorVersion = 9;
    }

    ActiveStatusNotify() {}

    void createPack(Caps& out) {
      out << CXR_CMD_ACTIVE_NOTIFY;
      out << status;
      out << mac;
      out << customInfo;
    }

    void create(Caps& pack, uint16_t majorVersion, uint16_t minorVersion) {
      status = pack[1];
      if (minorVersion >= 10) {
        mac = (const string&)pack[2];
        customInfo = (const string&)pack[3];
      }
    }

    const char* type() const {
      return "activeStatusNotify";
    }

    int32_t status{0};
    string mac;
    string customInfo;
  };

  class ClientListReq : public ShortMessage {
  public:
    ClientListReq() {
      minProtoMinorVersion = 11;
    }

    explicit ClientListReq(uint32_t id) {
      reqid = id;
      minProtoMinorVersion = 11;
    }

    void createPack(Caps& out) {
      out << CXR_CMD_CLIENT_LIST_REQ;
      out << reqid;
    }

    void create(Caps& pack) {
      reqid = pack[1];
    }

    const char* type() const {
      return "ClientListReq";
    }

    uint32_t reqid{0};
  };

  class ClientListResp : public ShortMessage {
  public:
    ClientListResp() {
      minProtoMinorVersion = 11;
    }

    ClientListResp(uint32_t id, vector<ClientInfo>&& clis) {
      minProtoMinorVersion = 11;
      reqid = id;
      clientInfos = clis;
    }

    void createPack(Caps& out) {
      out << CXR_CMD_CLIENT_LIST_RESP;
      out << reqid;
      Caps info;
      Caps arr;
      for (size_t i = 0; i < clientInfos.size(); ++i) {
        info.clear();
        info << clientInfos[i].status;
        info << clientInfos[i].mac;
        info << clientInfos[i].customInfo;
        arr << info;
      }
      out << arr;
    }

    void create(Caps& pack) {
      reqid = pack[1];
      Caps arr = pack[2];
      Caps info;
      int32_t status;
      string mac;
      string customInfo;
      for (uint32_t i = 0; i < arr.size(); ++i) {
        info = arr[i];
        status = info[0];
        mac = (const string&)info[1];
        customInfo = (const string&)info[2];
        clientInfos.emplace_back(status, mac, customInfo);
      }
    }

    const char* type() const {
      return "ClientListResp";
    }

    uint32_t reqid;
    vector<ClientInfo> clientInfos;
  };

  class RemoveClientReq : public ShortMessage {
  public:
    RemoveClientReq() {
      minProtoMinorVersion = 12;
    }

    RemoveClientReq(uint32_t id, const string& mac) {
      reqid = id;
      targetMac = mac;
      minProtoMinorVersion = 12;
    }

    void createPack(Caps& out) {
      out << CXR_CMD_REMOVE_CLIENT_REQ;
      out << reqid;
      out << targetMac;
    }

    void create(Caps& pack) {
      reqid = pack[1];
      targetMac = (const string&)pack[2];
    }

    const char* type() const {
      return "RemoveClientReq";
    }

    uint32_t reqid{0};
    string targetMac;
  };

  class RemoveClientResp : public ShortMessage {
  public:
    RemoveClientResp() {
      minProtoMinorVersion = 12;
    }

    RemoveClientResp(uint32_t id, int32_t res, const string& mac) {
      minProtoMinorVersion = 12;
      reqid = id;
      result = res;
      targetMac = mac;
    }

    void createPack(Caps& out) {
      out << CXR_CMD_REMOVE_CLIENT_RESP;
      out << reqid;
      out << result;
      out << targetMac;
    }

    void create(Caps& pack) {
      reqid = pack[1];
      result = pack[2];
      targetMac = (const string&)pack[3];
    }

    const char* type() const {
      return "RemoveClientResp";
    }

    uint32_t reqid;
    int32_t result{0};
    string targetMac;
  };

public:
  class Callback {
  public:
#ifdef CXR_SERVER_SIDE
    // uint16_t majorVersion
    // uint16_t minorVersion
    // string serviceRecord
    // string customInfo
    // uint64_t clientTime
    // uint32_t extraType
    /// \return 0: 认证成功, inactive
    ///         1: 认证成功, active
    ///        <0: 认证失败
    function<int32_t(uint16_t, uint16_t, const string&, const string&, uint64_t, uint32_t)> onAuthorize;
    // server side
    function<void(uint32_t, const string&, Caps&)> onRequest;
    // server side
    function<void(float, bool)> onARTCStatus;
    // server side
    function<void(const string&)> onRokidAccountChanged;
    /// \param 0 clientTime
    /// \param 1 target client mac address
    function<int32_t(uint64_t, const string&)> onActiveReq;
    function<void(vector<ClientInfo>&)> onClientListReq;
    function<int32_t(const string&)> onRemoveClientReq;
#else
    // client side
    function<void(uint32_t, Caps&)> onResponse;
    // client side
    function<void(const string&, Caps&)> onNotify;
    // client side
    function<void(const uint8_t*, uint32_t size, uint64_t)> onARTCFrame;
    // client side
    /// \param 0 result code
    /// \param 1 service protocol major version
    /// \param 2 service protocol minor version
    /// \param 3 client bluetooth mac address
    function<void(int32_t, uint16_t, uint16_t, const string&)> onAuthResult;
    /// \param 0 status
    /// \param 1 client mac address
    /// \param 2 client custom info
    function<void(int32_t, const string&, const string&)> onActiveStatus;
    function<void(const vector<ClientInfo>&)> onClientListResp;
    /// \brief 删除客户端信息的结果
    ///
    /// (int32_t result, const string& mac)
    /// \param result 0 成功
    ///              -2 未找到mac指定客户端信息
    ///              -3 无权删除: 本连接非活动状态或删除的目标是活动状态
    ///              -4 不可删除配对的手机设备
    /// \param mac 被删除的客户端设备mac地址
    function<void(int32_t, const string&)> onRemoveClientResult;
#endif
    // both side
    function<void(const string&, Caps&, const uint8_t*, uint32_t)> onTransfer;
    // both side
    /// \param 0 id
    /// \param 1 codec
    /// \param 2 channels
    /// \param 3 intent
    /// \param 4 custom args
    function<void(uint32_t, uint32_t, uint32_t, const string&, Caps&)> onStartAudioStream;
    // both side
    /// \param 0 id
    /// \param 1 audioData
    /// \param 2 audioDataSize
    /// \param 3 timestamp
    function<void(uint32_t, const uint8_t*, uint32_t, uint64_t)> onAudioStream;
    // both side
    /// \param 0 id
    function<void(uint32_t)> onAudioStreamFinish;
  };
  // both side
  typedef function<void(const uint8_t*, uint32_t)> FragmentCallback;

  CXRProtocol(const char* tag) {
    TAG = tag;
/// android在JNI_OnLoad中初始化CXRConfig
/// ios没有合适的地方初始化, 暂时在CXRProtocol构造时初始化CXRConfig
#ifdef __APPLE__
    if (!CXRConfig::ready())
      CXRConfig::initialize(nullptr);
#endif
    initBuffers();
    initTasks();
    initHandlers();
  }

  virtual ~CXRProtocol() {
    releaseBuffers();
  }

  void initialize(Callback& cb, FragmentCallback frag, uint32_t mtuv) {
    callback = cb;
    onSendFragment = frag;
    mtu = mtuv;
    if (sending == 0) {
      sending = 1;
      thrPool.push(sendTask);
      receiving = 1;
      thrPool.push(callbackTask);
#ifdef CXR_SERVER_SIDE
      thrPool.push(artcStatusTask);
#endif
    }
  }

  void close() {
    stopSendTask();
    stopCallbackTask();
    thrPool.finish();
  }

  void clear() {
    sendMutex.lock();
    clearSendData();
    sendMutex.unlock();
    recvMutex.lock();
    clearRecvData();
    recvMutex.unlock();
  }

  /// \brief 客户端发起CXR认证
  ///
  /// \param serviceRecord CXR服务uuid
  /// \param extra iphone客户端额外信息
  ///              0: 未知(android客户端传0)
  ///              194: RokidAI国内版
  ///              195: Hi Rokid海外版
  void auth(const char* serviceRecord, const char* customInfo, uint32_t extra = 0) {
    lock_guard<mutex> locker{sendMutex};
    if (sending) {
      shortMessages.push_back(new AuthRequest(CXR_PROTO_MAJOR_VERSION,
            CXR_PROTO_MINOR_VERSION, serviceRecord, customInfo, extra));
      sendCond.notify_one();
    }
  }

  void request(uint32_t id, const string& cmd, Caps& args) {
    KLOGD(TAG, "%s: cmd %s, sending %d", __func__, cmd.c_str(), sending);
    lock_guard<mutex> locker{sendMutex};
    if (sending) {
      shortMessages.push_back(new Request(id, cmd, args));
      sendCond.notify_one();
    }
  }

  void changeRokidAccount(const string& acc) {
    lock_guard<mutex> locker{sendMutex};
    if (sending) {
      shortMessages.push_back(new RokidAccountRequest(acc));
      sendCond.notify_one();
    }
  }

  void response(uint32_t id, Caps& args) {
    lock_guard<mutex> locker{sendMutex};
    if (sending) {
      shortMessages.push_back(new Response(id, args));
      sendCond.notify_one();
    }
  }

  void notify(const string& cmd, Caps& args, NotifyConfirm confirm) {
    lock_guard<mutex> locker{sendMutex};
    if (sending) {
      shortMessages.push_back(new Notify(cmd, args, confirm));
      sendCond.notify_one();
    }
  }

  /// \param codec 1 pcm
  ///              2 ogg opus
  ///              3 mp3
  /// \param mode 1: 迅飞系统内置
  /// \param mode 2: 蚂蚁近场
  /// \param mode 3: rokid自研全向
  /// \param mode 4: 蚂蚁全向
  /// \param mode 5: 迅飞定向
  /// \param mode 6: 无障碍模式
  void openAudioRecord(uint32_t codec, uint32_t mode, const string& intent,
      const AudioRecordParam& arp) {
    if (codec == 0)
      return;
    if (remoteProtoMinorVersion < 6) {
      if (codec > CXR_AUDIO_CODEC_OGGOPUS)
        return;
      codec = convertCodec1_5(codec, mode);
      openAudioRecord1_5(codec, intent, nullptr, arp.denoiseMode);
      return;
    }

    Caps pack;
    pack << "openAudioRecord2";
    pack << codec;
    pack << mode;
    pack << intent;
    /// 蚂蚁降噪sdk可设置降噪等级
    Caps param;
    param << arp.denoiseMode;
    param << arp.rokidDtlnAEC;
    param << arp.rokidBF;
    pack.write(param);
    request(0, "CXRControl", pack);
  }

  void closeAudioRecord(const string& intent) {
    Caps pack;
    pack << "closeAudioRecord";
    pack << intent;
    request(0, "CXRControl", pack);
  }

  void cancelAudioPlay(uint32_t id) {
    Caps pack;
    pack << "cancelAudioPlay";
    pack << id;
    request(0, "CXRControl", pack);
  }

  /// NOTE: value是CXRProtocol模块外部使用new分配的
  ///       这里为了节省一次内存分配和拷贝操作, 直接使用了模块外部的value指针
  ///       使用完后在CXRProtocol模块内部使用delete释放了value指针
  ///       破坏了指针分配/释放在同一个模块的规则
  void send(const string& cmd, Caps& args,
      uint8_t* value, uint32_t size) {
    lock_guard<mutex> locker{sendMutex};
    if (sending) {
      transfers.emplace_back(cmd, args, value, size);
      sendCond.notify_one();
    }
  }

#ifdef CXR_SERVER_SIDE
  void sendARTCFrame(uint32_t key, uint8_t* value, uint32_t size,
      uint64_t timestamp) {
    KLOGD(TAG, "%s: sending %d", __func__, sending);
    lock_guard<mutex> locker{sendMutex};
    if (sending) {
      artcFrameQueue.tryDropFrame();
      artcFrameQueue.add(key, value, size, timestamp);
      sendCond.notify_one();
    }
  }
#else
  bool startPlayAudio(uint32_t id, int32_t prio, float speed, uint32_t codec) {
    Caps args;
    args << prio;
    args << speed;
    return startAudioStream(id, codec, 1, "playAudio", args, true);
  }
#endif

  bool startAudioStream(uint32_t id, uint32_t codec, uint32_t channels,
      const string& intent, Caps& args, bool autoEncode = true) {
    lock_guard<mutex> locker{sendMutex};
    if (!sending)
      return false;
    auto stream = obtainSendAudioStream(id);
    stream->start(id, codec, channels, intent, args, autoEncode);
    sendCond.notify_one();
    return true;
  }

  int32_t sendAudioStream(uint32_t id, const uint8_t* data, uint32_t size,
      uint64_t ts = 0) {
    lock_guard<mutex> locker{sendMutex};
    if (!sending)
      return -1;
    auto stream = findSendAudioStream(id);
    if (stream == nullptr)
      return -2;
    auto r = stream->write(data, size, ts);
    if (r >= 0)
      sendCond.notify_one();
    return r;
  }

  void finishAudioStream(uint32_t id) {
    lock_guard<mutex> locker{sendMutex};
    if (sending) {
      auto stream = findSendAudioStream(id);
      if (stream != nullptr) {
        stream->stop();
        sendCond.notify_one();
      }
    }
  }

#ifndef CXR_SERVER_SIDE
  void disconnect() {
    lock_guard<mutex> locker{sendMutex};
    if (sending) {
      shortMessages.push_back(new DisconnectRequest());
      sendCond.notify_one();
    }
  }
#endif

#ifdef CXR_SERVER_SIDE
  void notifyActiveStatus(int32_t status, const string& mac, const string& info) {
    lock_guard<mutex> locker{sendMutex};
    if (sending) {
      shortMessages.push_back(new ActiveStatusNotify(status, mac, info));
      sendCond.notify_one();
    }
  }

  void sendClientList(uint32_t id, vector<ClientInfo>&& infos) {
    lock_guard<mutex> locker{sendMutex};
    if (sending) {
      shortMessages.push_back(new ClientListResp(id, move(infos)));
      sendCond.notify_one();
    }
  }

  void sendRemoveClientResult(uint32_t id, int32_t result, const string& mac) {
    lock_guard<mutex> locker{sendMutex};
    if (sending) {
      shortMessages.push_back(new RemoveClientResp(id, result, mac));
      sendCond.notify_one();
    }
  }
#else
  void active(const string& mac) {
    lock_guard<mutex> locker{sendMutex};
    if (sending) {
      if (authorized) {
        shortMessages.push_back(new ActiveRequest(mac));
        sendCond.notify_one();
      } else {
        // 等待获取眼镜服务的协议版本号后, 才能发送ActiveRequest
        pendingSendMessages.push_back(new ActiveRequest(mac));
      }
    }
  }

  /// \brief 获取曾经连接过眼镜的客户端信息列表, 阻塞直至获取成功或超时
  int32_t getClientList(vector<ClientInfo>& out, uint32_t timeout = 1000) {
    unique_lock<mutex> locker{syncReqMutex};
    auto id = ++syncReqId;
    syncRespMessages.insert(make_pair(id, nullptr));
    locker.unlock();

    sendMutex.lock();
    if (sending) {
      shortMessages.push_back(new ClientListReq(id));
      sendCond.notify_one();
    }
    sendMutex.unlock();

    locker.lock();
    syncReqCond.wait_for(locker, std::chrono::milliseconds{timeout});
    auto it = syncRespMessages.find(id);
    // impossible error
    if (it == syncRespMessages.end())
      return -1;
    // timeout
    if (it->second == nullptr) {
      syncRespMessages.erase(it);
      return -2;
    }
    auto msg = static_cast<ClientListResp*>(it->second);
    out = move(msg->clientInfos);
    delete msg;
    syncRespMessages.erase(it);
    return 0;
  }

  /// \brief 获取曾经连接过眼镜的客户端信息列表, 非阻塞, 异步回调(onClientList)结果
  void fetchClientList() {
    lock_guard<mutex> locker{sendMutex};
    if (sending) {
      shortMessages.push_back(new ClientListReq(++syncReqId));
      sendCond.notify_one();
    }
  }

  /// \brief 从眼镜删除指定客户端信息
  ///
  /// \param mac 客户端mac地址
  /// \param timeout 删除操作的超时时间, 毫秒
  //                 = 0 异步回调删除操作的结果
  ///                > 0 方法阻塞直致删除操作返回结果或超时
  /// \return 删除操作结果
  ///         0 成功
  ///        -1 超时
  ///        -2 未找到mac指定客户端信息
  ///        -3 无权删除: 本连接非活动状态或删除的目标是活动状态
  ///        -4 不可删除配对的手机设备
  int32_t removeClient(const string& mac, uint32_t timeout = 0) {
    unique_lock<mutex> locker{syncReqMutex};
    auto id = ++syncReqId;
    if (timeout > 0)
      syncRespMessages.insert(make_pair(id, nullptr));
    locker.unlock();

    sendMutex.lock();
    if (sending) {
      shortMessages.push_back(new RemoveClientReq(id, mac));
      sendCond.notify_one();
    }
    sendMutex.unlock();

    if (timeout > 0) {
      locker.lock();
      syncReqCond.wait_for(locker, std::chrono::milliseconds{timeout});
      auto it = syncRespMessages.find(id);
      // impossible error
      if (it == syncRespMessages.end())
        return -100;
      // timeout
      if (it->second == nullptr) {
        syncRespMessages.erase(it);
        return -1;
      }
      auto msg = static_cast<RemoveClientResp*>(it->second);
      int32_t ret = msg->result;
      delete msg;
      syncRespMessages.erase(it);
      return ret;
    } else
      return 0;
  }
#endif

  int32_t handleReadPacket(const uint8_t* data, uint32_t size, int32_t* res) {
    if (size > 0) {
      memcpy(recvBuffer + readPos, data, size);
      readPos += size;
    }
    Caps pack;
    uint32_t off{0};
    *res = 1;
    while (off < readPos) {
      auto c = pack.parse2(recvBuffer + off, readPos - off);
      if (c == 0)
        break;
      if (c < 0) {
        readPos = 0;
        *res = -1;
        break;
      }
      off += c;
      *res = packetHandler(pack);
      if (*res >= 0)
        continue;
      if (*res < 0)
        break;
    }
    readPos -= off;
    if (off && readPos)
      memmove(recvBuffer, recvBuffer + off, readPos);
    return readPos;
  }

#ifndef CXR_SERVER_SIDE
  void setRemoteProtoVersion(uint16_t major, uint16_t minor) {
    KLOGI(TAG, "%s: %u.%u", __func__, major, minor);
    remoteProtoMajorVersion = major;
    remoteProtoMinorVersion = minor;
    authorized = true;
  }
#else
  void setClientMac(const string& mac) {
    clientMac = mac;
  }
#endif

private:
  uint32_t convertCodec1_5(uint32_t codec, uint32_t mode) {
    if (mode == CXR_AUDIO_RECORD_XUNFEI && codec == CXR_AUDIO_CODEC_PCM)
      return 1;
    if (mode == CXR_AUDIO_RECORD_XUNFEI && codec == CXR_AUDIO_CODEC_OGGOPUS)
      return 2;
    if (mode == CXR_AUDIO_RECORD_ANTSE && codec == CXR_AUDIO_CODEC_PCM)
      return 3;
    if (mode == CXR_AUDIO_RECORD_ANTSE && codec == CXR_AUDIO_CODEC_OGGOPUS)
      return 4;
    if (mode == CXR_AUDIO_RECORD_ROKIDAEC && codec == CXR_AUDIO_CODEC_PCM)
      return 5;
    if (mode == CXR_AUDIO_RECORD_ROKIDAEC && codec == CXR_AUDIO_CODEC_OGGOPUS)
      return 6;
    if (mode == CXR_AUDIO_RECORD_ANTOMNI && codec == CXR_AUDIO_CODEC_PCM)
      return 7;
    if (mode == CXR_AUDIO_RECORD_ANTOMNI && codec == CXR_AUDIO_CODEC_OGGOPUS)
      return 8;
    return 0;
  }

  void openAudioRecord1_5(uint32_t codec, const string& intent, const Caps* args,
      int32_t denoiseMode) {
    Caps pack;
    pack << "openAudioRecord";
    pack << codec;
    pack << intent;
    if (args != nullptr)
      pack << *args;
    else {
      Caps tmp;
      pack.write(tmp);
    }
    /// 蚂蚁降噪sdk可设置降噪等级
    Caps param;
    param << denoiseMode;
    pack.write(param);
    request(0, "CXRControl", pack);
  }

  void stopSendTask() {
    lock_guard<mutex> locker{sendMutex};
    sending = 0;
    sendCond.notify_one();
#ifdef CXR_SERVER_SIDE
    artcRateCond.notify_one();
#endif
  }

  void stopCallbackTask() {
    lock_guard<mutex> locker{recvMutex};
    receiving = 0;
    recvCond.notify_one();
  }

  void initBuffers() {
    auto ptr = mmap(nullptr, CXRConfig::cxrproto.send_buffer_size,
        PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
    if (ptr != (void*)-1)
      sendBuffer = (uint8_t*)ptr;
    ptr = mmap(nullptr, CXRConfig::cxrproto.recv_buffer_size,
        PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
    if (ptr != (void*)-1)
      recvBuffer = (uint8_t*)ptr;
  }

  void releaseBuffers() {
    if (sendBuffer) {
      munmap(sendBuffer, CXRConfig::cxrproto.send_buffer_size);
      sendBuffer = nullptr;
    }
    if (recvBuffer) {
      munmap(recvBuffer, CXRConfig::cxrproto.recv_buffer_size);
      recvBuffer = nullptr;
    }
  }

  void initTasks() {
    sendTask = [this]() {
      Caps pack;
      uint32_t c;
      NotifyConfirm confirm;
      /**
      // pthread_setname_np(pthread_self(), "CXRProtoSend");
      int tid = syscall(SYS_gettid);
#ifdef CXR_SERVER_SIDE
      setpriority(PRIO_PROCESS, tid, -20);
#else
      setpriority(PRIO_PROCESS, tid, -10);
#endif
      KLOGI(TAG, "CXRProtoSend thread id %d", tid);
      */
      int32_t audioPackType;
      unique_lock<mutex> locker{sendMutex, defer_lock};
      while (true) {
        locker.lock();
        if (!sending) {
          clearSendData();
          break;
        }
        if (!shortMessages.empty()) {
          auto msg = shortMessages.front();
#ifdef CXR_SERVER_SIDE
          const char* prompt = "客户端";
#else
          const char* prompt = "眼镜";
#endif
          if (msg->minProtoMinorVersion > remoteProtoMinorVersion) {
            KLOGW(TAG, "%s版本过低(1.%u), 不发送\"%s\"消息", prompt,
                remoteProtoMinorVersion, msg->type());
            shortMessages.pop_front();
            delete msg;
            locker.unlock();
            continue;
          }
          KLOGI(TAG, "sending ShortMessage %s", msg->type());
          if (msg->type() == "notify")
            confirm = static_cast<Notify*>(msg)->confirm;
          msg->createPack(pack);
          shortMessages.pop_front();
          delete msg;
        } else if (generateAudioPacket(pack, &audioPackType)) {
          KLOGD(TAG, "sending AudioPacket");
        } else if (!transfers.empty()) {
          auto r = transfers.front().createPack(pack);
          if (r == 2) {
            KLOGI(TAG, "sending: transfer start");
          } else if (r == 0) {
            KLOGD(TAG, "sending: transfer end");
            transfers.pop_front();
          } else if (r < 0) {
            KLOGW(TAG, "transfer invalid, maybe size == 0");
            transfers.pop_front();
            locker.unlock();
            continue;
          }
#ifdef CXR_SERVER_SIDE
        } else if (!artcFrameQueue.empty()) {
          auto r = artcFrameQueue.createPack(pack);
          if (r == 2) {
            KLOGI(TAG, "sending: artc frame start: %u bytes", artcFrameQueue.frontSize());
          } else if (r == 1) {
            KLOGD(TAG, "sending: artc frame part");
          } else if (r == 0) {
            KLOGD(TAG, "sending: artc frame end: %d", r);
            artcFrameQueue.pop_front();
          } else if (r < 0) {
            KLOGW(TAG, "artc frame invalid, maybe size == 0");
            artcFrameQueue.pop_front();
            locker.unlock();
            continue;
          }
#endif
        } else {
          sendCond.wait(locker);
          locker.unlock();
          continue;
        }
        eraseFinishedSendAudioStream();
        // debug
        printPendingData();
        locker.unlock();
        try {
          c = pack.serialize(sendBuffer, CXRConfig::cxrproto.send_buffer_size);
        } catch (exception& e) {
          KLOGW(TAG, "caps serialize failed, sending aborted: %s", e.what());
          c = 0;
        }
        pack.clear();
        fragmentCallback(sendBuffer, c);
        if (confirm != nullptr) {
          KLOGI(TAG, "invoke NotifyConfirm");
          confirm();
          confirm = nullptr;
        }
      }
// #ifdef CXR_SERVER_SIDE
      // setpriority(PRIO_PROCESS, tid, 0/*ANDROID_PRIORITY_NORMAL*/);
// #endif
    };
    callbackTask = [this]() {
// #ifdef CXR_SERVER_SIDE
/**
      // pthread_setname_np(pthread_self(), "CXRProtoCallback");
      int tid = syscall(SYS_gettid);
      setpriority(PRIO_PROCESS, tid, -10);
      KLOGI(TAG, "CXRProtoCallback thread id %d", tid);
*/
// #endif
      unique_lock<mutex> locker{recvMutex, defer_lock};
      ShortMessage* msg{nullptr};
      RecvTransfer* cbtrans{nullptr};
      ARTCFrame* cbframe{nullptr};
      constexpr uint32_t maxAudioDataSize{32000};
      uint8_t* audioData = new uint8_t[maxAudioDataSize];
      KLOGI(TAG, "callbackTask running");
      while (true) {
        locker.lock();
        if (!receiving) {
          clearRecvData();
          break;
        }
        if (!recvShortMessages.empty()) {
          msg = recvShortMessages.front();
          recvShortMessages.pop_front();
        } else if (!callbackTransfers.empty()) {
          cbtrans = callbackTransfers.front();
          callbackTransfers.pop_front();
        } else if (!callbackFrames.empty()) {
          cbframe = callbackFrames.front();
          callbackFrames.pop_front();
        }
        locker.unlock();
        // auto starttp = steady_clock::now();
        if (msg) {
          auto type = msg->type();
#ifdef CXR_SERVER_SIDE
          if (strcmp(type, "request") == 0) {
            auto req = static_cast<Request*>(msg);
            KLOGD(TAG, "onRequest %u %s", req->reqid, req->cmd.c_str());
            callback.onRequest(req->reqid, req->cmd, req->args);
          } else if (strcmp(type, "changeRokidAccount") == 0) {
            auto req = static_cast<RokidAccountRequest*>(msg);
            KLOGD(TAG, "onRokidAccountChanged %s", req->account.c_str());
            callback.onRokidAccountChanged(req->account);
          } else if (strcmp(type, "active") == 0) {
            KLOGD(TAG, "onActiveReq");
            auto req = static_cast<ActiveRequest*>(msg);
            callback.onActiveReq(req->clientTime, req->mac);
          } else if (strcmp(type, "ClientListReq") == 0) {
            vector<ClientInfo> infos;
            callback.onClientListReq(infos);
            for (size_t i = 0; i < infos.size(); ++i) {
              KLOGI(TAG, "ClientList[%d]: status %d, mac %s, customInfo %s",
                  i, infos[i].status, infos[i].mac.c_str(), infos[i].customInfo.c_str());
            }
            sendClientList(static_cast<ClientListReq*>(msg)->reqid, move(infos));
          } else if (strcmp(type, "RemoveClientReq") == 0) {
            auto req = static_cast<RemoveClientReq*>(msg);
            auto r = callback.onRemoveClientReq(req->targetMac);
            KLOGD(TAG, "RemoveClientReq %s, result %d", req->targetMac.c_str(), r);
            sendRemoveClientResult(req->reqid, r, req->targetMac);
          }
#else
          if (strcmp(type, "response") == 0) {
            auto resp = static_cast<Response*>(msg);
            KLOGD(TAG, "onResponse %u", resp->reqid);
            if (callback.onResponse != nullptr)
              callback.onResponse(resp->reqid, resp->args);
          } else if (strcmp(type, "notify") == 0) {
            auto noti = static_cast<Notify*>(msg);
            KLOGD(TAG, "onNotify %s", noti->cmd.c_str());
            if (callback.onNotify != nullptr)
              callback.onNotify(noti->cmd, noti->args);
          } else if (strcmp(type, "authResponse") == 0) {
            auto resp = static_cast<AuthResponse*>(msg);
            if (callback.onAuthResult != nullptr)
              callback.onAuthResult(resp->retCode, resp->majorVersion,
                  resp->minorVersion, resp->clientMac);
            if (resp->retCode >= 0 && callback.onActiveStatus != nullptr)
              callback.onActiveStatus(resp->retCode, "", "");
          } else if (strcmp(type, "activeStatusNotify") == 0) {
            auto stn = static_cast<ActiveStatusNotify*>(msg);
            KLOGD(TAG, "onActiveStatus %d", stn->status);
            if (callback.onActiveStatus != nullptr)
              callback.onActiveStatus(stn->status, stn->mac, stn->customInfo);
          } else if (strcmp(type, "ClientListResp") == 0) {
            auto resp = static_cast<ClientListResp*>(msg);
            KLOGD(TAG, "onClientListResp %d", resp->clientInfos.size());
            if (callback.onClientListResp != nullptr)
              callback.onClientListResp(resp->clientInfos);
          } else if (strcmp(type, "RemoveClientResp") == 0) {
            auto resp = static_cast<RemoveClientResp*>(msg);
            KLOGD(TAG, "onRemoveClientResult %d", resp->result);
            if (callback.onRemoveClientResult != nullptr)
              callback.onRemoveClientResult(resp->result, resp->targetMac);
          }
#endif
          delete msg;
          msg = nullptr;
        } else if (cbtrans) {
          KLOGD(TAG, "onTransfer %s %u bytes", cbtrans->cmd.c_str(), cbtrans->totalSize);
          if (callback.onTransfer != nullptr)
            callback.onTransfer(cbtrans->cmd, cbtrans->args,
                cbtrans->data, cbtrans->totalSize);
          delete cbtrans;
          cbtrans = nullptr;
#ifndef CXR_SERVER_SIDE
        } else if (cbframe) {
          KLOGD(TAG, "onARTCFrame key %u, %u bytes", cbframe->key, cbframe->dataSize);
          if (callback.onARTCFrame != nullptr)
            callback.onARTCFrame(cbframe->data, cbframe->dataSize, cbframe->timestamp);
          delete cbframe;
          cbframe = nullptr;
#endif
        } else {
          bool hasAudio{false};
          locker.lock();
          auto it = recvAudioStreams.begin();
          while (it != recvAudioStreams.end()) {
            auto stream = (*it);
            if (stream->isStart()) {
              hasAudio = true;
              if (callback.onStartAudioStream != nullptr) {
                callback.onStartAudioStream(stream->streamId, stream->audioCodec,
                    stream->audioChannels, stream->audioIntent, stream->audioArgs);
              }
              stream->clearStartFlag();
            } else {
              uint64_t timestamp;
              auto c = stream->read(audioData, maxAudioDataSize, &timestamp);
              if (c > 0) {
                hasAudio = true;
                if (callback.onAudioStream != nullptr)
                  callback.onAudioStream(stream->streamId, audioData, c, timestamp);
                // auto now = system_clock::now().time_since_epoch();
                // auto cost = duration_cast<std::chrono::milliseconds>(now).count() - timestamp;
                // KLOGI(TAG, "audio data delay %dms", (int32_t)cost);
              } else if (stream->isStop() || stream->isTimeout()) {
                hasAudio = true;
                it = recvAudioStreams.erase(it);
                if (callback.onAudioStreamFinish != nullptr)
                  callback.onAudioStreamFinish(stream->streamId);
                delete stream;
              }
            }
            ++it;
          }
          if (!hasAudio) {
            // 如果有未完成的RecvAudioStream, 隔段时间检测一下是否超时
            if (recvAudioStreams.empty())
              recvCond.wait(locker);
            else
              recvCond.wait_for(locker, std::chrono::seconds{20});
            locker.unlock();
            continue;
          }
          locker.unlock();
        }
        // auto endtp = steady_clock::now();
        // int32_t costms = duration_cast<milliseconds>(endtp - starttp).count();
        // KLOGD(TAG, "cxr msg callback cost %d ms", costms);
      }
      delete[] audioData;
// #ifdef CXR_SERVER_SIDE
      // setpriority(PRIO_PROCESS, tid, 0/*ANDROID_PRIORITY_NORMAL*/);
// #endif
      KLOGI(TAG, "callbackTask exit");
    };
#ifdef CXR_SERVER_SIDE
    artcStatusTask = [this]() {
      bool reset{false};
      std::chrono::seconds tm{ARTC_SENT_RATE_PERIOD};
      unique_lock<mutex> locker{sendMutex};
      KLOGI(TAG, "artcStatusTask running");
      while (true) {
        if (!sending)
          break;
        auto rate = artcFrameQueue.getSentRate(&reset);
        if (rate > 0 && callback.onARTCStatus != nullptr)
          callback.onARTCStatus(rate, reset);
        artcRateCond.wait_for(locker, tm);
      }
      KLOGI(TAG, "artcStatusTask exit");
    };
#endif
  }

  SendAudioStream* findSendAudioStream(uint32_t id) {
    auto it = sendAudioStreams.begin();
    while (it != sendAudioStreams.end()) {
      if ((*it)->isMatch(id))
        return *it;
      ++it;
    }
    return nullptr;
  }

  SendAudioStream* obtainSendAudioStream(uint32_t id) {
    auto stream = findSendAudioStream(id);
    if (stream)
      return stream;
    stream = new SendAudioStream(TAG, remoteProtoMajorVersion, remoteProtoMinorVersion);
    KLOGI(TAG, "new SendAudioStream %u", id);
    // stream->init(CXRConfig::audio.send_buffer_size);
    sendAudioStreams.push_back(stream);
    return stream;
  }

  RecvAudioStream* findRecvAudioStream(uint32_t id) {
    auto it = recvAudioStreams.begin();
    while (it != recvAudioStreams.end()) {
      if ((*it)->isMatch(id))
        return *it;
      ++it;
    }
    return nullptr;
  }

  RecvAudioStream* obtainRecvAudioStream(uint32_t id) {
    auto stream = findRecvAudioStream(id);
    if (stream)
      return stream;
    stream = new RecvAudioStream(TAG);
    // stream->init(CXRConfig::audio.recv_buffer_size);
    recvAudioStreams.push_back(stream);
    return stream;
  }

    
  void printPendingData() {
    KLOGI(TAG, "has %u short messages", shortMessages.size());
    auto it = sendAudioStreams.begin();
    while (it != sendAudioStreams.end()) {
      KLOGI(TAG, "SendAudioStream(%u) has %u packets",
      (*it)->getId(), (*it)->audioPacketCount());
      ++it;
    }
    auto it2 = transfers.begin();
    while (it2 != transfers.end()) {
      KLOGI(TAG, "Transfer(%s) remain %u bytes",
            it2->getCommand(), it2->remainBytes());
      ++it2;
      }
  }
    
  bool generateAudioPacket(Caps& out, int32_t* packType) {
    int32_t r;
    auto it = sendAudioStreams.begin();
    while (it != sendAudioStreams.end()) {
      if (!(*it)->empty()) {
        r = (*it)->createPack(out);
        *packType = r;
        // r == 1: start audio stream
        // r == 2: audio stream
        // r == 3: finish audio stream
        if (r == 0)
          return false;
        // 兼容旧版本协议
        if (r == 3 && remoteProtoMinorVersion < 4) {
          out.clear();
          return false;
        }
        return true;
      }
      ++it;
    }
    return false;
  }

  void eraseFinishedSendAudioStream() {
    bool erased{false};
    auto it = sendAudioStreams.begin();
    while (it != sendAudioStreams.end()) {
      auto stream = (*it);
      if (stream->isFinished() || stream->isTimeout()) {
        KLOGI(TAG, "erase finished or timeout SendAudioStream %u", stream->getId());
        delete stream;
        it = sendAudioStreams.erase(it);
        erased = true;
      } else
        ++it;
    }
  }

  void sendAuthResponse(int32_t ret) {
    lock_guard<mutex> locker{sendMutex};
    if (sending) {
      shortMessages.push_back(new AuthResponse(
            CXR_PROTO_MAJOR_VERSION, CXR_PROTO_MINOR_VERSION, ret, clientMac));
      sendCond.notify_one();
    }
  }

  void initHandlers() {
#ifdef CXR_SERVER_SIDE
    packetHandler = std::bind(&CXRProtocol::handlePacketBeforeAuthorized,
        this, placeholders::_1);
#else
    packetHandler = std::bind(&CXRProtocol::handlePacketAfterAuthorized,
        this, placeholders::_1);
#endif

    CmdHandler handler;
#ifdef CXR_SERVER_SIDE
    handler = [this](Caps&) -> int32_t {
      KLOGI(TAG, "CXR连接已认证成功, 再次收到AUTH_REQ, 无条件认证通过");
      sendAuthResponse(isClientActive ? 0 : 1);
      return 0;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_AUTH_REQ, handler));
    handler = [this](Caps& pack) -> int32_t {
      auto req = new Request();
      if (!req->create(pack)) {
        delete req;
        KLOGE(TAG, "recv Request, data invalid");
        return -301;
      }
      KLOGI(TAG, "recv Request: id %u, cmd %s", req->reqid, req->cmd.c_str());
      lock_guard<mutex> locker{recvMutex};
      recvShortMessages.push_back(req);
      recvCond.notify_one();
      return 0;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_REQUEST, handler));
    handler = [this](Caps& pack) -> int32_t {
      auto req = new RokidAccountRequest();
      if (!req->create(pack)) {
        delete req;
        pack.dump(dumpBuffer, sizeof(dumpBuffer));
        KLOGE(TAG, "recv RokidAccountRequest: data invalid\n%s", dumpBuffer);
        return -301;
      }
      KLOGI(TAG, "recv RokidAccountRequest: %s", req->account.c_str());
      lock_guard<mutex> locker{recvMutex};
      recvShortMessages.push_back(req);
      recvCond.notify_one();
      return 0;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_CHANGE_ROKID_ACCOUNT, handler));
    handler = [](Caps& pack) -> int32_t {
      // 返回负值, 即可断开client
      return -601;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_DISCONNECT, handler));
    handler = [this](Caps& pack) -> int32_t {
      lock_guard<mutex> locker{recvMutex};
      auto req = new ActiveRequest();
      req->create(pack, remoteProtoMajorVersion, remoteProtoMinorVersion);
      recvShortMessages.push_back(req);
      recvCond.notify_one();
      return 0;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_ACTIVE_REQ, handler));
    handler = [this](Caps& pack) -> int32_t {
      lock_guard<mutex> locker{recvMutex};
      auto req = new ClientListReq();
      req->create(pack);
      recvShortMessages.push_back(req);
      recvCond.notify_one();
      return 0;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_CLIENT_LIST_REQ, handler));
    handler = [this](Caps& pack) -> int32_t {
      lock_guard<mutex> locker{recvMutex};
      auto req = new RemoveClientReq();
      req->create(pack);
      recvShortMessages.push_back(req);
      recvCond.notify_one();
      return 0;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_REMOVE_CLIENT_REQ, handler));
#else // CXR_SERVER_SIDE
    handler = [this](Caps& pack) -> int32_t {
      auto resp = new Response();
      if (!resp->create(pack)) {
        delete resp;
        KLOGE(TAG, "recv Response: data invalid");
        return -301;
      }
      KLOGI(TAG, "recv Response: id %u", resp->reqid);
      lock_guard<mutex> locker{recvMutex};
      recvShortMessages.push_back(resp);
      recvCond.notify_one();
      return 0;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_RESPONSE, handler));
    handler = [this](Caps& pack) -> int32_t {
      auto noti = new Notify();
      if (!noti->create(pack)) {
        delete noti;
        KLOGE(TAG, "recv Notify: data invalid");
        return -301;
      }
      KLOGI(TAG, "recv Notify: cmd %s", noti->cmd.c_str());
      lock_guard<mutex> locker{recvMutex};
      recvShortMessages.push_back(noti);
      recvCond.notify_one();
      return 0;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_NOTIFY, handler));
    handler = [this](Caps& pack) -> int32_t {
      auto resp = new AuthResponse();
      if (!resp->create(pack))
        return -404;
      KLOGI(TAG, "CXR协议握手结果%d, 服务协议版本%u.%u", resp->retCode,
          resp->majorVersion, resp->minorVersion);
      sendMutex.lock();
      setRemoteProtoVersion(resp->majorVersion, resp->minorVersion);
      shortMessages.insert(shortMessages.end(), pendingSendMessages.begin(),
          pendingSendMessages.end());
      pendingSendMessages.clear();
      sendCond.notify_one();
      sendMutex.unlock();
      lock_guard<mutex> locker{recvMutex};
      recvShortMessages.push_back(resp);
      recvCond.notify_one();
      return resp->retCode;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_AUTH_RESP, handler));
    handler = [this](Caps& pack) -> int32_t {
      auto r = recvARTCFrame.create(pack);
      if (r < 0) {
        KLOGE(TAG, "recv artc frame: data invalid");
      } else {
        KLOGI(TAG, "recv artc frame: data size %u", recvARTCFrame.frame->dataSize);
      }
      // int64_t sendTime = (uint64_t)pack[3];
      // auto dur = system_clock::now().time_since_epoch();
      // int64_t recvTime = duration_cast<std::chrono::milliseconds>(dur).count();
      // KLOGI(TAG, "artc frame transfer time %" PRIi64, recvTime - sendTime);
      if (recvARTCFrame.frame->dataSize == 0) {
        auto frame = recvARTCFrame.getFrame();
        lock_guard<mutex> locker{recvMutex};
        callbackFrames.push_back(frame);
        recvCond.notify_one();
      }
      return r;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_ARTC_FRAME_START, handler));
    handler = [this](Caps& pack) -> int32_t {
      auto r = recvARTCFrame.write(pack, false);
      if (r < 0) {
        KLOGE(TAG, "recv artc frame failed: %d", r);
      }
      return r;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_ARTC_FRAME_TRANSFER, handler));
    handler = [this](Caps& pack) -> int32_t {
      auto r = recvARTCFrame.write(pack, true);
      KLOGI(TAG, "recv artc frame last: %d", r);
      if (r < 0)
        return r;
      auto frame = recvARTCFrame.getFrame();
      auto dur = system_clock::now().time_since_epoch();
      int64_t recvTime = duration_cast<std::chrono::milliseconds>(dur).count();
      KLOGI(TAG, "artc frame transfer time %" PRIi64 ", %" PRIi64,
          recvTime - frame->sendTime, recvTime - frame->timestamp);
      lock_guard<mutex> locker{recvMutex};
      callbackFrames.push_back(frame);
      recvCond.notify_one();
      return r;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_ARTC_FRAME_LAST, handler));
    handler = [this](Caps& pack) -> int32_t {
      auto msg = new ActiveStatusNotify();
      msg->create(pack, remoteProtoMajorVersion, remoteProtoMinorVersion);
      lock_guard<mutex> locker{recvMutex};
      recvShortMessages.push_back(msg);
      recvCond.notify_one();
      return 0;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_ACTIVE_NOTIFY, handler));
    handler = [this](Caps& pack) -> int32_t {
      auto msg = new ClientListResp();
      msg->create(pack);
      unique_lock<mutex> syncLocker{syncReqMutex};
      auto it = syncRespMessages.find(msg->reqid);
      if (it != syncRespMessages.end()) {
        it->second = msg;
        syncReqCond.notify_one();
        return 0;
      }
      syncLocker.unlock();
      lock_guard<mutex> locker{recvMutex};
      recvShortMessages.push_back(msg);
      recvCond.notify_one();
      return 0;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_CLIENT_LIST_RESP, handler));
    handler = [this](Caps& pack) -> int32_t {
      auto msg = new RemoveClientResp();
      msg->create(pack);
      unique_lock<mutex> syncLocker{syncReqMutex};
      auto it = syncRespMessages.find(msg->reqid);
      if (it != syncRespMessages.end()) {
        it->second = msg;
        syncReqCond.notify_one();
        return 0;
      }
      syncLocker.unlock();
      lock_guard<mutex> locker{recvMutex};
      recvShortMessages.push_back(msg);
      recvCond.notify_one();
      return 0;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_REMOVE_CLIENT_RESP, handler));
#endif // CXR_SERVER_SIDE
    handler = [this](Caps& pack) -> int32_t {
      auto trans = new RecvTransfer();
      auto r = trans->create(pack);
      if (r < 0) {
        delete trans;
        KLOGE(TAG, "recv Transfer: data invalid");
        return r;
      }
      KLOGI(TAG, "recv Transfer: cmd %s, totalSize %u",
          trans->cmd.c_str(), trans->totalSize);
      if (recvTransfer)
        delete recvTransfer;
      if (trans->totalSize)
        recvTransfer = trans;
      else {
        lock_guard<mutex> locker{recvMutex};
        callbackTransfers.push_back(trans);
        recvTransfer = nullptr;
        recvCond.notify_one();
      }
      return r;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_TRANSFER_START, handler));
    handler = [this](Caps& pack) -> int32_t {
      if (recvTransfer == nullptr)
        return -199;
      auto r = recvTransfer->write(pack, false);
      if (r < 0) {
        KLOGE(TAG, "recv Transfer failed: %d", r);
        delete recvTransfer;
        recvTransfer = nullptr;
      }
      return r;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_TRANSFER, handler));
    handler = [this](Caps& pack) -> int32_t {
      if (recvTransfer == nullptr)
        return -199;
      auto r = recvTransfer->write(pack, true);
      KLOGI(TAG, "recv TransferLast: %d", r);
      if (r < 0) {
        delete recvTransfer;
        recvTransfer = nullptr;
        return r;
      }
      lock_guard<mutex> locker{recvMutex};
      callbackTransfers.push_back(recvTransfer);
      recvTransfer = nullptr;
      recvCond.notify_one();
      return 0;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_TRANSFER_LAST, handler));
    handler = [this](Caps& pack) -> int32_t {
      lock_guard<mutex> locker{recvMutex};
      uint32_t codec = pack[1];
      string intent = (const string&)pack[2];
      Caps args = pack[3];
      uint32_t id{0};
      uint32_t ocodec{codec};
      uint32_t channels{1};
      if (remoteProtoMinorVersion < 4) {
      } else if (remoteProtoMinorVersion < 6) {
        int32_t prio{0};
        float speed{1.0};
        auto pksz = pack.size();
        KLOGI(TAG, "startAudioStream: caps size %d", pksz);
        id = pack[4];
        if (pksz > 5)
          prio = pack[5];
        if (pksz > 6)
          speed = pack[6];
        if (pksz > 7)
          ocodec = pack[7];
        args.clear();
        args << prio;
        args << speed;
      } else {
        id = pack[4];
        ocodec = pack[5];
        if (remoteProtoMinorVersion >= 8)
          channels = pack[6];
      }
      auto stream = obtainRecvAudioStream(id);
      stream->start(id, codec, channels, intent, args, ocodec);
      recvCond.notify_one();
      KLOGI(TAG, "recv StartAudioStream, codec %u, originCodec %u, channels %u",
          codec, ocodec, channels);
      return 0;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_START_AUDIO_STREAM, handler));
    handler = [this](Caps& pack) -> int32_t {
      lock_guard<mutex> locker{recvMutex};
      uint32_t id{0};
      if (remoteProtoMinorVersion >= 4)
        id = pack[2];
      auto stream = findRecvAudioStream(id);
      if (stream) {
        uint64_t timestamp;
        const vector<char>& ad = pack[1];
        if (remoteProtoMinorVersion >= 7)
          timestamp = pack[3];
        else
          timestamp = 0;
        stream->write(ad.data(), ad.size(), timestamp);
        recvCond.notify_one();
        /**
        if (r < 0) {
          KLOGW(TAG, "RecvAudioStream.write failed(%d): %u bytes, stream %u/%u",
              r, ad.size(), stream->size(), stream->capacity());
        } else
          recvCond.notify_one();
        */
      }
      return 0;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_AUDIO_STREAM, handler));
    handler = [this](Caps& pack) -> int32_t {
      lock_guard<mutex> locker{recvMutex};
      uint32_t id{0};
      if (remoteProtoMinorVersion >= 4)
        id = pack[1];
      auto stream = findRecvAudioStream(id);
      if (stream) {
        stream->stop();
        recvCond.notify_one();
      }
      return 0;
    };
    cmdHandlers.insert(make_pair(CXR_CMD_AUDIO_STREAM_FINISH, handler));
  }

#ifdef CXR_SERVER_SIDE
  int32_t handlePacketBeforeAuthorized(Caps& pack) {
    uint32_t type;
    try {
      type = pack[0];
    } catch (exception& e) {
      return -31;
    }
    if (type != CXR_CMD_AUTH_REQ) {
      pack.dump(dumpBuffer, sizeof(dumpBuffer));
      KLOGW(TAG, "%s: %s", __func__, dumpBuffer);
      KLOGW(TAG, "%s: request not AUTH_REQ, ignore", __func__);
      return 0;
    }
    AuthRequest req;
    if (!req.create(pack))
      return -32;
    int32_t r{-33};
    if (callback.onAuthorize != nullptr) {
      r = callback.onAuthorize(req.majorVersion, req.minorVersion,
          req.serviceRecord, req.customInfo, req.clientTime, req.extraType);
    }
    KLOGI(TAG, "client authorize: %d", r);
    // android与iphone-mfi都有办法断开app连接
    // 认证失败时无需sendAuthResponse
    // iphone-gatt可以不支持了
    if (r >= 0) {
      remoteProtoMajorVersion = req.majorVersion;
      remoteProtoMinorVersion = req.minorVersion;
      packetHandler = std::bind(&CXRProtocol::handlePacketAfterAuthorized,
          this, placeholders::_1);
      sendAuthResponse(r);
    }
    return r;
  }
#endif

  int32_t handlePacketAfterAuthorized(Caps& pack) {
    try {
      uint32_t type = pack[0];
      KLOGD(TAG, "%s: type = 0x%x", __func__, type);
      auto it = cmdHandlers.find(type);
      if (it == cmdHandlers.end())
        goto failed;
      auto r = it->second(pack);
      if (r < 0) {
        KLOGE(TAG, "%s: type 0x%x failed: %d", __func__, type, r);
      }
      return r;
    } catch (exception& e) {
    }

failed:
    pack.dump(dumpBuffer, sizeof(dumpBuffer));
    KLOGI(TAG, "%s failed, dump caps:\n%s", __func__, dumpBuffer);
    return -1;
  }

  void clearSendData() {
#ifdef CXR_SERVER_SIDE
    artcFrameQueue.clear();
#endif
    transfers.clear();
    auto it = sendAudioStreams.begin();
    while (it != sendAudioStreams.end()) {
      auto stream = (*it);
      it = sendAudioStreams.erase(it);
      delete stream;
    }
  }

  void clearRecvData() {
    // 此时不可能再收到传输数据, 可以放心删除
    if (recvTransfer) {
      delete recvTransfer;
      recvTransfer = nullptr;
    }
    auto it = callbackTransfers.begin();
    while (it != callbackTransfers.end()) {
      delete *it;
      ++it;
    }
    callbackTransfers.clear();
    auto ait = recvAudioStreams.begin();
    while (ait != recvAudioStreams.end()) {
      auto stream = (*ait);
      ait = recvAudioStreams.erase(ait);
      delete stream;
    }
    readPos = 0;
  }

  void fragmentCallback(const uint8_t* data, uint32_t size) {
    if (onSendFragment == nullptr)
      return;
    uint32_t cbsz{0};
    uint32_t off{0};
    while (off < size) {
      if (size - off > mtu)
        cbsz = mtu;
      else
        cbsz = size - off;
      onSendFragment(data + off, cbsz);
      off += cbsz;
    }
  }

protected:
  const char* TAG;

private:
  static constexpr uint32_t dumpBufsize = 2048;
  char dumpBuffer[dumpBufsize];
  uint8_t* sendBuffer{nullptr};
  uint8_t* recvBuffer{nullptr};
  uint16_t sending{0};
  uint16_t receiving{0};
  // variables for send
  ThreadPool::TaskFunc sendTask;
  mutex sendMutex;
  condition_variable sendCond;
  list<TransferInfo> transfers;
#ifdef CXR_SERVER_SIDE
  ThreadPool thrPool{3};
  ARTCFrameQueue artcFrameQueue;
  condition_variable artcRateCond;
  ThreadPool::TaskFunc artcStatusTask;
  uint32_t isClientActive{0};
#else
  ThreadPool thrPool{2};
  RecvARTCFrame recvARTCFrame;
  bool authorized{false};
  list<ShortMessage*> pendingSendMessages;
  // 用于同步请求
  uint32_t syncReqId{0};
  // key: reqid
  // value: response message
  map<uint32_t, ShortMessage*> syncRespMessages;
  mutex syncReqMutex;
  condition_variable syncReqCond;
#endif
  list<SendAudioStream*> sendAudioStreams;
  list<ShortMessage*> shortMessages;
  // variables for recv
  uint32_t readPos{0};
  map<uint32_t, CmdHandler> cmdHandlers;
  mutex recvMutex;
  condition_variable recvCond;
  RecvTransfer* recvTransfer{nullptr};
  list<RecvTransfer*> callbackTransfers;
  list<ARTCFrame*> callbackFrames;
  list<RecvAudioStream*> recvAudioStreams;
  list<ShortMessage*> recvShortMessages;
  ThreadPool::TaskFunc callbackTask;
  Callback callback;
  FragmentCallback onSendFragment;
  uint32_t mtu{500};
  uint16_t remoteProtoMajorVersion{1};
  uint16_t remoteProtoMinorVersion{0};
  PacketHandler packetHandler;
  string clientMac;

  static constexpr uint32_t AUDIO_CALLBACK_CHECK_INTERVAL = 10;
  static constexpr uint32_t ARTC_SENT_RATE_PERIOD = 6;

public:
  static constexpr uint32_t CXR_PROTO_MAJOR_VERSION = 1;
  static constexpr uint32_t CXR_PROTO_MINOR_VERSION = 12;
  static constexpr uint32_t CXR_CMD_REQUEST = 0x1001;
  static constexpr uint32_t CXR_CMD_RESPONSE = 0x1002;
  static constexpr uint32_t CXR_CMD_NOTIFY = 0x1003;
  static constexpr uint32_t CXR_CMD_AUTH_REQ = 0x1004;
  static constexpr uint32_t CXR_CMD_AUTH_RESP = 0x1005;
  static constexpr uint32_t CXR_CMD_CHANGE_ROKID_ACCOUNT = 0x1006;
  // 仅iphone gatt模式使用
  static constexpr uint32_t CXR_CMD_DISCONNECT = 0x1007;
  // 激活当前连接
  static constexpr uint32_t CXR_CMD_ACTIVE_REQ = 0x1008;
  // 连接激活状态通知
  static constexpr uint32_t CXR_CMD_ACTIVE_NOTIFY = 0x1009;
  // 获取曾经连接过的客户端列表
  static constexpr uint32_t CXR_CMD_CLIENT_LIST_REQ = 0x100a;
  static constexpr uint32_t CXR_CMD_CLIENT_LIST_RESP = 0x100b;
  static constexpr uint32_t CXR_CMD_REMOVE_CLIENT_REQ = 0x100c;
  static constexpr uint32_t CXR_CMD_REMOVE_CLIENT_RESP = 0x100d;
  static constexpr uint32_t CXR_CMD_TRANSFER_START = 0x2001;
  static constexpr uint32_t CXR_CMD_TRANSFER = 0x2002;
  static constexpr uint32_t CXR_CMD_TRANSFER_LAST = 0x2003;
  static constexpr uint32_t CXR_CMD_ARTC_FRAME_START = 0x2011;
  static constexpr uint32_t CXR_CMD_ARTC_FRAME_TRANSFER = 0x2012;
  static constexpr uint32_t CXR_CMD_ARTC_FRAME_LAST = 0x2013;
  static constexpr uint32_t CXR_CMD_START_AUDIO_STREAM = 0x3001;
  static constexpr uint32_t CXR_CMD_AUDIO_STREAM = 0x3002;
  static constexpr uint32_t CXR_CMD_AUDIO_STREAM_FINISH = 0x3003;
};
