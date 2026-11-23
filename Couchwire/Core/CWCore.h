// CWCore — a thin, Swift-friendly C facade over libchiaki.
//
// libchiaki's public structs are large and full of unions/macros that import
// awkwardly into Swift. This layer exposes opaque handles plus flat callback
// tables so the Swift side never touches libchiaki types directly.

#ifndef CW_CORE_H
#define CW_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
	CW_LOG_DEBUG = 1 << 4,
	CW_LOG_VERBOSE = 1 << 3,
	CW_LOG_INFO = 1 << 2,
	CW_LOG_WARNING = 1 << 1,
	CW_LOG_ERROR = 1 << 0,
} CWLogLevel;

typedef void (*CWLogCallback)(int level, const char *msg, void *user);

/// Must be called once before anything else. Returns 0 on success.
int cw_init(void);

/// Human-readable string for a libchiaki error code.
const char *cw_error_string(int code);

// MARK: - Discovery

typedef enum {
	CW_HOST_STATE_UNKNOWN = 0,
	CW_HOST_STATE_READY = 1,
	CW_HOST_STATE_STANDBY = 2,
} CWHostState;

typedef struct {
	CWHostState state;
	bool is_ps5;
	char address[64];
	char name[64];
	char host_id[64];
	char host_type[16];
	char system_version[32];
	char running_app_name[128];
	char running_app_title_id[32];
} CWHostInfo;

typedef void (*CWDiscoveryCallback)(const CWHostInfo *hosts, size_t count, void *user);

typedef struct CWDiscovery CWDiscovery;

/// Starts continuous LAN discovery (UDP broadcast on every active IPv4 interface).
CWDiscovery *cw_discovery_start(CWDiscoveryCallback cb, CWLogCallback log_cb, void *user);
void cw_discovery_stop(CWDiscovery *discovery);

/// Sends a wake-up packet. `regist_key` is the 16-byte key obtained from registration.
int cw_wakeup(const char *host, const char regist_key[16], bool ps5, CWLogCallback log_cb, void *user);

// MARK: - Registration

typedef struct {
	bool success;
	bool is_ps5;
	int target;
	char server_nickname[32];
	char regist_key[16];     // rp_regist_key, used as connect_info.regist_key
	uint8_t rp_key[16];      // used as connect_info.morning
	uint8_t server_mac[6];
} CWRegistResult;

typedef void (*CWRegistCallback)(const CWRegistResult *result, void *user);

typedef struct CWRegist CWRegist;

/// Registers ("pairs") with a console. `account_id` is the 8-byte PSN account id,
/// `pin` the 8-digit code shown under Settings > System > Remote Play > Link Device.
CWRegist *cw_regist_start(const char *host, const uint8_t account_id[8], uint32_t pin, bool ps5,
		CWRegistCallback cb, CWLogCallback log_cb, void *user);
void cw_regist_cancel(CWRegist *regist);
/// Frees the registration. Must not be called from inside the callback.
void cw_regist_free(CWRegist *regist);

// MARK: - Streaming session

typedef enum {
	CW_CODEC_H264 = 0,
	CW_CODEC_H265 = 1,
	/// HEVC Main10 with HDR (PQ/HLG) when the game outputs it.
	CW_CODEC_H265_HDR = 2,
} CWCodec;

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
	CWCodec codec;
	bool enable_dualsense;
	/// Internet play: a PSN OAuth access token. NULL for a LAN session (`host`, `regist_key` and
	/// `morning` are then used). When set, `host` is ignored, the console is registered afresh
	/// over PSN on every connect, and the session must be connected with cw_session_psn_connect.
	const char *psn_token;
	/// Internet play: the console's 32-byte PSN device id (from cw_psn_list_devices).
	uint8_t psn_duid[32];
	/// Internet play: guess ports even when the NAT looks friendly. Helps with double NAT and
	/// some mobile hotspots; slower.
	bool psn_force_port_guessing;
	/// Internet play: don't look for a UPnP router first. Mobile hotspots never have one, and the
	/// search takes 7 s to give up.
	bool psn_skip_upnp;
} CWSessionConfig;

typedef struct {
	void *user;
	CWLogCallback log;
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
	/// Lightbar colour requested by the console/game.
	void (*led_color)(uint8_t r, uint8_t g, uint8_t b, void *user);
	/// Player number (1-based as sent by the console), shown on the player LEDs.
	void (*player_index)(uint8_t index, void *user);
	/// Internet play: progress through cw_session_psn_connect (a CWPSNStep). Called on the
	/// connecting thread, then on libchiaki's session thread for the data channel.
	void (*psn_progress)(int step, void *user);
} CWSessionCallbacks;

/// Steps of an internet connection, in order.
typedef enum {
	CW_PSN_STEP_ROUTER = 0,        // asking the router to open a port (UPnP)
	CW_PSN_STEP_SESSION = 1,       // creating a Remote Play session on PSN
	CW_PSN_STEP_CONSOLE = 2,       // asking the console to join (this also wakes it)
	CW_PSN_STEP_CONNECTION = 3,    // opening a direct connection through both networks
	CW_PSN_STEP_STREAM = 4,        // connected; registering and starting the stream
} CWPSNStep;

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
} CWControllerState;

enum {
	CW_BUTTON_CROSS = 1 << 0,
	CW_BUTTON_CIRCLE = 1 << 1,
	CW_BUTTON_SQUARE = 1 << 2,
	CW_BUTTON_TRIANGLE = 1 << 3,
	CW_BUTTON_DPAD_LEFT = 1 << 4,
	CW_BUTTON_DPAD_RIGHT = 1 << 5,
	CW_BUTTON_DPAD_UP = 1 << 6,
	CW_BUTTON_DPAD_DOWN = 1 << 7,
	CW_BUTTON_L1 = 1 << 8,
	CW_BUTTON_R1 = 1 << 9,
	CW_BUTTON_L3 = 1 << 10,
	CW_BUTTON_R3 = 1 << 11,
	CW_BUTTON_OPTIONS = 1 << 12,
	CW_BUTTON_CREATE = 1 << 13,
	CW_BUTTON_TOUCHPAD = 1 << 14,
	CW_BUTTON_PS = 1 << 15,
};

typedef struct CWSession CWSession;

CWSession *cw_session_create(const CWSessionConfig *config, CWSessionCallbacks callbacks, int *err_out);
int cw_session_start(CWSession *session);
int cw_session_stop(CWSession *session);
/// Blocks until the session thread exits, then frees everything.
void cw_session_free(CWSession *session);
int cw_session_set_controller(CWSession *session, const CWControllerState *state);

/// Internet play: finds the console through PSN, opens a connection to it and starts the session
/// (so don't also call cw_session_start). Blocks for up to a minute or more; call it off the main
/// thread, and wait for it to return before cw_session_free. Returns 0 on success, otherwise a
/// ChiakiErrorCode: CW_ERR_HOST_DOWN if the console never joined (asleep without network wake, off,
/// or signed in to a different account), CW_ERR_HOST_UNREACH if no direct connection could be made
/// (the network type blocks it), CW_ERR_CANCELED after cw_session_psn_cancel.
int cw_session_psn_connect(CWSession *session);
/// Stops cw_session_psn_connect early. Safe from any thread.
void cw_session_psn_cancel(CWSession *session);
int cw_session_set_login_pin(CWSession *session, const char *pin);

#define CW_MIC_SAMPLE_RATE 48000
/// Samples per channel in each microphone frame (10 ms).
#define CW_MIC_FRAME_SAMPLES 480
/// Unmute (connecting the mic on first use) or mute the microphone on the console.
int cw_session_mic_set_muted(CWSession *session, bool muted);
/// Send one frame: CW_MIC_FRAME_SAMPLES interleaved stereo samples (960 values).
/// Call from one thread only.
void cw_session_mic_frame(CWSession *session, int16_t *pcm);
int cw_session_request_idr(CWSession *session);
int cw_session_go_to_bed(CWSession *session);
typedef struct {
	double rtt_ms;             // measured once during connection setup
	double packet_loss;        // 0...1, rolling (congestion control window)
	double measured_bitrate_mbps;
	unsigned int mtu_in;
} CWNetworkStats;

/// Snapshot of libchiaki's network statistics. Cheap; safe to call at any time.
void cw_session_get_stats(CWSession *session, CWNetworkStats *out);

// MARK: - PSN

#define CW_ERR_CANCELED 14
#define CW_ERR_HOST_DOWN 8
#define CW_ERR_HOST_UNREACH 9

typedef struct {
	char name[32];
	uint8_t duid[32];
	bool remote_play_enabled;
} CWPSNDevice;

/// Lists the PS5s on the PSN account the access token belongs to. Blocks on the network (about 5 s
/// at most); call it off the main thread. Free the list with cw_psn_free_devices.
int cw_psn_list_devices(const char *access_token, CWPSNDevice **devices_out, size_t *count_out,
		CWLogCallback log_cb, void *user);
void cw_psn_free_devices(CWPSNDevice *devices);

#define CW_PSN_CLIENT_DUID_SIZE 49
/// A fresh client device id for the PSN sign-in URL's `duid` parameter (needed for internet play).
void cw_psn_generate_client_duid(char out[CW_PSN_CLIENT_DUID_SIZE]);

/// Returns the controller-state idle value (sticks centred, orientation identity).
CWControllerState cw_controller_idle(void);

#ifdef __cplusplus
}
#endif

#endif
