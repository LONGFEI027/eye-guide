#pragma once

#ifdef CXR_PLATFORM_APPLE

typedef void (*LogFunc)(const char*, ...);
extern LogFunc logFunc;

#ifndef ROKID_LOG_ENABLED
#define ROKID_LOG_ENABLED 1
#endif

// #define RLOG_PRINT(lv, tag, fmt, ...)  android_log_print(__FILE__, __LINE__, lv, tag, fmt, ##__VA_ARGS__)
#define RLOG_PRINT(lv, tag, fmt, ...)  logFunc(fmt, ##__VA_ARGS__)

#if ROKID_LOG_ENABLED <= 0
#define KLOGV(tag, fmt, ...) RLOG_PRINT(ROKID_LOGLEVEL_VERBOSE, tag, fmt, ##__VA_ARGS__)
#else
#define KLOGV(tag, fmt, ...)
#endif

#if ROKID_LOG_ENABLED <= 1
#define KLOGD(tag, fmt, ...) RLOG_PRINT(ROKID_LOGLEVEL_DEBUG, tag, fmt, ##__VA_ARGS__)
#else
#define KLOGD(tag, fmt, ...)
#endif

#if ROKID_LOG_ENABLED <= 2
#define KLOGI(tag, fmt, ...) RLOG_PRINT(ROKID_LOGLEVEL_INFO, tag, fmt, ##__VA_ARGS__)
#else
#define KLOGI(tag, fmt, ...)
#endif

#if ROKID_LOG_ENABLED <= 3
#define KLOGW(tag, fmt, ...) RLOG_PRINT(ROKID_LOGLEVEL_WARNING, tag, fmt, ##__VA_ARGS__)
#else
#define KLOGW(tag, fmt, ...)
#endif

#if ROKID_LOG_ENABLED <= 4
#define KLOGE(tag, fmt, ...) RLOG_PRINT(ROKID_LOGLEVEL_ERROR, tag, fmt, ##__VA_ARGS__)
#else
#define KLOGE(tag, fmt, ...)
#endif

#else // CXR_PLATFORM_APPLE
#include "rlog.h"
#endif // CXR_PLATFORM_APPLE
