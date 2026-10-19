#pragma once

#include <stdint.h>
#include <list>
#include "cxr-config.h"
#include "caps.h"
#include "apple-log.h"

using namespace rokid;
using namespace std;

class ARTCFrame {
public:
  // 用于发送
  ARTCFrame(uint32_t k, uint8_t* d, uint32_t s, uint64_t ts) {
    key = k;
    data = d;
    dataSize = s;
    timestamp = ts / 1000000;
    writePos = 0;
    firstSend = 1;
  }

  // 用于接收
  ARTCFrame(uint32_t k, uint32_t s, uint64_t ts1, uint64_t ts2) {
    key = k;
    dataSize = s;
    if (s)
      data = new uint8_t[s];
    timestamp = ts1;
    sendTime = ts2;
    writePos = 0;
    firstSend = 0;
  }

  ~ARTCFrame() {
    if (data)
      delete[] data;
  }

#ifdef CXR_SERVER_SIDE
  int32_t createPack(Caps& out);
#else
  int32_t createPack(Caps& out) { return -1; }
#endif

  static constexpr uint32_t MAX_PACKET_SIZE = 490;

public:
  uint32_t key;
  uint8_t* data;
  uint32_t dataSize;
  uint64_t timestamp;
  uint64_t sendTime;
  uint32_t writePos:31;
  uint32_t firstSend:1;
};

class ARTCFrameQueue {
public:
  void add(uint32_t key, uint8_t* data, uint32_t size, uint64_t ts) {
    ++added;
    frames.emplace_back(key, data, size, ts);
  }

  inline bool empty() const {
    return frames.empty();
  }

  inline void pop_front() {
    frames.pop_front();
  }

  inline void clear() {
    frames.clear();
    erased = 0;
    added = 0;
    reset = false;
  }

  uint32_t frontSize() const {
    if (frames.empty())
      return 0;
    return frames.front().dataSize;
  }

  inline int32_t createPack(Caps& out) {
    return frames.front().createPack(out);
  }

  void tryDropFrame() {
    auto size = frames.size();
    if (size < CXRConfig::artc.frame_queue_size)
      return;
    auto rmc = size - CXRConfig::artc.frame_queue_size + 1;
    auto it = frames.begin();
    while (rmc) {
      // 首个frame不删, 正在发送
      ++it;
      if (it == frames.end())
        break;
      if (it->key == 0) {
        it = frames.erase(it);
        ++erased;
        --rmc;
        continue;
      }
    }
    // 非关键帧都删了, 队列仍满
    // 此时清空队列(除队列首帧外)
    if (rmc) {
      it = frames.begin();
      ++it;
      while (it != frames.end()) {
        it = frames.erase(it);
        ++erased;
        reset = true;
      }
    }
  }

  float getSentRate(bool* isReset) {
    if (added == 0)
      return -1.0;
    auto rate = (float)(added - erased)/(float)added;
    KLOGI("cxr-service", "%s: (%u - %u) / %u = %f", __func__, added, erased, added, rate);
    added = 0;
    erased = 0;
    *isReset = reset;
    reset = false;
    return rate;
  }

private:
  list<ARTCFrame> frames;
  uint32_t added{0};
  uint32_t erased{0};
  bool reset{false};
};

class RecvARTCFrame {
public:
  int32_t create(Caps& pack) {
    if (frame)
      delete frame;
    uint32_t size = pack[1];
    uint32_t key = pack[2];
    uint64_t ts1 = pack[3];
    uint64_t ts2 = pack[4];
    frame = new ARTCFrame(key, size, ts1, ts2);
    return 0;
  }

  int32_t write(Caps& pack, bool isLast) {
    if (frame == nullptr)
      return -101;
    auto size = pack[1].size();
    if (isLast) {
      if (frame->writePos + size != frame->dataSize)
        return -102;
    } else {
      if (frame->writePos + size >= frame->dataSize)
        return -103;
    }
    pack[1].read(frame->data + frame->writePos, size);
    frame->writePos += size;
    return 0;
  }

  ARTCFrame* getFrame() {
    auto res = frame;
    frame = nullptr;
    return res;
  }

  ARTCFrame* frame{nullptr};
};
