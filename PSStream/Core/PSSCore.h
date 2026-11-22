// PSSCore — a thin, Swift-friendly C facade over libchiaki.
//
// libchiaki's public structs are large and full of unions/macros that import
// awkwardly into Swift. This layer exposes opaque handles plus flat callback
// tables so the Swift side never touches libchiaki types directly.

#ifndef PSS_CORE_H
#define PSS_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
	PSS_LOG_DEBUG = 1 << 4,
	PSS_LOG_VERBOSE = 1 << 3,
	PSS_LOG_INFO = 1 << 2,
	PSS_LOG_WARNING = 1 << 1,
	PSS_LOG_ERROR = 1 << 0,
} PSSLogLevel;

typedef void (*PSSLogCallback)(int level, const char *msg, void *user);

/// Must be called once before anything else. Returns 0 on success.
int pss_init(void);

/// Human-readable string for a libchiaki error code.
const char *pss_error_string(int code);

// MARK: - Discovery

typedef enum {
	PSS_HOST_STATE_UNKNOWN = 0,
	PSS_HOST_STATE_READY = 1,
	PSS_HOST_STATE_STANDBY = 2,
} PSSHostState;

typedef struct {
	PSSHostState state;
	bool is_ps5;
	char address[64];
	char name[64];
	char host_id[64];
	char host_type[16];
	char system_version[32];
	char running_app_name[128];
	char running_app_title_id[32];
} PSSHostInfo;

typedef void (*PSSDiscoveryCallback)(const PSSHostInfo *hosts, size_t count, void *user);

typedef struct PSSDiscovery PSSDiscovery;

/// Starts continuous LAN discovery (UDP broadcast on every active IPv4 interface).
PSSDiscovery *pss_discovery_start(PSSDiscoveryCallback cb, PSSLogCallback log_cb, void *user);
void pss_discovery_stop(PSSDiscovery *discovery);

/// Sends a wake-up packet. `regist_key` is the 16-byte key obtained from registration.
int pss_wakeup(const char *host, const char regist_key[16], bool ps5, PSSLogCallback log_cb, void *user);

// MARK: - Registration

typedef struct {
	bool success;
	bool is_ps5;
	int target;
	char server_nickname[32];
	char regist_key[16];     // rp_regist_key, used as connect_info.regist_key
	uint8_t rp_key[16];      // used as connect_info.morning
	uint8_t server_mac[6];
} PSSRegistResult;

typedef void (*PSSRegistCallback)(const PSSRegistResult *result, void *user);

typedef struct PSSRegist PSSRegist;

/// Registers ("pairs") with a console. `account_id` is the 8-byte PSN account id,
/// `pin` the 8-digit code shown under Settings > System > Remote Play > Link Device.
PSSRegist *pss_regist_start(const char *host, const uint8_t account_id[8], uint32_t pin, bool ps5,
		PSSRegistCallback cb, PSSLogCallback log_cb, void *user);
void pss_regist_cancel(PSSRegist *regist);
/// Frees the registration. Must not be called from inside the callback.
void pss_regist_free(PSSRegist *regist);

// MARK: - Streaming session

typedef enum {
	PSS_CODEC_H264 = 0,
	PSS_CODEC_H265 = 1,
} PSSCodec;

typedef struct {
	const char *host;
	bool ps5;
	char regist_key[16];
	uint8_t morning[16];
	uint8_t psn_account_id[8];
	unsigned int width;
	unsigned int height;
	unsigned int max_fps;
	unsigned int bitrate_kbps;
	PSSCodec codec;
	bool enable_dualsense;
} PSSSessionConfig;

typedef struct {
	void *user;
	PSSLogCallback log;
	/// Annex-B encoded access unit. Called on libchiaki's receive thread.
	bool (*video)(const uint8_t *buf, size_t size, int32_t frames_lost, bool frame_recovered, void *user);
	void (*audio_format)(uint32_t channels, uint32_t rate, void *user);
	/// Interleaved signed 16-bit PCM, `frames` frames.
	void (*audio_frames)(const int16_t *buf, size_t frames, void *user);
	void (*connected)(void *user);
	void (*login_pin_request)(bool pin_incorrect, void *user);
	void (*rumble)(uint8_t left, uint8_t right, void *user);
	void (*quit)(int reason, bool is_error, const char *reason_str, void *user);
	/// Raw DualSense adaptive-trigger effects: effect type byte + 10 parameter bytes per trigger.
	void (*trigger_effects)(uint8_t type_left, const uint8_t *left, uint8_t type_right, const uint8_t *right, void *user);
	/// DualSense haptics: interleaved stereo (left, right) signed 16-bit PCM at 3000 Hz.
	void (*haptics)(const int16_t *buf, size_t frames, void *user);
} PSSSessionCallbacks;

/// Mirrors ChiakiControllerState. Axes are -32768...32767 (Y down positive, as on DualSense).
typedef struct {
	uint32_t buttons;
	uint8_t l2;
	uint8_t r2;
	int16_t left_x, left_y;
	int16_t right_x, right_y;
	// Touchpad: up to two fingers, id < 0 means not touching. Coordinates 0...1919 x 0...941.
	int8_t touch_id[2];
	uint16_t touch_x[2];
	uint16_t touch_y[2];
	float gyro_x, gyro_y, gyro_z;
	float accel_x, accel_y, accel_z;
	float orient_x, orient_y, orient_z, orient_w;
} PSSControllerState;

enum {
	PSS_BUTTON_CROSS = 1 << 0,
	PSS_BUTTON_CIRCLE = 1 << 1,
	PSS_BUTTON_SQUARE = 1 << 2,
	PSS_BUTTON_TRIANGLE = 1 << 3,
	PSS_BUTTON_DPAD_LEFT = 1 << 4,
	PSS_BUTTON_DPAD_RIGHT = 1 << 5,
	PSS_BUTTON_DPAD_UP = 1 << 6,
	PSS_BUTTON_DPAD_DOWN = 1 << 7,
	PSS_BUTTON_L1 = 1 << 8,
	PSS_BUTTON_R1 = 1 << 9,
	PSS_BUTTON_L3 = 1 << 10,
	PSS_BUTTON_R3 = 1 << 11,
	PSS_BUTTON_OPTIONS = 1 << 12,
	PSS_BUTTON_CREATE = 1 << 13,
	PSS_BUTTON_TOUCHPAD = 1 << 14,
	PSS_BUTTON_PS = 1 << 15,
};

typedef struct PSSSession PSSSession;

PSSSession *pss_session_create(const PSSSessionConfig *config, PSSSessionCallbacks callbacks, int *err_out);
int pss_session_start(PSSSession *session);
int pss_session_stop(PSSSession *session);
/// Blocks until the session thread exits, then frees everything.
void pss_session_free(PSSSession *session);
int pss_session_set_controller(PSSSession *session, const PSSControllerState *state);
int pss_session_set_login_pin(PSSSession *session, const char *pin);
int pss_session_request_idr(PSSSession *session);
int pss_session_go_to_bed(PSSSession *session);
typedef struct {
	double rtt_ms;             // measured once during connection setup
	double packet_loss;        // 0...1, rolling (congestion control window)
	double measured_bitrate_mbps;
	unsigned int mtu_in;
} PSSNetworkStats;

/// Snapshot of libchiaki's network statistics. Cheap; safe to call at any time.
void pss_session_get_stats(PSSSession *session, PSSNetworkStats *out);

/// Returns the controller-state idle value (sticks centred, orientation identity).
PSSControllerState pss_controller_idle(void);

#ifdef __cplusplus
}
#endif

#endif
