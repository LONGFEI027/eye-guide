#pragma once

#include <stdint.h>
#include <string>
#include <vector>

using namespace std;

class CXRConfig {
public:
  typedef struct {
    string client_connection_info_storage_path_compatible;
    string client_connection_info_storage_path;
    string client_connection_info_file;
    uint32_t socket_read_buffer_size;
    uint32_t mtu[3];
  } CXR;
  typedef struct {
    uint32_t recv_buffer_size;
    uint32_t send_buffer_size;
    uint32_t auth_send_buffer_size;
  } CXRProto;
  typedef struct {
    string name;
    uint8_t id;
    uint8_t match_action;
    string app_bundle_id;
  } ExternalAccessoryProtocol;
  typedef struct {
    string name;
    string model_id;
    string product_plan_uid;
  } IdentificationInformation;
  typedef struct {
    bool detect_acp;
    uint32_t connect_timeout;
    uint32_t connect_retry_interval;
    uint32_t send_buffer_size;
    uint32_t recv_buffer_size;
    string rokid_team_id;
    string manufacture;
    string firmware_version;
    string hardware_version;
    vector<ExternalAccessoryProtocol> eap;
    vector<IdentificationInformation> identification_information;
  } MFI;
  typedef struct {
    uint32_t notify_timeout;
  } GATT;
  typedef struct {
    uint32_t frame_queue_size;
  } ARTC;
  typedef struct {
    string model_path;
    int32_t gain_min_dB;
    int32_t gain_fixed_dB;
    int32_t gain_agc_max_dB;
    int32_t denoise_mode;
  } ANT_AEC_PARAM;
  typedef struct {
    string model_path;
    uint32_t refresh_noise_interval;
  } ROKID_AEC_PARAM;
  typedef struct {
    string aec_path;
    string ans_path;
    int32_t target_level;
    int32_t noise_floor;
    int32_t max_gain;
    int32_t pregain;
  } ANT_OMNI_PARAM;
  typedef struct {
    string work_dir;
  } XUNFEI_CAE_PARAM;
  typedef struct {
    float amplitude_conversion_factor;
    float target_gain_scaling_factor;
  } ROKID_AGC_PARAM;
  typedef struct {
    uint32_t send_buffer_size;
    uint32_t recv_buffer_size;
    uint32_t ogg_packet_threshold;
    uint32_t send_audio_stream_mtu;
    ANT_AEC_PARAM ant_aec;
    ROKID_AEC_PARAM rokid_aec;
    ANT_OMNI_PARAM ant_omni;
    XUNFEI_CAE_PARAM xunfei_cae;
    ROKID_AGC_PARAM rokid_agc;
  } Audio;

  static CXR cxr;
  static CXRProto cxrproto;
  static MFI mfi;
  static GATT gatt;
  static ARTC artc;
  static Audio audio;
  static bool initialized;

  static bool ready();
  static void initialize(const char* file);
  static void setDefaultValues();
#ifdef CXR_SERVER_SIDE
  static void parseConfig(const char* json, uint32_t size);
#endif
};
