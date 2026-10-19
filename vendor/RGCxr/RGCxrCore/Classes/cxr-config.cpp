#ifdef CXR_SERVER_SIDE
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <json/json.h>
#include "rlog.h"
#endif
#include "cxr-config.h"

#define TAG "cxr-config"

#ifdef CXR_SERVER_SIDE
using namespace Json;
#endif

CXRConfig::CXR CXRConfig::cxr;
CXRConfig::CXRProto CXRConfig::cxrproto;
CXRConfig::MFI CXRConfig::mfi;
CXRConfig::GATT CXRConfig::gatt;
CXRConfig::ARTC CXRConfig::artc;
CXRConfig::Audio CXRConfig::audio;
bool CXRConfig::initialized = false;

bool CXRConfig::ready() {
  return initialized;
}

void CXRConfig::initialize(const char* file) {
  setDefaultValues();
  initialized = true;
#ifdef CXR_SERVER_SIDE
  if (file == nullptr)
    return;
  auto fd = ::open(file, O_RDONLY);
  if (fd < 0) {
    KLOGE(TAG, "open cxr config file %s failed: %d/%s",
        file, errno, strerror(errno));
    return;
  }
  auto sz = lseek(fd, 0, SEEK_END);
  lseek(fd, 0, SEEK_SET);
  if (sz <= 0) {
    ::close(fd);
    return;
  }
  auto buffer = new char[sz];
  ::read(fd, buffer, sz);
  ::close(fd);
  parseConfig(buffer, sz);
  delete[] buffer;
#endif
}

void CXRConfig::setDefaultValues() {
  cxr.client_connection_info_storage_path_compatible = "/sdcard";
  cxr.client_connection_info_storage_path = ".";
  cxr.client_connection_info_file = "cxr.connection.data";
  cxr.socket_read_buffer_size = 1024;
  cxr.mtu[0] = 4096;
  cxr.mtu[1] = 500;
  cxr.mtu[1] = 4080;
  cxrproto.recv_buffer_size = 0x400000;
  cxrproto.send_buffer_size = 0x200000;
  cxrproto.auth_send_buffer_size = 1024;
  mfi.detect_acp = true;
  mfi.connect_timeout = 30000;
  mfi.connect_retry_interval = 2000;
  mfi.send_buffer_size = 0x200000;
  mfi.recv_buffer_size = 0x400000;
  mfi.rokid_team_id = "ZZEB3P6V4Y";
  mfi.manufacture = "Hangzhou Lingban Technology Co., Ltd.";
  mfi.firmware_version = "1.0";
  mfi.hardware_version = "1.0";
  gatt.notify_timeout = 600;
  artc.frame_queue_size = 12;
  // 客户端audio buffer, 可以大一些
  audio.send_buffer_size = 0x800000;
  audio.recv_buffer_size = 192000;
  audio.ogg_packet_threshold = 40;
  audio.send_audio_stream_mtu = 3200;
  audio.ant_aec.gain_min_dB = -60;
  audio.ant_aec.gain_fixed_dB = 6;
  audio.ant_aec.gain_agc_max_dB = 6;
  audio.ant_aec.denoise_mode = 2;
  audio.rokid_aec.refresh_noise_interval = 1000;
  audio.ant_omni.target_level = -12;
  audio.ant_omni.noise_floor = -50;
  audio.ant_omni.max_gain = 20;
  audio.ant_omni.pregain = 15;
  audio.rokid_agc.amplitude_conversion_factor = 4.0;
  audio.rokid_agc.target_gain_scaling_factor = 0.9;
}

#ifdef CXR_SERVER_SIDE
void CXRConfig::parseConfig(const char* json, uint32_t size) {
  CharReaderBuilder builder;
  builder["collectComments"] = false;
  auto reader = builder.newCharReader();
  Value root;
  String errs;
  if (!reader->parse(json, json + size, &root, &errs)) {
    KLOGE(TAG, "parse config json failed: %s", errs.c_str());
    return;
  }
  auto jcxr = root["cxr"];
  if (jcxr.isObject()) {
    auto v = jcxr["client_connection_info_storage_path"];
    if (v.isString())
      cxr.client_connection_info_storage_path = v.asString();
    v = jcxr["client_connection_info_storage_path_compatible"];
    if (v.isString())
      cxr.client_connection_info_storage_path_compatible = v.asString();
    v = jcxr["client_connection_info_file"];
    if (v.isString())
      cxr.client_connection_info_file = v.asString();
    v = jcxr["socket_read_buffer_size"];
    if (v.isInt())
      cxr.socket_read_buffer_size = v.asUInt();
    auto jmtu = jcxr["mtu"];
    if (jmtu.isObject()) {
      v = jmtu["android"];
      if (v.isInt())
        cxr.mtu[0] = v.asUInt();
      v = jmtu["iphone_gatt"];
      if (v.isInt())
        cxr.mtu[1] = v.asUInt();
      v = jmtu["iphone_socket"];
      if (v.isInt())
        cxr.mtu[2] = v.asUInt();
    }
  }
  auto jcxrproto = root["cxrproto"];
  if (jcxrproto.isObject()) {
    auto v = jcxrproto["recv_buffer_size"];
    if (v.isInt())
      cxrproto.recv_buffer_size = v.asUInt();
    v = jcxrproto["send_buffer_size"];
    if (v.isInt())
      cxrproto.send_buffer_size = v.asUInt();
    v = jcxrproto["auth_send_buffer_size"];
    if (v.isInt())
      cxrproto.auth_send_buffer_size = v.asUInt();
  }
  auto jmfi = root["mfi"];
  if (jmfi.isObject()) {
    auto v = jmfi["detect_acp"];
    if (v.isBool())
      mfi.detect_acp = v.asBool();
    v = jmfi["connect_timeout"];
    if (v.isInt())
      mfi.connect_timeout = v.asUInt();
    v = jmfi["connect_retry_interval"];
    if (v.isInt())
      mfi.connect_retry_interval = v.asUInt();
    v = jmfi["send_buffer_size"];
    if (v.isInt())
      mfi.send_buffer_size = v.asUInt();
    v = jmfi["recv_buffer_size"];
    if (v.isInt())
      mfi.recv_buffer_size = v.asUInt();
    v = jmfi["rokid_team_id"];
    if (v.isString())
      mfi.rokid_team_id = v.asString();
    v = jmfi["manufacture"];
    if (v.isString())
      mfi.manufacture = v.asString();
    v = jmfi["firmware_version"];
    if (v.isString())
      mfi.firmware_version = v.asString();
    v = jmfi["hardware_version"];
    if (v.isString())
      mfi.hardware_version = v.asString();
    auto jeap = jmfi["eap"];
    if (jeap.isArray()) {
      ExternalAccessoryProtocol ieap;
      for (ArrayIndex i = 0; i < jeap.size(); ++i) {
        auto item = jeap[i];
        if (!item.isObject())
          continue;
        v = item["id"];
        if (!v.isInt())
          continue;
        ieap.id = v.asUInt();
        v = item["name"];
        if (!v.isString())
          continue;
        ieap.name = v.asString();
        v = item["match_action"];
        if (!v.isInt())
          continue;
        ieap.match_action = v.asUInt();
        v = item["app_bundle_id"];
        if (!v.isString())
          continue;
        ieap.app_bundle_id = v.asString();
        mfi.eap.push_back(ieap);
      }
    }
    auto jii = jmfi["identification_information"];
    if (jii.isArray()) {
      IdentificationInformation ii;
      for (ArrayIndex i = 0; i < jii.size(); ++i) {
        auto item = jii[i];
        if (!item.isObject())
          continue;
        v = item["name"];
        if (!v.isString())
          continue;
        ii.name = v.asString();
        v = item["model_id"];
        if (!v.isString())
          continue;
        ii.model_id = v.asString();
        v = item["product_plan_uid"];
        if (!v.isString())
          continue;
        ii.product_plan_uid = v.asString();
        mfi.identification_information.push_back(ii);
      }
    }
  }
  auto jgatt = root["gatt"];
  if (jgatt.isObject()) {
    auto v = jgatt["notify_timeout"];
    if (v.isInt())
      gatt.notify_timeout = v.asUInt();
  }
  auto jartc = root["artc"];
  if (jartc.isObject()) {
    auto v = jartc["frame_queue_size"];
    if (v.isInt())
      artc.frame_queue_size = v.asUInt();
  }
  auto jaudio = root["audio"];
  if (jaudio.isObject()) {
    auto v = jaudio["send_buffer_size"];
    if (v.isInt())
      audio.send_buffer_size = v.asUInt();
    v = jaudio["recv_buffer_size"];
    if (v.isInt())
      audio.recv_buffer_size = v.asUInt();
    v = jaudio["ogg_packet_threshold"];
    if (v.isInt())
      audio.ogg_packet_threshold = v.asUInt();
    v = jaudio["send_audio_stream_mtu"];
    if (v.isInt())
      audio.send_audio_stream_mtu = v.asUInt();
    auto aec_param = jaudio["ant_aec"];
    if (aec_param.isObject()) {
      v = aec_param["model_path"];
      if (v.isString())
        audio.ant_aec.model_path = v.asString();
      v = aec_param["gain_min_dB"];
      if (v.isInt())
        audio.ant_aec.gain_min_dB = v.asInt();
      v = aec_param["gain_fixed_dB"];
      if (v.isInt())
        audio.ant_aec.gain_fixed_dB = v.asInt();
      v = aec_param["gain_agc_max_dB"];
      if (v.isInt())
        audio.ant_aec.gain_agc_max_dB = v.asInt();
      v = aec_param["denoise_mode"];
      if (v.isInt())
        audio.ant_aec.denoise_mode = v.asInt();
    }
    aec_param = jaudio["ant_omni"];
    if (aec_param.isObject()) {
      v = aec_param["aec_path"];
      if (v.isString())
        audio.ant_omni.aec_path = v.asString();
      v = aec_param["ans_path"];
      if (v.isString())
        audio.ant_omni.ans_path = v.asString();
      v = aec_param["target_level"];
      if (v.isInt())
        audio.ant_omni.target_level = v.asInt();
      v = aec_param["noise_floor"];
      if (v.isInt())
        audio.ant_omni.noise_floor = v.asInt();
      v = aec_param["max_gain"];
      if (v.isInt())
        audio.ant_omni.max_gain = v.asInt();
      v = aec_param["pregain"];
      if (v.isInt())
        audio.ant_omni.pregain = v.asInt();
    }
    aec_param = jaudio["rokid_aec"];
    if (aec_param.isObject()) {
      v = aec_param["model_path"];
      if (v.isString())
        audio.rokid_aec.model_path = v.asString();
      v = aec_param["refresh_noise_interval"];
      if (v.isInt())
        audio.rokid_aec.refresh_noise_interval = v.asInt();
    }
    aec_param = jaudio["xunfei_cae"];
    if (aec_param.isObject()) {
      v = aec_param["work_dir"];
      if (v.isString())
        audio.xunfei_cae.work_dir = v.asString();
    }
    aec_param = jaudio["rokid_agc"];
    if (aec_param.isObject()) {
      v = aec_param["amplitude_conversion_factor"];
      if (v.isNumeric())
        audio.rokid_agc.amplitude_conversion_factor = v.asFloat();
      v = aec_param["target_gain_scaling_factor"];
      if (v.isNumeric())
        audio.rokid_agc.target_gain_scaling_factor = v.asFloat();
    }
  }
  KLOGI(TAG, "parse cxr config success");
}
#endif // CXR_SERVER_SIDE
