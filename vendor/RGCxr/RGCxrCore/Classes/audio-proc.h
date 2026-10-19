#pragma once

#include <inttypes.h>
#include <stdint.h>
#include <functional>
#include "opus.h"
#include "cxr-config.h"
#include "ogg.h"
#include "apple-log.h"
// #include "xxd.h"
#ifdef CXR_SERVER_SIDE
#include "media/AudioRecord.h"
#include "thr-pool.h"
#include "permutation.h"
#include "agse_api.h"
#include "ant_rokid_omni_api.h"
#include "minimp3.h"
#ifdef __aarch64__
#include "rokid_audio_api.h"
#include "vtn_api.h"
#include "rokid_agc_16k.h"
#endif
using namespace android;
#endif // CXR_SERVER_SIDE

using namespace std;
using namespace std::chrono;

static constexpr uint32_t CXR_AUDIO_CODEC_PCM = 1;
static constexpr uint32_t CXR_AUDIO_CODEC_OGGOPUS = 2;
static constexpr uint32_t CXR_AUDIO_CODEC_MP3 = 3;
static constexpr uint32_t CXR_AUDIO_RECORD_XUNFEI = 1;
static constexpr uint32_t CXR_AUDIO_RECORD_ANTSE = 2;
static constexpr uint32_t CXR_AUDIO_RECORD_ROKIDAEC = 3;
static constexpr uint32_t CXR_AUDIO_RECORD_ANTOMNI = 4;
static constexpr uint32_t CXR_AUDIO_RECORD_XUNFEI_CAE = 5;
static constexpr uint32_t CXR_AUDIO_RECORD_A11Y = 6;

typedef std::function<void(const uint8_t*, uint32_t)> AudioCallback;

class AudioProcessor;

class AudioProcessorBase {
public:
  virtual ~AudioProcessorBase() = default;

  void setOutput(std::shared_ptr<AudioProcessor>& out) {
    output = out;
  }

  void setOutput(AudioCallback cb) {
    callback = cb;
  }

  virtual void finish();

  inline std::shared_ptr<AudioProcessor> getNext() {
    return output;
  }

protected:
  void gotoNext(const uint8_t* in, uint32_t size);

protected:
  std::shared_ptr<AudioProcessor> output;
  AudioCallback callback;
  bool finished{false};
  static constexpr uint32_t sampleRate = 16000;
  static constexpr uint32_t SAMPLES_PER_CHANNEL = 320;
  static constexpr const char* TAG = "audio-proc";
};

#ifdef CXR_SERVER_SIDE
class AudioProvider : public AudioProcessorBase {
public:
  virtual ~AudioProvider () = default;

  virtual void start() = 0;

  virtual void stop() = 0;
};
#endif // CXR_SERVER_SIDE

class AudioProcessor : public AudioProcessorBase {
public:
  virtual ~AudioProcessor() = default;

  void process(const uint8_t* in, uint32_t size) {
    if (finished)
      return;
    processInner(in, size);
  }

protected:
  virtual void processInner(const uint8_t* in, uint32_t size) = 0;
};

#ifdef CXR_SERVER_SIDE
class AudioRecordWrap : public AudioProvider {
public:
  virtual ~AudioRecordWrap() = default;

protected:
  bool createAudioRecord(audio_channel_mask_t channelMask) {
    audio_format_t format = AUDIO_FORMAT_PCM_16_BIT;
    size_t frameCount = 1600;
#if PLATFORM_SDK_VERSION >= 32
    audio_source_t recsrc = AUDIO_SOURCE_MIC;
    content::AttributionSourceState attributionSource;
    attributionSource.packageName = "com.rokid.cxrservice";
    attributionSource.token = sp<BBinder>::make();
    audioRecord = new AudioRecord(attributionSource);
#else
    audio_source_t recsrc = AUDIO_SOURCE_DEFAULT;
    audioRecord = new AudioRecord(String16(TAG));
#endif
    audioRecord->set(recsrc,
            sampleRate,
            format,
            channelMask,
            frameCount
            );
    auto status = audioRecord->initCheck();
    if (status != NO_ERROR) {
      audioRecord.clear();
      return false;
    }
    status = audioRecord->start();
    return status == NO_ERROR;
  }

protected:
  sp<AudioRecord> audioRecord;
  ThreadPool thrPool{1};
};

class AudioProviderMono : public AudioRecordWrap {
public:
  void start() {
    running = 1;
    ThreadPool::TaskFunc task;
    task = std::bind(&AudioProviderMono::recordingRoutine, this);
    thrPool.push(task);
  }

  void stop() {
    running = 0;
    thrPool.finish();
  }

private:
  void recordingRoutine() {
    KLOGI(TAG, "AudioProviderMono.%s", __func__);
    int16_t pcmBuffer[SAMPLES_PER_CHANNEL];

    if (!createAudioRecord(AUDIO_CHANNEL_IN_MONO)) {
      KLOGE(TAG, "%s: createAudioRecord failed", __func__);
      return;
    }

    while (running) {
      auto pcmBytes = audioRecord->read(pcmBuffer, sizeof(pcmBuffer));
      if (pcmBytes <= 0) {
        KLOGW(TAG, "录音失败: %d", pcmBytes);
        break;
      }
      KLOGD(TAG, "%s: audio output %u bytes", __func__, pcmBytes);
      recordSamples += SAMPLES_PER_CHANNEL;
      gotoNext((uint8_t*)pcmBuffer, pcmBytes);
    }
    audioRecord->stop();
    audioRecord.clear();
    finish();
    KLOGI(TAG, "AudioProviderMono record %u samples", recordSamples);
  }

private:
  int32_t running{0};
  uint32_t recordSamples{0};
};

class AudioProvider8 : public AudioRecordWrap {
public:
  void start() {
    running = 1;
    ThreadPool::TaskFunc task;
    task = std::bind(&AudioProvider8::recordingRoutine, this);
    thrPool.push(task);
  }

  void stop() {
    running = 0;
    thrPool.finish();
  }

private:
  void recordingRoutine() {
    KLOGI(TAG, "AudioProvider8.%s", __func__);
    if (!createAudioRecord(AUDIO_CHANNEL_IN_8)) {
      KLOGE(TAG, "%s: createAudioRecord failed", __func__);
      return;
    }

    uint32_t maxSamples = 8 * SAMPLES_PER_CHANNEL;
    uint32_t bufsize = maxSamples * sizeof(int16_t);
    int16_t* pcmBuffer = new int16_t[maxSamples];
    while (running) {
      auto pcmBytes = audioRecord->read(pcmBuffer, bufsize);
      if (pcmBytes <= 0) {
        KLOGW(TAG, "录音失败: %d", pcmBytes);
        break;
      }
      KLOGD(TAG, "%s: audio output %u bytes", __func__, pcmBytes);
      recordSamples += SAMPLES_PER_CHANNEL;
      gotoNext((uint8_t*)pcmBuffer, pcmBytes);
    }
    delete[] pcmBuffer;
    audioRecord->stop();
    audioRecord.clear();
    finish();
    KLOGI(TAG, "AudioProvider8 record %u samples", recordSamples);
  }

private:
  int32_t running{0};
  uint32_t recordSamples{0};
};
#endif // CXR_SERVER_SIDE

class OggEncodeProcessor : public AudioProcessor {
public:
  OggEncodeProcessor(uint32_t packThres, uint32_t chn, uint32_t oggsn = 0x70000) {
    oggPacketThreshold = packThres;
    ogg_stream_init(&oggStream, oggsn);
    channels = chn;
    MAX_OPUS_ENCODE_BYTES = MAX_OPUS_ENCODE_SAMPLES * chn * 2;
    processBuffer = new uint8_t[MAX_OPUS_ENCODE_BYTES];
    int err{0};
    opusEncoder = opus_encoder_create(sampleRate, chn, OPUS_APPLICATION_VOIP, &err);
  }

  ~OggEncodeProcessor() {
    if (opusEncoder)
      opus_encoder_destroy(opusEncoder);
    ogg_stream_clear(&oggStream);
    if (processBuffer)
      delete[] processBuffer;
  }

  void finish() {
    encode((opus_int16*)processBuffer, processPos / channels / 2, 4);
    processPos = 0;
    AudioProcessor::finish();
  }

protected:
  void processInner(const uint8_t* in, uint32_t size) {
    if (createHead) {
      createHeader(channels, 0, sampleRate);
      vector<string> comments;
      createTags("RokidCXR1.0", comments);
      createHead = false;
    }

    uint32_t off{0};
    if (processPos) {
      auto cpsz = MAX_OPUS_ENCODE_BYTES - processPos;
      if (cpsz > size)
        cpsz = size;
      if (cpsz) {
        memcpy(processBuffer + processPos, in, cpsz);
        processPos += cpsz;
        off += cpsz;
      }
      if (processPos == MAX_OPUS_ENCODE_BYTES) {
        encode((opus_int16*)processBuffer, MAX_OPUS_ENCODE_SAMPLES, 0);
        processPos = 0;
      }
    }

    // opus_encode每次只接受特定数值的字节
    // 剩余的未处理字节先放入processBuffer, 等待后继输入补齐
    uint32_t remain;
    while (off < size) {
      remain = size - off;
      if (remain >= MAX_OPUS_ENCODE_BYTES) {
        encode((opus_int16*)(in + off), MAX_OPUS_ENCODE_SAMPLES, 0);
        off += MAX_OPUS_ENCODE_BYTES;
      } else {
        memcpy(processBuffer, in + off, remain);
        processPos = remain;
        off += remain;
      }
    }
  }

private:
  void createHeader(uint8_t channels, uint16_t preskip, uint32_t sampleRate) {
    uint8_t buffer[32];
    uint8_t* p = buffer;
    memcpy(p, "OpusHead", 8);
    p += 8;
    p[0] = 1; // version
    ++p;
    p[0] = channels;
    ++p;
    writeLE16(p, preskip);
    p += 2;
    writeLE32(p, sampleRate);
    p += 4;
    p[0] = 0; // output gain
    p[1] = 0;
    p += 2;
    p[0] = 0; // map family
    ++p;
    put(buffer, p - buffer, 0, 1);
  }

  void createTags(const string& vendor, vector<string>& comments) {
    constexpr uint32_t bufsize = 4096;
    uint8_t* buffer = new uint8_t[bufsize];
    uint8_t* p = buffer;
    memcpy(p, "OpusTags", 8);
    p += 8;
    writeLE32(p, vendor.length());
    p += 4;
    memcpy(p, vendor.c_str(), vendor.length());
    p += vendor.length();
    writeLE32(p, comments.size());
    p += 4;
    auto it = comments.begin();
    while (it != comments.end()) {
      writeLE32(p, it->length());
      p += 4;
      memcpy(p, it->c_str(), it->length());
      p += it->length();
      ++it;
    }
    put(buffer, p - buffer, 0, 4);
    delete[] buffer;
  }

  /// \param flags bit 0 - bos
  ///                  1 - eos
  ///                  2 - flush
  void put(uint8_t* data, uint32_t size, uint64_t gp = 0, uint32_t flags = 0) {
    ogg_packet pack;
    memset(&pack, 0, sizeof(pack));
    pack.packet = data;
    pack.bytes = size;
    pack.e_o_s = (flags & 2) ? 1 : 0;
    pack.b_o_s = (flags & 1) ? 1 : 0;
    pack.granulepos = gp;
    pack.packetno = numPacket++;
    ogg_stream_packetin(&oggStream, &pack);
    ogg_page page;
    int r;
    if (flags & 4) {
      r = ogg_stream_flush(&oggStream, &page);
    } else  {
      r = ogg_stream_pageout_fill(&oggStream, &page, oggPacketThreshold);
    }
    if (r == 1) {
      oggPageOut(page);
      // callback(page.header, page.header_len, page.body, page.body_len);
    }
  }

  void oggPageOut(ogg_page& page) {
    if (page.header_len + page.body_len < OGG_BUFSIZE) {
      memcpy(oggBuffer, page.header, page.header_len);
      memcpy(oggBuffer + page.header_len, page.body, page.body_len);
      gotoNext(oggBuffer, page.header_len + page.body_len);
    } else {
      KLOGE(TAG, "ogg buffer not enough: %u/%u", OGG_BUFSIZE,
          page.header_len + page.body_len);
    }
  }

  void encode(const opus_int16* in, uint32_t samples, uint32_t flags) {
    uint8_t opusBuffer[OPUS_BUFSIZE];
    samples = validOpusSamples(samples);
    if (samples == 0) {
      if (flags)
        put(nullptr, 0, flags);
      return;
    }
    auto c = opus_encode(opusEncoder, in, samples,
        (unsigned char*)opusBuffer, sizeof(opusBuffer));
    gp += samples * 48000 / sampleRate;
    if (c > 0) {
      KLOGD(TAG, "OpusEncode: put opus packet %u bytes to ogg", c);
      put(opusBuffer, c, gp, flags);
    } else {
      KLOGE(TAG, "OpusEncode: failed: %d, input %u samples", c, samples);
    }
  }

  uint32_t validOpusSamples(uint32_t count) {
    uint32_t i;
    for (i = 0; i < NUMBER_OF_VALID_OPUS_ENCODE_SAMPLES; ++i) {
      if (count >= VALID_OPUS_ENCODE_SAMPLES[i])
        return VALID_OPUS_ENCODE_SAMPLES[i];
    }
    return 0;
  }

  static void writeLE16(uint8_t* ptr, uint16_t v) {
    ptr[0] = v & 0xff;
    ptr[1] = v >> 8;
  }

  static void writeLE32(uint8_t* ptr, uint32_t v) {
    ptr[0] = v & 0xff;
    ptr[1] = (v >> 8) & 0xff;
    ptr[2] = (v >> 16) & 0xff;
    ptr[3] = v >> 24;
  }

private:
  ogg_stream_state oggStream;
  OpusEncoder* opusEncoder;
  uint64_t gp{0};
  bool createHead{true};
  static constexpr uint32_t OPUS_BUFSIZE = 400;
  static constexpr uint32_t OGG_BUFSIZE = 2048;
  uint8_t oggBuffer[OGG_BUFSIZE];
  uint32_t oggPacketThreshold;
  ogg_int64_t numPacket{0};
  uint32_t channels;
  uint32_t MAX_OPUS_ENCODE_BYTES;
  // opus_encode输入最大单位: 20ms数据
  static constexpr uint32_t MAX_OPUS_ENCODE_SAMPLES = 320;
  // Opus can encode frames of 2.5, 5, 10, 20, 40, or 60 ms
  static constexpr uint32_t NUMBER_OF_VALID_OPUS_ENCODE_SAMPLES = 6;
  static constexpr uint32_t VALID_OPUS_ENCODE_SAMPLES[] = {
    960, 640, 320, 160, 80, 40
  };
  uint8_t* processBuffer;
  uint32_t processPos{0};
};

class OggDecodeProcessor : public AudioProcessor {
public:
  OggDecodeProcessor(uint32_t chn) {
    channels = chn;
    ogg_sync_init(&syncState);
    ogg_stream_init(&streamState, 0);
    int err{0};
    opusDecoder = opus_decoder_create(sampleRate, chn, &err);
    pcmBuffer = new opus_int16[MAX_SAMPLES_PER_OPUS_PACKET * chn];
  }

  ~OggDecodeProcessor() {
    delete[] pcmBuffer;
    opus_decoder_destroy(opusDecoder);
    ogg_stream_clear(&streamState);
    ogg_sync_clear(&syncState);
  }

protected:
  void processInner(const uint8_t* in, uint32_t size) {
    auto buf = ogg_sync_buffer(&syncState, size);
    memcpy(buf, in, size);
    KLOGD(TAG, "ogg sync in %u bytes", size);
    ogg_sync_wrote(&syncState, size);
    ogg_page page;
    ogg_packet pack;
    // auto xxdcb = [](const char* str) {
    //   KLOGI(TAG, "%s", str);
    // };
    while (true) {
      auto r = ogg_sync_pageout(&syncState, &page);
      if (r <= 0)
        break;
      auto sn = ogg_page_serialno(&page);
      ogg_stream_reset_serialno(&streamState, sn);
      ogg_stream_pagein(&streamState, &page);
      while (true) {
        auto sr = ogg_stream_packetout(&streamState, &pack);
        if (sr <= 0)
          break;
        KLOGD(TAG, "found packet %ld bytes, seq %" PRIi64, pack.bytes, pack.packetno);
        // mutils::xxd(pack.packet, pack.bytes, xxdcb);
        // skip "OpusHead", "OpusTags"
        if (memcmp(pack.packet, "Opus", 4) == 0)
          continue;
        auto c = opus_decode(opusDecoder, pack.packet, pack.bytes, pcmBuffer,
            MAX_SAMPLES_PER_OPUS_PACKET, 0);
        KLOGD(TAG, "OggDecode gotoNext %u bytes", c * channels * 2);
        gotoNext((uint8_t*)pcmBuffer, c * channels * 2);
      }
    }
  }

private:
  ogg_sync_state syncState;
  ogg_stream_state streamState;
  OpusDecoder* opusDecoder;
  opus_int16* pcmBuffer;
  uint32_t channels;
  static constexpr uint32_t oggSerialno = 0x70000;
  static constexpr uint32_t MAX_SAMPLES_PER_OPUS_PACKET = 1920;
};

class MP3EncodeProcessor : public AudioProcessor {
public:
protected:
  void processInner(const uint8_t* in, uint32_t size) {
    KLOGI(TAG, "MP3EncodeProcessor: input %u bytes", size);
  }
};

#ifdef CXR_SERVER_SIDE
class MP3DecodeProcessor : public AudioProcessor {
public:
  MP3DecodeProcessor() {
    mp3dec_init(&mp3dec);
    decout = new mp3d_sample_t[MINIMP3_MAX_SAMPLES_PER_FRAME];
    monopcm = new int16_t[MINIMP3_MAX_SAMPLES_PER_FRAME / 2];
    uint8_t pp{0};
    permutation.init(2, 1, &pp);
    auto ptr = mmap(nullptr, MP3_INPUT_BUFSIZE, PROT_WRITE | PROT_READ,
        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (ptr != (void*)-1)
      inputBuffer = (uint8_t*)ptr;
    else
      inputBuffer = nullptr;
  }

  ~MP3DecodeProcessor() {
    if (decout)
      delete[] decout;
    if (monopcm)
      delete[] monopcm;
    if (inputBuffer)
      munmap(inputBuffer, MP3_INPUT_BUFSIZE);
  }

protected:
  void processInner(const uint8_t* in, uint32_t size) {
    KLOGD(TAG, "MP3DecodeProcessor: input %u bytes", size);
    totalSize += size;
    if (inputPos + size > MP3_INPUT_BUFSIZE) {
      KLOGW(TAG, "MP3DecodeProcessor: input buffer not enough, %u/%u",
          inputPos + size, MP3_INPUT_BUFSIZE);
      inputPos = 0;
      return;
    }
    memcpy(inputBuffer + inputPos, in, size);
    inputPos += size;

    int fb;
    int frameBytes;
    uint32_t off{0};
    mp3dec_frame_info_t info;
    while (off < inputPos) {
      KLOGD(TAG, "MP3DecodeProcessor: input + %u, size %u", off, inputPos - off);
      auto r = mp3d_find_frame(inputBuffer + off, inputPos - off, &fb, &frameBytes);
      KLOGD(TAG, "MP3DecodeProcessor: find frame %u, start %u", frameBytes, r);
      if (frameBytes) {
        auto samples = mp3dec_decode_frame(&mp3dec, inputBuffer + off + r, frameBytes, decout, &info);
        KLOGD(TAG, "MP3DecodeProcessor: decode frame samples %u, chn %u", samples, info.channels);
        off += (r + frameBytes);
        if (info.channels == 1)
          gotoNext((uint8_t*)decout, samples << 1);
        else if (info.channels == 2) {
          permutation.permutate((int16_t*)decout, monopcm, samples);
          gotoNext((uint8_t*)monopcm, samples << 1);
        }
      } else
        break;
    }
    KLOGD(TAG, "MP3DecodeProcessor: remain %u bytes", inputPos - off);
    if (off < inputPos) {
      memmove(inputBuffer, inputBuffer + off, inputPos - off);
      inputPos -= off;
    } else
      inputPos = 0;
    /**
    uint32_t off{0};
    while (off < inputPos) {
      auto r = mp3dec_decode_frame(&mp3dec, inputBuffer + off, inputPos - off, decout, &info);
      KLOGI(TAG, "MP3DecodeProcessor: return %d, frame bytes %d, off %d, chn %d, hz %d, layer %d, bit %d",
          r, info.frame_bytes, info.frame_offset, info.channels, info.hz, info.layer, info.bitrate_kbps);
      if (r == 0) {
        if (info.frame_offset) {
          off += info.frame_offset;
          continue;
        }
        break;
      }
      off += info.frame_bytes;
    }
    KLOGI(TAG, "MP3DecodeProcessor: remain %u bytes", inputPos - off);
    if (off < inputPos) {
      memmove(inputBuffer, inputBuffer + off, inputPos - off);
      inputPos -= off;
    } else
      inputPos = 0;
      */
  }

  void finish() {
    KLOGI(TAG, "MP3DecodeProcessor: total size %u", totalSize);
    AudioProcessorBase::finish();
  }

private:
  mp3dec_t mp3dec;
  mp3d_sample_t* decout;
  uint8_t* inputBuffer;
  uint32_t inputPos{0};
  int16_t* monopcm;
  Permutation<int16_t> permutation;
  uint32_t totalSize{0};
  static constexpr uint32_t MP3_INPUT_BUFSIZE = 16 * 1024 * 1024;
};

class AgseProcessor : public AudioProcessor {
public:
  AgseProcessor(const string& modelPath, int32_t minGain, int32_t fixedGain,
      int32_t agcMaxGain, int32_t denoiseMode) {
    KLOGI(TAG, "ant aec: model %s, gain { %d, %d, %d }, denoise %d",
        modelPath.c_str(), minGain, fixedGain, agcMaxGain, denoiseMode);
    uint8_t pp[3]{ 4, 5, 2 };
    permutation.init(8, AGSE_CHANNEL, pp);
    agseSamples = new int16_t[AGSE_CHANNEL * SAMPLES_PER_CHANNEL];
    agseOutSamples = new short[SAMPLES_PER_CHANNEL];
    agseOutBufsize = SAMPLES_PER_CHANNEL * sizeof(short);
    int32_t perm[3]{ 0, 1, 2 };
    agseHandle = agse_main_init(AGSE_CHANNEL, perm, modelPath.c_str());
    agse_main_params_t p;
    p.gain_min_dB = minGain;
    p.gain_fixed_dB = fixedGain;
    p.gain_agc_max_dB = agcMaxGain;
    agse_main_set_param(agseHandle, &p);
    agse_main_params_realtime_t rp;
    rp.mode_denoise = denoiseMode;
    agse_main_set_param_realtime(agseHandle, &rp);
  }

  ~AgseProcessor() {
    if (agseSamples)
      delete[] agseSamples;
    if (agseOutSamples)
      delete[] agseOutSamples;
    if (agseHandle)
      agse_main_destroy(agseHandle);
  }

protected:
  void processInner(const uint8_t* in, uint32_t) {
    permutation.permutate((const int16_t*)in, agseSamples, SAMPLES_PER_CHANNEL);
    agse_main_process(agseHandle, (short*)agseSamples, AGSE_CHANNEL,
        SAMPLES_PER_CHANNEL, agseOutSamples);
    KLOGD(TAG, "%s: audio callback %u bytes", __func__, agseOutBufsize);
    gotoNext((uint8_t*)agseOutSamples, agseOutBufsize);
  }

private:
  Permutation<int16_t> permutation;
  int16_t* agseSamples;
  short* agseOutSamples;
  void* agseHandle;
  uint32_t agseOutBufsize;
  static constexpr uint32_t AGSE_CHANNEL = 3;
};

class StoreFileProcessor : public AudioProcessor {
public:
  StoreFileProcessor(const string& name, const string& suffix, int32_t flag) {
    if (flag == 1)
      filename = name + "." + suffix;
    else if (flag == 2) {
      auto nowtp = system_clock::now();
      auto tt = system_clock::to_time_t(nowtp);
      struct tm tm;
      localtime_r(&tt, &tm);
      char fn[64];
      snprintf(fn, sizeof(fn), "%s.%04u%02u%02u%02u%02u%02u.%s",
          name.c_str(), tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
          tm.tm_hour, tm.tm_min, tm.tm_sec, suffix.c_str());
      filename = fn;
    }
    if (filename.empty()) {
      fd = -1;
    } else {
      fd = ::open(filename.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    }
  }

  ~StoreFileProcessor() {
    if (fd >= 0)
      ::close(fd);
  }

protected:
  void processInner(const uint8_t* in, uint32_t size) {
    totalSize += size;
    KLOGD(TAG, "StoreFileProcessor(%s) %u bytes", filename.c_str(), totalSize);
    if (fd >= 0)
      ::write(fd, in, size);
    gotoNext(in, size);
  }

private:
  int32_t fd;
  string filename;
  uint32_t totalSize{0};
};

class RokidAudioNoiseCallback {
public:
  virtual ~RokidAudioNoiseCallback() = default;

  virtual void refreshNoise(float noise) = 0;
};

class RokidAudioProcessor : public AudioProcessor {
public:
  /// \param outMode: 0 输出一路, 全向
  /// \param          1 输出一路, 近场
  /// \param          2 输出二路, 全向+参考(agc)
  RokidAudioProcessor(const string& modelPath, uint8_t dtlnAEC, uint8_t bf,
      uint32_t outMode, RokidAudioNoiseCallback* cb) {
#ifdef __aarch64__
    Rokid_Audio_Config cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.bAecOpen = 0;
    cfg.bDtlnAecOpen = dtlnAEC;
    cfg.bAgcOpen = 0;
    cfg.bBfOpen = bf;
    cfg.bPreAecOpen = 1;
    strcpy(cfg.BfConfig.model_path, modelPath.c_str());
    strcpy(cfg.DtlnAecConfig.model_path, modelPath.c_str());
    KLOGI(TAG, "RokidAudioSDK: dtlnAEC %u, bf %u, model path %s, outMode %u",
        dtlnAEC, bf, modelPath.c_str(), outMode);
    rokid_audio_init(&cfg);

    inputBuffer = new int16_t[INPUT_BUFFER_SAMPLES * PROC_INPUT_CHANNELS];
    sdkMicInBuffer = new int16_t[PROC_SAMPLES * MIC_CHANNELS];
    sdkSpkInBuffer = new int16_t[PROC_SAMPLES * SPEAKER_CHANNELS];
    sdkOutBuffer = new int16_t[PROC_SAMPLES * OUTPUT_CHANNELS];
    uint8_t mp[MIC_CHANNELS]{ 2, 3, 4, 5 };
    micPerm.init(PROC_INPUT_CHANNELS, MIC_CHANNELS, mp);
    uint8_t sp[SPEAKER_CHANNELS]{ 6, 7 };
    speakerPerm.init(PROC_INPUT_CHANNELS, SPEAKER_CHANNELS, sp);
    uint8_t op[2]{0, 0};
    if (outMode == 1) {
      op[0] = 2;
      outPerm.init(OUTPUT_CHANNELS, 1, op);
      outBuffer = new int16_t[PROC_SAMPLES];
      outBufsize = PROC_SAMPLES * 2;
    } else if (outMode == 2) {
      op[0] = 0;
      op[1] = 1;
      outPerm.init(OUTPUT_CHANNELS, 2, op);
      outBuffer = new int16_t[PROC_SAMPLES * 2];
      outBufsize = PROC_SAMPLES * 4;
    } else {
      op[0] = 0;
      outPerm.init(OUTPUT_CHANNELS, 1, op);
      outBuffer = new int16_t[PROC_SAMPLES];
      outBufsize = PROC_SAMPLES * 2;
    }
    sdkOutMode = outMode;
    noiseCallback = cb;
    KLOGI(TAG, "init rokid audio sdk: out mode %u", outMode);
#endif
  }

  ~RokidAudioProcessor() {
#ifdef __aarch64__
    rokid_audio_deinit();
    if (inputBuffer)
      delete[] inputBuffer;
    if (sdkMicInBuffer)
      delete[] sdkMicInBuffer;
    if (sdkSpkInBuffer)
      delete[] sdkSpkInBuffer;
    if (sdkOutBuffer)
      delete[] sdkOutBuffer;
    if (outBuffer)
      delete[] outBuffer;
#endif
  }

protected:
  void processInner(const uint8_t* in, uint32_t size) {
#ifdef __aarch64__
    memcpy(inputBuffer + inputPos, in, size);
    uint32_t inSamples = size >> 1;
    inputPos += inSamples;
    KLOGD(TAG, "RokidAudioProcessor: input buffer has %u samples(per channel)", inputPos / PROC_INPUT_CHANNELS);
    uint32_t costSamples = PROC_SAMPLES * PROC_INPUT_CHANNELS;
    float noise;
    // 环境噪声, 可能需要在眼镜端显示, 暂时忽略
    while (procPos + costSamples <= inputPos) {
      micPerm.permutate(inputBuffer + procPos, sdkMicInBuffer, PROC_SAMPLES);
      speakerPerm.permutate(inputBuffer + procPos, sdkSpkInBuffer, PROC_SAMPLES);
      rokid_audio_work(sdkMicInBuffer, sdkSpkInBuffer, sdkOutBuffer, &noise);
      noiseCallback->refreshNoise(noise);
      procPos += costSamples;
      // outPerm.permutate(sdkOutBuffer, outBuffer, PROC_SAMPLES);
      if (sdkOutMode == 1)
        memcpy(outBuffer, sdkOutBuffer + PROC_SAMPLES * 2, outBufsize);
      else if (sdkOutMode == 2) {
        auto op = outBuffer;
        auto p0 = sdkOutBuffer;
        auto p1 = sdkOutBuffer + PROC_SAMPLES;
        for (uint32_t i = 0; i < PROC_SAMPLES; ++i) {
          op[0] = *p0;
          op[1] = *p1;
          op += 2;
          ++p0;
          ++p1;
        }
      } else
        memcpy(outBuffer, sdkOutBuffer, outBufsize);
      gotoNext((uint8_t*)outBuffer, outBufsize);
    }
    if (procPos == inputPos) {
      procPos = 0;
      inputPos = 0;
    }
#endif
  }

private:
#ifdef __aarch64__
  static constexpr uint32_t PROC_SAMPLES = 128;
  // Processor模块输入是320 samples
  // sdk的输入是128 samples
  // 所以buffer取128与320最小公倍数
  static constexpr uint32_t INPUT_BUFFER_SAMPLES = 640;
  static constexpr uint32_t PROC_INPUT_CHANNELS = 8;
  static constexpr uint32_t MIC_CHANNELS = 4;
  static constexpr uint32_t SPEAKER_CHANNELS = 2;
  static constexpr uint32_t OUTPUT_CHANNELS = 3;
  int16_t* inputBuffer;
  uint32_t inputPos{0};
  uint32_t procPos{0};
  int16_t* sdkMicInBuffer;
  int16_t* sdkSpkInBuffer;
  int16_t* sdkOutBuffer;
  int16_t* outBuffer;
  uint32_t outBufsize;
  Permutation<int16_t> micPerm;
  Permutation<int16_t> speakerPerm;
  Permutation<int16_t> outPerm;
  uint32_t sdkOutMode;
  RokidAudioNoiseCallback* noiseCallback;
#endif
};

typedef struct {
  string aec_path;
  string ans_path;
  int32_t pregain;
  int32_t target_level;
  int32_t noise_floor;
  int32_t max_gain;
} AntOmniParam;
class AntOmniProcessor : public AudioProcessor {
public:
  AntOmniProcessor(const AntOmniParam& param) {
    KLOGI(TAG, "ant omni: aec %s, ans %s, params { %d %d %d %d }",
        param.aec_path.c_str(), param.ans_path.c_str(),
        param.target_level, param.noise_floor, param.max_gain, param.pregain);
    uint8_t pp[4]{ 2, 4, 5, 6 };
    inputPerm.init(8, INPUT_CHANNEL, pp);
    refPerm.init(8, REF_CHANNEL, pp + INPUT_CHANNEL);
    inputSamples = new int16_t[INPUT_CHANNEL * OMNI_SAMPLES_PER_CHANNEL];
    refSamples = new int16_t[REF_CHANNEL * OMNI_SAMPLES_PER_CHANNEL];
    outSamples = new short[OMNI_SAMPLES_PER_CHANNEL];
    outBufsize = OMNI_SAMPLES_PER_CHANNEL * sizeof(short);
    ANT_ROKID_OMNISTRU_PARAM omniParam;
    ans_path = param.ans_path;
    aec_path = param.aec_path;
    omniParam.ans_path = (char*)ans_path.c_str();
    omniParam.aec_path = (char*)aec_path.c_str();
    omniParam.aec_enable = 1;
    omniParam.ans_enable = 1;
    omniParam.agc_enable = 1;
    omniParam.target_level = param.target_level;
    omniParam.noise_floor = param.noise_floor;
    omniParam.max_gain = param.max_gain;
    omniParam.pregain = param.pregain;

    auto sz = ant_rokid_omni_getchansize();
    omniHandle = malloc(sz);
    auto r = ant_rokid_omni_init(omniHandle, &omniParam);
    KLOGI(TAG, "ant_rokid_omni_init return %d", r);
  }

  ~AntOmniProcessor() {
    if (inputSamples)
      delete[] inputSamples;
    if (refSamples)
      delete[] refSamples;
    if (outSamples)
      delete[] outSamples;
    if (omniHandle) {
      ant_rokid_omni_release(omniHandle);
      free(omniHandle);
    }
  }

protected:
  void processInner(const uint8_t* in, uint32_t) {
    /// 一次输入320采样返回-22错误
    /// 只能改成一次输入160采样
    uint32_t off{0};
    for (uint32_t i = 0; i < 2; ++i) {
      inputPerm.permutate((const int16_t*)(in + off), inputSamples, OMNI_SAMPLES_PER_CHANNEL);
      refPerm.permutate((const int16_t*)(in + off), refSamples, OMNI_SAMPLES_PER_CHANNEL);
      auto r = ant_rokid_omni_apply(omniHandle, (short*)inputSamples, INPUT_CHANNEL,
          (short*)refSamples, REF_CHANNEL, OMNI_SAMPLES_PER_CHANNEL, outSamples);
      KLOGD(TAG, "ant_rokid_omni_apply return %d", r);
      gotoNext((uint8_t*)outSamples, outBufsize);
      off += OMNI_SAMPLES_PER_CHANNEL * 8 * 2;
    }
  }

private:
  Permutation<int16_t> inputPerm;
  Permutation<int16_t> refPerm;
  int16_t* inputSamples;
  int16_t* refSamples;
  short* outSamples;
  void* omniHandle;
  uint32_t outBufsize;
  string aec_path;
  string ans_path;
  static constexpr uint32_t INPUT_CHANNEL = 3;
  static constexpr uint32_t REF_CHANNEL = 1;
  static constexpr uint32_t OMNI_SAMPLES_PER_CHANNEL = 160;
};

class XunfeiCAEProcessor : public AudioProcessor {
public:
  XunfeiCAEProcessor(const string& sn, const string& workdir) {
#ifdef __aarch64__
    KLOGI(TAG, "xunfei cae sdk version: %s", vtn_api_get_version());
    inputBuffer1 = new int16_t[RECORD_CHANNEL * PROC_SAMPLES];
    inputBuffer2 = new int16_t[INPUT_CHANNEL * PROC_SAMPLES];
    outputBuffer = new int16_t[PROC_SAMPLES];
    const char* fmt = R"({ "params": { "appid": "%s", "sn": "%s", "work_dir": "%s" } })";
    auto c = snprintf((char*)inputBuffer1, RECORD_CHANNEL * PROC_SAMPLES * 2,
        fmt, "42029a9d", sn.c_str(), workdir.c_str());
    KLOGI(TAG, "xunfei cae init(%d):\n%s", c, (char*)inputBuffer1);
    vtn_init_param_t param;
    param.params.in = (char*)inputBuffer1;
    param.params.in_size = c;
    param.params.out = nullptr;
    param.params.out_size = 0;
    param.callback.user_data = this;
    param.callback.handler = cae_callback;
    handle = 0;
    auto r = vtn_api_init(&handle, &param);
    KLOGI(TAG, "vtn_api_init return %d, handle %p", r, handle);
    if (r)
      handle = 0;
    uint8_t pp[INPUT_CHANNEL]{ 2, 3, 4, 5, 6, 7 };
    inputPerm.init(8, INPUT_CHANNEL, pp);
#endif
  }

  ~XunfeiCAEProcessor() {
#ifdef __aarch64__
    if (handle) {
      KLOGI(TAG, "vtn_api_destroy %p", handle);
      vtn_api_destroy(handle);
    }
    if (inputBuffer1)
      delete[] inputBuffer1;
    if (inputBuffer2)
      delete[] inputBuffer2;
    if (outputBuffer)
      delete[] outputBuffer;
#endif
  }

protected:
  void processInner(const uint8_t* in, uint32_t size) {
#ifdef __aarch64__
    if (handle == 0)
      return;
    static constexpr uint32_t maxCopySize = RECORD_CHANNEL * PROC_SAMPLES * 2;
    uint32_t cpsz;
    uint32_t off{0};
    vtn_interact_info_t info;
    memset(&info, 0, sizeof(info));
    info.in.raw_size = INPUT_CHANNEL * PROC_SAMPLES * 2;
    while (off < size) {
      auto remain = size - off;
      if (remain > maxCopySize - inPos)
        cpsz = maxCopySize - inPos;
      else
        cpsz = remain;
      memcpy(reinterpret_cast<uint8_t*>(inputBuffer1) + inPos, in + off, cpsz);
      off += cpsz;
      inPos += cpsz;
      // 不足256 samples, 保留数据, 不处理
      if (inPos < maxCopySize)
        break;
      inputPerm.permutate(inputBuffer1, inputBuffer2, PROC_SAMPLES);
      inPos = 0;
      info.type = VTN_INTERACT_TYPE_FEED_AUDIO;
      info.in.raw = inputBuffer2;
      auto r = vtn_api_interact(handle, &info);
      if (r != VTN_STATUS_SUCCESS) {
        KLOGE(TAG, "xunfei cae处理失败: %d", r);
      }
    }
#endif
  }

private:
#ifdef __aarch64__
  static int cae_callback(vtn_callback_data_t* datap, void* userp) {
    if (datap == nullptr)
      return -1;
    if (datap->type == VTN_CALLBACK_TYPE_AUDIO_CAE) {
      reinterpret_cast<XunfeiCAEProcessor*>(userp)->cae_data_callback(
          datap->data, datap->data_size);
      return 0;
    }
    KLOGI(TAG, "cae未知类型回调: %d", datap->type);
    return 0;
  }

  void cae_data_callback(void* data, int size) {
    gotoNext((uint8_t*)data, size);
  }
#endif

private:
#ifdef __aarch64__
  vtn_handle handle;
  Permutation<int16_t> inputPerm;
  // 8路pcm, 256 samples
  int16_t* inputBuffer1;
  // 6路pcm, 256 samples
  int16_t* inputBuffer2;
  // 1路pcm, 256 samples
  int16_t* outputBuffer;
  uint32_t inPos{0};
  static constexpr uint32_t RECORD_CHANNEL = 8;
  static constexpr uint32_t INPUT_CHANNEL = 6;
  static constexpr uint32_t PROC_SAMPLES = 256;
#endif
};

/// 无障碍模式
/// 取0, 6两路音频
class A11yProcessor : public AudioProcessor {
public:
  A11yProcessor() {
    uint8_t pp[2]{ 0, 6 };
    perm.init(8, 2, pp);
  }

protected:
  void processInner(const uint8_t* in, uint32_t size) {
    auto numSamples = size / 16;
    uint32_t off{0};
    uint32_t procSamples;
    // 每次处理FIXED_SAMPLES, 如剩余数据不足FIXED_SAMPLES
    // 存入buffer留到下次processInner
    while (numSamples) {
      procSamples = FIXED_SAMPLES - writePos / 2;
      if (procSamples > numSamples)
        procSamples = numSamples;
      perm.permutate((int16_t*)(in + off), buffer + writePos, procSamples);
      if (procSamples < FIXED_SAMPLES) {
        writePos = procSamples * 2;
        break;
      }
      numSamples -= procSamples;
      off += procSamples * 16;
      writePos = 0;
      gotoNext((uint8_t*)buffer, FIXED_SAMPLES * 4);
    }
  }

private:
  static constexpr uint32_t FIXED_SAMPLES = 320;

  Permutation<int16_t> perm;
  int16_t buffer[FIXED_SAMPLES * 2];
  uint32_t writePos{0};
};

class RokidAGCProcessor : public AudioProcessor {
public:
  RokidAGCProcessor(float factor1, float factor2) {
#ifdef __aarch64__
    static bool agc_created = false;
    uint8_t pp{1};
    perm.init(2, 1, &pp);
    // target_gain_scaling_factor = factor1;
    amplitude_conversion_factor = factor2;
    if (!agc_created) {
      agc_created = true;
      VadBeforeAgc_Create_Instance();
      AutoGainControl_Create_Instance(factor1);
    }
#endif
  }

protected:
  void processInner(const uint8_t* in, uint32_t size) {
#ifdef __aarch64__
    // NOTE: 输入为两路, 固定320 samples
    // 对第二路做agc
    perm.permutate((const int16_t*)in, buffer, FIXED_SAMPLES);
    AutoLevelControl_FrameProcess(buffer, alcBuffer, amplitude_conversion_factor);
    auto vad = VadBeforeAgc_FrameProcess(alcBuffer);
    AutoGainControl_FrameProcess(alcBuffer, agcBuffer, vad);
    auto p1 = (const int16_t*)in;
    auto p2 = outBuffer;
    for (uint32_t i = 0; i < FIXED_SAMPLES; ++i) {
      p2[0] = p1[0];
      p2[1] = agcBuffer[i];
      p1 += 2;
      p2 += 2;
    }
    gotoNext((uint8_t*)outBuffer, FIXED_SAMPLES * 4);
#endif
  }

private:
#ifdef __aarch64__
  static constexpr uint32_t FIXED_SAMPLES = 320;

  Permutation<int16_t> perm;
  int16_t buffer[FIXED_SAMPLES];
  int16_t alcBuffer[FIXED_SAMPLES];
  int16_t agcBuffer[FIXED_SAMPLES];
  int16_t outBuffer[FIXED_SAMPLES * 2];
  float amplitude_conversion_factor;
#endif
};
#endif // CXR_SERVER_SIDE
