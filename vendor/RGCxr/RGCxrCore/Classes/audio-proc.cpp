#define MINIMP3_IMPLEMENTATION
#include "audio-proc.h"

void AudioProcessorBase::finish() {
  if (finished)
    return;
  finished = true;
  if (output != nullptr)
    output->finish();
  else if (callback != nullptr)
    callback(nullptr, 0);
}

void AudioProcessorBase::gotoNext(const uint8_t* in, uint32_t size) {
  if (output != nullptr)
    output->process(in, size);
  else if (callback != nullptr)
    callback(in, size);
}
