#include "CWCore.h"

#include <chiaki/common.h>
#include <chiaki/discoveryservice.h>
#include <chiaki/log.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/opusencoder.h>
#include <chiaki/regist.h>
#include <chiaki/session.h>
#include <chiaki/remote/holepunch.h>

#include <arpa/inet.h>
#include <time.h>
#include <pthread.h>
#include <unistd.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CW_LOG_MASK (CHIAKI_LOG_INFO | CHIAKI_LOG_WARNING | CHIAKI_LOG_ERROR)

static void copy_str(char *dst, size_t dst_size, const char *src)
{
	if(!dst_size)
		return;
	if(!src)
	{
		dst[0] = '\0';
		return;
	}
	strncpy(dst, src, dst_size - 1);
	dst[dst_size - 1] = '\0';
}

typedef struct {
	CWLogCallback cb;
	void *user;
} LogForward;

static void log_forward(ChiakiLogLevel level, const char *msg, void *user)
{
	LogForward *fwd = user;
	if(fwd && fwd->cb)
		fwd->cb((int)level, msg, fwd->user);
}

static void session_log_forward(ChiakiLogLevel level, const char *msg, void *user);

int cw_init(void)
{
	return (int)chiaki_lib_init();
}

const char *cw_error_string(int code)
{
	return chiaki_error_string((ChiakiErrorCode)code);
}

// MARK: - Discovery

#define CW_DISCOVERY_MAX_BROADCAST 16

struct CWDiscovery {
	ChiakiDiscoveryService service;
	ChiakiLog log;
	LogForward log_fwd;
	CWDiscoveryCallback cb;
	void *user;
};

static void discovery_cb(ChiakiDiscoveryHost *hosts, size_t count, void *user)
{
	CWDiscovery *d = user;
	if(!d->cb)
		return;
	CWHostInfo *infos = count ? calloc(count, sizeof(CWHostInfo)) : NULL;
	if(count && !infos)
		return;
	for(size_t i = 0; i < count; i++)
	{
		ChiakiDiscoveryHost *h = &hosts[i];
		CWHostInfo *o = &infos[i];
		o->state = (CWHostState)h->state;
		o->is_ps5 = chiaki_discovery_host_is_ps5(h);
		copy_str(o->address, sizeof(o->address), h->host_addr);
		copy_str(o->name, sizeof(o->name), h->host_name);
		copy_str(o->host_id, sizeof(o->host_id), h->host_id);
		copy_str(o->host_type, sizeof(o->host_type), h->host_type);
		copy_str(o->system_version, sizeof(o->system_version), h->system_version);
		copy_str(o->running_app_name, sizeof(o->running_app_name), h->running_app_name);
		copy_str(o->running_app_title_id, sizeof(o->running_app_title_id), h->running_app_titleid);
	}
	d->cb(infos, count, d->user);
	free(infos);
}

CWDiscovery *cw_discovery_start(CWDiscoveryCallback cb, CWLogCallback log_cb, void *user)
{
	CWDiscovery *d = calloc(1, sizeof(CWDiscovery));
	if(!d)
		return NULL;
	d->cb = cb;
	d->user = user;
	d->log_fwd.cb = log_cb;
	d->log_fwd.user = user;
	chiaki_log_init(&d->log, CW_LOG_MASK, log_forward, &d->log_fwd);

	ChiakiDiscoveryServiceOptions options = {0};
	options.ping_ms = 500;
	options.ping_initial_ms = 50;
	options.hosts_max = 16;
	options.host_drop_pings = 6;
	options.cb = discovery_cb;
	options.cb_user = d;

	struct sockaddr_in global = {0};
	global.sin_family = AF_INET;
	global.sin_addr.s_addr = 0xffffffff;
	struct sockaddr_storage send_addr = {0};
	memcpy(&send_addr, &global, sizeof(global));
	options.send_addr = &send_addr;
	options.send_addr_size = sizeof(global);

	// macOS does not reliably route 255.255.255.255 out of every interface,
	// so also send a directed broadcast on each active IPv4 interface.
	struct sockaddr_storage broadcasts[CW_DISCOVERY_MAX_BROADCAST];
	size_t broadcast_count = 0;
	struct ifaddrs *ifs = NULL;
	if(getifaddrs(&ifs) == 0)
	{
		for(struct ifaddrs *ifa = ifs; ifa && broadcast_count < CW_DISCOVERY_MAX_BROADCAST; ifa = ifa->ifa_next)
		{
			if(!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET || !ifa->ifa_netmask)
				continue;
			if(!(ifa->ifa_flags & IFF_UP) || !(ifa->ifa_flags & IFF_BROADCAST) || (ifa->ifa_flags & IFF_LOOPBACK))
				continue;
			uint32_t addr = ((struct sockaddr_in *)ifa->ifa_addr)->sin_addr.s_addr;
			uint32_t mask = ((struct sockaddr_in *)ifa->ifa_netmask)->sin_addr.s_addr;
			struct sockaddr_in b = {0};
			b.sin_family = AF_INET;
			b.sin_addr.s_addr = addr | ~mask;
			bool dup = false;
			for(size_t i = 0; i < broadcast_count; i++)
				if(((struct sockaddr_in *)&broadcasts[i])->sin_addr.s_addr == b.sin_addr.s_addr)
					dup = true;
			if(dup)
				continue;
			memset(&broadcasts[broadcast_count], 0, sizeof(struct sockaddr_storage));
			memcpy(&broadcasts[broadcast_count], &b, sizeof(b));
			broadcast_count++;
		}
		freeifaddrs(ifs);
	}
	options.broadcast_addrs = broadcast_count ? broadcasts : NULL;
	options.broadcast_num = broadcast_count;

	ChiakiErrorCode err = chiaki_discovery_service_init(&d->service, &options, &d->log);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&d->log, "Failed to start discovery: %s", chiaki_error_string(err));
		free(d);
		return NULL;
	}
	return d;
}

void cw_discovery_stop(CWDiscovery *d)
{
	if(!d)
		return;
	chiaki_discovery_service_fini(&d->service);
	free(d);
}

int cw_wakeup(const char *host, const char regist_key[16], bool ps5, CWLogCallback log_cb, void *user)
{
	LogForward fwd = { log_cb, user };
	ChiakiLog log;
	chiaki_log_init(&log, CW_LOG_MASK, log_forward, &fwd);

	// The wake-up credential is the regist key (an ASCII hex string, NUL padded) parsed as hex.
	char key[17] = {0};
	memcpy(key, regist_key, 16);
	char *end = NULL;
	uint64_t credential = strtoull(key, &end, 16);
	if(end == key || strlen(key) > 8)
	{
		CHIAKI_LOGE(&log, "Invalid regist key for wakeup");
		return CHIAKI_ERR_INVALID_DATA;
	}
	return (int)chiaki_discovery_wakeup(&log, NULL, host, credential, ps5);
}

// MARK: - Registration

struct CWRegist {
	ChiakiRegist regist;
	ChiakiLog log;
	LogForward log_fwd;
	CWRegistCallback cb;
	void *user;
	char *host;
	bool started;
};

static void regist_cb(ChiakiRegistEvent *event, void *user)
{
	CWRegist *r = user;
	CWRegistResult res = {0};
	res.success = event->type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS && event->registered_host;
	if(res.success)
	{
		ChiakiRegisteredHost *h = event->registered_host;
		res.target = (int)h->target;
		res.is_ps5 = chiaki_target_is_ps5(h->target);
		copy_str(res.server_nickname, sizeof(res.server_nickname), h->server_nickname);
		memcpy(res.regist_key, h->rp_regist_key, sizeof(res.regist_key));
		memcpy(res.rp_key, h->rp_key, sizeof(res.rp_key));
		memcpy(res.server_mac, h->server_mac, sizeof(res.server_mac));
	}
	if(r->cb)
		r->cb(&res, r->user);
}

CWRegist *cw_regist_start(const char *host, const uint8_t account_id[8], uint32_t pin, bool ps5,
		CWRegistCallback cb, CWLogCallback log_cb, void *user)
{
	CWRegist *r = calloc(1, sizeof(CWRegist));
	if(!r)
		return NULL;
	r->cb = cb;
	r->user = user;
	r->host = strdup(host);
	r->log_fwd.cb = log_cb;
	r->log_fwd.user = user;
	chiaki_log_init(&r->log, CW_LOG_MASK, log_forward, &r->log_fwd);

	ChiakiRegistInfo info = {0};
	info.target = ps5 ? CHIAKI_TARGET_PS5_1 : CHIAKI_TARGET_PS4_10;
	info.host = r->host;
	info.broadcast = false;
	info.psn_online_id = NULL;
	memcpy(info.psn_account_id, account_id, CHIAKI_PSN_ACCOUNT_ID_SIZE);
	info.pin = pin;
	info.console_pin = 0;
	info.holepunch_info = NULL;
	info.rudp = NULL;

	ChiakiErrorCode err = chiaki_regist_start(&r->regist, &r->log, &info, regist_cb, r);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&r->log, "Failed to start registration: %s", chiaki_error_string(err));
		free(r->host);
		free(r);
		return NULL;
	}
	r->started = true;
	return r;
}

void cw_regist_cancel(CWRegist *r)
{
	if(r && r->started)
		chiaki_regist_stop(&r->regist);
}

void cw_regist_free(CWRegist *r)
{
	if(!r)
		return;
	if(r->started)
	{
		chiaki_regist_stop(&r->regist);
		chiaki_regist_fini(&r->regist); // joins the thread
	}
	free(r->host);
	free(r);
}

// MARK: - Session

struct CWSession {
	ChiakiSession session;
	ChiakiLog log;
	LogForward log_fwd;
	ChiakiOpusDecoder opus;
	/// Microphone: 48 kHz stereo 16-bit PCM in, 480-frame Opus packets out to the console.
	ChiakiOpusEncoder mic;
	bool mic_connected;
	CWSessionCallbacks cb;
	char *host;
	bool started;
	/// Internet play only. Owned by `session` once chiaki_session_init succeeds (it finalizes it).
	ChiakiHolepunchSession holepunch;
	uint8_t psn_duid[32];
	bool psn_skip_upnp;
	/// The console's Vibration Intensity setting as a gain for rumble and haptics (0 = off).
	_Atomic float feedback_gain;
	/// The console's Trigger Effect Intensity setting is Off.
	bool triggers_off;
	/// Last trigger effects from the console, re-sent when the trigger intensity changes.
	bool have_triggers;
	uint8_t trigger_type_left, trigger_type_right;
	uint8_t trigger_left[10], trigger_right[10];
	/// The console's target bitrate from its connection-quality messages (0 = not heard yet).
	_Atomic int console_target_bitrate;
	/// Blip shield (see cw_session_set_blip_shield). The cap is 0 when it's off.
	pthread_t shield_thread;
	bool shield_running;
	atomic_bool shield_stop;
	_Atomic double shield_cap;
	atomic_uint shield_hidden;
	_Atomic double shield_last_hidden;
	atomic_bool shield_passing;
};

/// DualSense trigger-force reduction (high nibble of the output report's motor power byte),
/// as chiaki-ng sets it. One stream runs at a time, and it's a console-wide setting.
static _Atomic uint8_t trigger_reduction = 0;

uint8_t cw_feedback_trigger_reduction(void)
{
	return atomic_load(&trigger_reduction);
}

static void emit_triggers(CWSession *s)
{
	if(!s->cb.trigger_effects || !s->have_triggers)
		return;
	static const uint8_t off[10] = {0};
	if(s->triggers_off)
		s->cb.trigger_effects(0x05, off, 0x05, off, s->cb.user);
	else
		s->cb.trigger_effects(s->trigger_type_left, s->trigger_left, s->trigger_type_right, s->trigger_right, s->cb.user);
}

_Static_assert(CW_ERR_CANCELED == CHIAKI_ERR_CANCELED, "CW_ERR_CANCELED");
_Static_assert(CW_ERR_HOST_DOWN == CHIAKI_ERR_HOST_DOWN, "CW_ERR_HOST_DOWN");
_Static_assert(CW_ERR_HOST_UNREACH == CHIAKI_ERR_HOST_UNREACH, "CW_ERR_HOST_UNREACH");

static void psn_progress(CWSession *s, CWPSNStep step)
{
	if(s->cb.psn_progress)
		s->cb.psn_progress((int)step, s->cb.user);
}

static void session_event_cb(ChiakiEvent *event, void *user)
{
	CWSession *s = user;
	switch(event->type)
	{
		case CHIAKI_EVENT_CONNECTED:
			if(s->cb.connected)
				s->cb.connected(s->cb.user);
			break;
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			if(s->cb.login_pin_request)
				s->cb.login_pin_request(event->login_pin_request.pin_incorrect, s->cb.user);
			break;
		case CHIAKI_EVENT_RUMBLE:
			if(s->cb.rumble)
			{
				float gain = atomic_load(&s->feedback_gain);
				s->cb.rumble((uint8_t)(event->rumble.left * gain), (uint8_t)(event->rumble.right * gain), s->cb.user);
			}
			break;
		case CHIAKI_EVENT_TRIGGER_EFFECTS:
			s->trigger_type_left = event->trigger_effects.type_left;
			s->trigger_type_right = event->trigger_effects.type_right;
			memcpy(s->trigger_left, event->trigger_effects.left, 10);
			memcpy(s->trigger_right, event->trigger_effects.right, 10);
			s->have_triggers = true;
			emit_triggers(s);
			break;
		case CHIAKI_EVENT_HAPTIC_INTENSITY:
		{
			// Same steps as chiaki-ng: the PS5's Strong / Medium / Weak / Off.
			float gain = 1.0f;
			switch(event->intensity)
			{
				case Off: gain = 0.0f; break;
				case Weak: gain = 0.33f; break;
				case Medium: gain = 0.5f; break;
				case Strong: default: gain = 1.0f; break;
			}
			atomic_store(&s->feedback_gain, gain);
			CHIAKI_LOGI(&s->log, "Vibration intensity gain %.2f", gain);
			if(gain == 0.0f && s->cb.rumble)
				s->cb.rumble(0, 0, s->cb.user);
			break;
		}
		case CHIAKI_EVENT_TRIGGER_INTENSITY:
		{
			uint8_t reduction = 0x00;
			switch(event->intensity)
			{
				case Off: reduction = 0x00; break;
				case Weak: reduction = 0x90; break;
				case Medium: reduction = 0x60; break;
				case Strong: default: reduction = 0x00; break;
			}
			atomic_store(&trigger_reduction, reduction);
			s->triggers_off = event->intensity == Off;
			CHIAKI_LOGI(&s->log, "Trigger intensity: reduction 0x%02x%s", reduction, s->triggers_off ? ", off" : "");
			emit_triggers(s);
			break;
		}
		case CHIAKI_EVENT_LED_COLOR:
			if(s->cb.led_color)
				s->cb.led_color(event->led_state[0], event->led_state[1], event->led_state[2], s->cb.user);
			break;
		case CHIAKI_EVENT_PLAYER_INDEX:
			if(s->cb.player_index)
				s->cb.player_index(event->player_index, s->cb.user);
			break;
		case CHIAKI_EVENT_HOLEPUNCH:
			// The data channel: the last step before the stream starts.
			if(!event->data_holepunch.finished)
				psn_progress(s, CW_PSN_STEP_STREAM);
			break;
		case CHIAKI_EVENT_QUIT:
			if(s->cb.quit)
				s->cb.quit((int)event->quit.reason, chiaki_quit_reason_is_error(event->quit.reason),
						event->quit.reason_str ? event->quit.reason_str : chiaki_quit_reason_string(event->quit.reason),
						s->cb.user);
			break;
		default:
			break;
	}
}

static bool session_video_cb(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	CWSession *s = user;
	if(s->cb.video)
		return s->cb.video(buf, buf_size, frames_lost, frame_recovered, s->cb.user);
	return true;
}

static void haptics_frame_cb(uint8_t *buf, size_t buf_size, void *user)
{
	CWSession *s = user;
	const size_t frame_bytes = 2 * sizeof(int16_t);
	if(!s->cb.haptics || buf_size < frame_bytes)
		return;
	// The buffer is not guaranteed to be 2-byte aligned; copy into an aligned scratch buffer.
	int16_t pcm[256];
	size_t frames = buf_size / frame_bytes;
	if(frames > sizeof(pcm) / frame_bytes)
		frames = sizeof(pcm) / frame_bytes;
	memcpy(pcm, buf, frames * frame_bytes);
	float gain = atomic_load(&s->feedback_gain);
	if(gain <= 0.0f)
		return;
	if(gain < 1.0f)
		for(size_t i = 0; i < frames * 2; i++)
			pcm[i] = (int16_t)(pcm[i] * gain);
	s->cb.haptics(pcm, frames, s->cb.user);
}

static void opus_settings_cb(uint32_t channels, uint32_t rate, void *user)
{
	CWSession *s = user;
	if(s->cb.audio_format)
		s->cb.audio_format(channels, rate, s->cb.user);
}

static void opus_frame_cb(int16_t *buf, size_t samples_count, void *user)
{
	CWSession *s = user;
	if(s->cb.audio_frames)
		s->cb.audio_frames(buf, samples_count, s->cb.user);
}

CWSession *cw_session_create(const CWSessionConfig *config, CWSessionCallbacks callbacks, int *err_out)
{
	CWSession *s = calloc(1, sizeof(CWSession));
	if(!s)
	{
		if(err_out)
			*err_out = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	s->cb = callbacks;
	atomic_init(&s->feedback_gain, 1.0f);
	atomic_store(&trigger_reduction, 0);
	s->log_fwd.cb = callbacks.log;
	s->log_fwd.user = callbacks.user;
	chiaki_log_init(&s->log, CW_LOG_MASK, session_log_forward, s);

	bool internet = config->psn_token != NULL;
	// Over the internet the address comes from the connection PSN sets up, not from us.
	s->host = strdup(internet || !config->host ? "" : config->host);
	if(internet)
	{
		s->holepunch = chiaki_holepunch_session_init(config->psn_token, &s->log);
		if(!s->holepunch)
		{
			CHIAKI_LOGE(&s->log, "Couldn't start a PSN session");
			free(s->host);
			free(s);
			if(err_out)
				*err_out = CHIAKI_ERR_UNKNOWN;
			return NULL;
		}
		chiaki_holepunch_session_force_port_guessing(s->holepunch, config->psn_force_port_guessing);
		s->psn_skip_upnp = config->psn_skip_upnp;
		memcpy(s->psn_duid, config->psn_duid, sizeof(s->psn_duid));
	}

	ChiakiConnectInfo info = {0};
	info.ps5 = config->ps5;
	info.host = s->host;
	memcpy(info.regist_key, config->regist_key, sizeof(info.regist_key));
	memcpy(info.morning, config->morning, sizeof(info.morning));
	memcpy(info.psn_account_id, config->psn_account_id, sizeof(info.psn_account_id));
	info.video_profile.width = config->width;
	info.video_profile.height = config->height;
	info.video_profile.max_fps = config->max_fps;
	info.video_profile.bitrate = config->bitrate_kbps;
	switch(config->ps5 ? config->codec : CW_CODEC_H264)
	{
		case CW_CODEC_H265_HDR: info.video_profile.codec = CHIAKI_CODEC_H265_HDR; break;
		case CW_CODEC_H265: info.video_profile.codec = CHIAKI_CODEC_H265; break;
		default: info.video_profile.codec = CHIAKI_CODEC_H264; break;
	}
	info.video_profile_auto_downgrade = true;
	info.enable_keyboard = false;
	info.enable_dualsense = config->enable_dualsense;
	info.audio_video_disabled = 0;
	info.auto_regist = false;
	// chiaki_session_init takes ownership: it finalizes the holepunch session, even on failure.
	info.holepunch_session = s->holepunch;
	info.rudp_sock = NULL;
	info.packet_loss_max = 0.05;
	info.enable_idr_on_fec_failure = true;

	ChiakiErrorCode err = chiaki_session_init(&s->session, &info, &s->log);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&s->log, "Session init failed: %s", chiaki_error_string(err));
		free(s->host);
		free(s);
		if(err_out)
			*err_out = (int)err;
		return NULL;
	}

	chiaki_opus_decoder_init(&s->opus, &s->log);
	chiaki_opus_decoder_set_cb(&s->opus, opus_settings_cb, opus_frame_cb, s);
	ChiakiAudioSink sink;
	chiaki_opus_decoder_get_sink(&s->opus, &sink);
	chiaki_session_set_audio_sink(&s->session, &sink);

	chiaki_opus_encoder_init(&s->mic, &s->log);
	ChiakiAudioHeader mic_header;
	chiaki_audio_header_set(&mic_header, 2, 16, CW_MIC_SAMPLE_RATE, CW_MIC_FRAME_SAMPLES);
	chiaki_opus_encoder_header(&mic_header, &s->mic, &s->session);

	ChiakiAudioSink haptics_sink = {0};
	haptics_sink.user = s;
	haptics_sink.frame_cb = haptics_frame_cb;
	chiaki_session_set_haptics_sink(&s->session, &haptics_sink);

	chiaki_session_set_event_cb(&s->session, session_event_cb, s);
	chiaki_session_set_video_sample_cb(&s->session, session_video_cb, s);

	if(err_out)
		*err_out = 0;
	return s;
}

int cw_session_start(CWSession *s)
{
	ChiakiErrorCode err = chiaki_session_start(&s->session);
	if(err == CHIAKI_ERR_SUCCESS)
		s->started = true;
	return (int)err;
}

int cw_session_psn_connect(CWSession *s)
{
	if(!s->holepunch)
		return CHIAKI_ERR_UNINITIALIZED;
	ChiakiHolepunchSession hp = s->holepunch;
	ChiakiErrorCode err;

	// The order chiaki-ng uses (lib/include/chiaki/remote/holepunch.h). UPnP is a bonus: it's
	// fine for it to fail.
	psn_progress(s, CW_PSN_STEP_ROUTER);
	// Skipping it leaves the gateway "unknown", which libchiaki treats as "not found".
	if(!s->psn_skip_upnp)
		chiaki_holepunch_upnp_discover(hp);

	psn_progress(s, CW_PSN_STEP_SESSION);
	err = chiaki_holepunch_session_create(hp);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&s->log, "PSN session create failed: %s", chiaki_error_string(err));
		return (int)err;
	}
	err = holepunch_session_create_offer(hp);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&s->log, "PSN offer failed: %s", chiaki_error_string(err));
		return (int)err;
	}

	// Asking the console to join also wakes it from rest mode.
	psn_progress(s, CW_PSN_STEP_CONSOLE);
	err = chiaki_holepunch_session_start(hp, s->psn_duid, CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&s->log, "Console didn't join the PSN session: %s", chiaki_error_string(err));
		return (int)err;
	}

	psn_progress(s, CW_PSN_STEP_CONNECTION);
	err = chiaki_holepunch_session_punch_hole(hp, CHIAKI_HOLEPUNCH_PORT_TYPE_CTRL);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&s->log, "No direct connection to the console: %s", chiaki_error_string(err));
		return (int)err;
	}

	// Registration over PSN and the data channel happen inside the session thread.
	return cw_session_start(s);
}

void cw_session_psn_cancel(CWSession *s)
{
	if(s && s->holepunch)
		chiaki_holepunch_main_thread_cancel(s->holepunch, false);
}

int cw_session_stop(CWSession *s)
{
	return (int)chiaki_session_stop(&s->session);
}

static void shield_thread_stop(CWSession *s);

void cw_session_free(CWSession *s)
{
	if(!s)
		return;
	// Before the session goes: the shield thread uses its packet stats.
	shield_thread_stop(s);
	if(s->started)
	{
		chiaki_session_stop(&s->session);
		chiaki_session_join(&s->session);
	}
	chiaki_session_fini(&s->session);
	chiaki_opus_decoder_fini(&s->opus);
	chiaki_opus_encoder_fini(&s->mic);
	free(s->host);
	free(s);
}

int cw_session_set_controller(CWSession *s, const CWControllerState *in)
{
	ChiakiControllerState st;
	chiaki_controller_state_set_idle(&st);
	st.buttons = in->buttons;
	st.l2_state = in->l2;
	st.r2_state = in->r2;
	st.left_x = in->left_x;
	st.left_y = in->left_y;
	st.right_x = in->right_x;
	st.right_y = in->right_y;
	for(int i = 0; i < CHIAKI_CONTROLLER_TOUCHES_MAX; i++)
	{
		st.touches[i].id = in->touch_id[i];
		st.touches[i].x = in->touch_x[i];
		st.touches[i].y = in->touch_y[i];
	}
	st.gyro_x = in->gyro_x;
	st.gyro_y = in->gyro_y;
	st.gyro_z = in->gyro_z;
	st.accel_x = in->accel_x;
	st.accel_y = in->accel_y;
	st.accel_z = in->accel_z;
	st.orient_x = in->orient_x;
	st.orient_y = in->orient_y;
	st.orient_z = in->orient_z;
	st.orient_w = in->orient_w;
	return (int)chiaki_session_set_controller_state(&s->session, &st);
}

int cw_session_mic_set_muted(CWSession *s, bool muted)
{
	if(!s->mic_connected)
	{
		if(muted)
			return 0;
		ChiakiErrorCode err = chiaki_session_connect_microphone(&s->session);
		if(err != CHIAKI_ERR_SUCCESS)
			return (int)err;
		s->mic_connected = true;
	}
	// libchiaki's flag is inverted: it takes the *current* state, so true sends unmute
	// (see ctrl_message_toggle_microphone).
	return (int)chiaki_session_toggle_microphone(&s->session, !muted);
}

void cw_session_mic_frame(CWSession *s, int16_t *pcm)
{
	if(s->mic_connected)
		chiaki_opus_encoder_frame(pcm, &s->mic);
}

int cw_session_set_login_pin(CWSession *s, const char *pin)
{
	return (int)chiaki_session_set_login_pin(&s->session, (const uint8_t *)pin, strlen(pin));
}

int cw_session_request_idr(CWSession *s)
{
	return (int)chiaki_session_request_idr(&s->session);
}

int cw_session_go_to_bed(CWSession *s)
{
	return (int)chiaki_session_goto_bed(&s->session);
}

void cw_session_get_stats(CWSession *s, CWNetworkStats *out)
{
	memset(out, 0, sizeof(*out));
	if(!s)
		return;
	// Unlocked reads of plain scalars for display only; a stale value is fine.
	ChiakiSession *cs = &s->session;
	out->rtt_ms = (double)cs->rtt_us / 1000.0;
	out->mtu_in = cs->mtu_in;
	ChiakiStreamConnection *sc = &cs->stream_connection;
	// As measured, before the cap (and the blip shield) limit what the console is told.
	out->packet_loss = sc->congestion_control.packet_loss;
	out->measured_bitrate_mbps = sc->measured_bitrate;
	out->console_target_bitrate = atomic_load(&s->console_target_bitrate);
	out->shield_hidden = atomic_load(&s->shield_hidden);
	out->shield_last_hidden = atomic_load(&s->shield_last_hidden);
	out->shield_passing = atomic_load(&s->shield_passing);
}

// MARK: - Blip shield

/// What the shield thread knows about the reports libchiaki sends every 200 ms.
typedef struct {
	bool lossy[10];  // the last 10 reports (2 s): whether each had loss
	int next;
	uint64_t last_received, last_lost;
	uint64_t last_loss_ms;   // when loss was last seen
	uint64_t episode_ms;     // when the current run of loss began (gaps under 3 s count as one)
} Shield;

static uint64_t now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

/// On each look at the counts libchiaki is building its next report from, sets the most loss
/// that report may carry: none while loss is a passing stall, the cap once it has lasted.
static void shield_step(CWSession *s, Shield *sh, uint64_t received, uint64_t lost, bool new_report)
{
	double cap = atomic_load(&s->shield_cap);
	ChiakiCongestionControl *cc = &s->session.stream_connection.congestion_control;
	if(new_report)
	{
		// The counts were reset, so the previous report has gone, with what we last saw in it.
		bool had_loss = sh->last_lost > 0;
		if(had_loss && !atomic_load(&s->shield_passing))
		{
			atomic_fetch_add(&s->shield_hidden, 1);
			uint64_t total = sh->last_received + sh->last_lost;
			atomic_store(&s->shield_last_hidden, total ? (double)sh->last_lost / total : 0);
		}
		sh->lossy[sh->next] = had_loss;
		sh->next = (sh->next + 1) % 10;
	}
	sh->last_received = received;
	sh->last_lost = lost;
	int count = lost > 0 ? 1 : 0;
	for(int i = 0; i < 10; i++)
		count += sh->lossy[i] ? 1 : 0;
	uint64_t now = now_ms();
	bool passing = atomic_load(&s->shield_passing);
	if(lost > 0)
	{
		if(!sh->last_loss_ms || now - sh->last_loss_ms > 3000)
			sh->episode_ms = now;
		sh->last_loss_ms = now;
	}
	// A Wi-Fi scan stalls the stream for up to 10-odd seconds; lowering the bitrate doesn't help
	// with that, and the console takes ages to climb back. So only pass loss on once it has lasted
	// over 10 s and is still steady (3 of the last 10 reports), as real congestion does. Light loss
	// that never gets that steady is passed on once its run has lasted over 30 s: a scan doesn't
	// last that long, and the console should still ease off for congestion that never goes away.
	bool run_alive = sh->last_loss_ms && now - sh->last_loss_ms <= 3000;
	uint64_t run_ms = run_alive ? now - sh->episode_ms : 0;
	if(!passing && run_alive && ((count >= 3 && run_ms > 10000) || run_ms > 30000))
		passing = true;
	else if(passing && now - sh->last_loss_ms > 5000)
		passing = false;
	atomic_store(&s->shield_passing, passing);
	// Aligned double, read by libchiaki's congestion thread each report; a plain write is fine.
	cc->packet_loss_max = passing ? cap : 0;
}

/// Every 50 ms, peeks at the counts for libchiaki's next congestion report.
static void *shield_thread_func(void *user)
{
	CWSession *s = user;
	ChiakiPacketStats *stats = &s->session.stream_connection.packet_stats;
	uint64_t last_received = 0;
	Shield shield = { 0 };
	while(!atomic_load(&s->shield_stop))
	{
		usleep(50 * 1000);
		uint64_t received, lost;
		chiaki_packet_stats_get(stats, false, &received, &lost);
		// libchiaki resets the counts each time it sends a report.
		bool new_report = received < last_received;
		last_received = received;
		shield_step(s, &shield, received, lost, new_report);
	}
	return NULL;
}

static void shield_thread_stop(CWSession *s)
{
	if(!s->shield_running)
		return;
	atomic_store(&s->shield_stop, true);
	pthread_join(s->shield_thread, NULL);
	s->shield_running = false;
}

void cw_session_set_blip_shield(CWSession *s, double cap)
{
	if(!s || cap <= 0 || s->shield_running)
		return;
	atomic_store(&s->shield_cap, cap);
	atomic_store(&s->shield_stop, false);
	if(pthread_create(&s->shield_thread, NULL, shield_thread_func, s) == 0)
		s->shield_running = true;
}

/// The session's log. Verbose messages are only switched on to read the console's target
/// bitrate; they're never passed on.
static void session_log_forward(ChiakiLogLevel level, const char *msg, void *user)
{
	CWSession *s = user;
	if(level == CHIAKI_LOG_VERBOSE)
	{
		static const char prefix[] = "StreamConnection received connection quality: target_bitrate=";
		if(strncmp(msg, prefix, sizeof(prefix) - 1) == 0)
			atomic_store(&s->console_target_bitrate, atoi(msg + sizeof(prefix) - 1));
		return;
	}
	log_forward(level, msg, &s->log_fwd);
}

void cw_session_watch_console_bitrate(CWSession *s)
{
	if(!s)
		return;
	// libchiaki's threads read the mask without a lock; an int write is fine for that.
	s->log.level_mask |= CHIAKI_LOG_VERBOSE;
}

CWControllerState cw_controller_idle(void)
{
	ChiakiControllerState st;
	chiaki_controller_state_set_idle(&st);
	CWControllerState out = {0};
	out.touch_id[0] = -1;
	out.touch_id[1] = -1;
	out.accel_y = st.accel_y;
	out.orient_x = st.orient_x;
	out.orient_y = st.orient_y;
	out.orient_z = st.orient_z;
	out.orient_w = st.orient_w;
	return out;
}

// MARK: - PSN

int cw_psn_list_devices(const char *access_token, CWPSNDevice **devices_out, size_t *count_out,
		CWLogCallback log_cb, void *user)
{
	*devices_out = NULL;
	*count_out = 0;
	LogForward fwd = { .cb = log_cb, .user = user };
	ChiakiLog log;
	chiaki_log_init(&log, CW_LOG_MASK, log_forward, &fwd);

	ChiakiHolepunchDeviceInfo *list = NULL;
	size_t count = 0;
	ChiakiErrorCode err = chiaki_holepunch_list_devices(access_token, CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5, &list, &count, &log);
	if(err != CHIAKI_ERR_SUCCESS)
		return (int)err;
	if(count > 0)
	{
		CWPSNDevice *out = calloc(count, sizeof(CWPSNDevice));
		if(!out)
		{
			chiaki_holepunch_free_device_list(&list);
			return CHIAKI_ERR_MEMORY;
		}
		for(size_t i = 0; i < count; i++)
		{
			memcpy(out[i].name, list[i].device_name, sizeof(out[i].name));
			out[i].name[sizeof(out[i].name) - 1] = '\0';
			memcpy(out[i].duid, list[i].device_uid, sizeof(out[i].duid));
			out[i].remote_play_enabled = list[i].remoteplay_enabled;
		}
		*devices_out = out;
		*count_out = count;
	}
	chiaki_holepunch_free_device_list(&list);
	return 0;
}

void cw_psn_free_devices(CWPSNDevice *devices)
{
	free(devices);
}

void cw_psn_generate_client_duid(char out[CW_PSN_CLIENT_DUID_SIZE])
{
	size_t size = CW_PSN_CLIENT_DUID_SIZE;
	memset(out, 0, CW_PSN_CLIENT_DUID_SIZE);
	chiaki_holepunch_generate_client_device_uid(out, &size);
	out[CW_PSN_CLIENT_DUID_SIZE - 1] = '\0';
}
