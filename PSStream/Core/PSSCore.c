#include "PSSCore.h"

#include <chiaki/common.h>
#include <chiaki/discoveryservice.h>
#include <chiaki/log.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/regist.h>
#include <chiaki/session.h>

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PSS_LOG_MASK (CHIAKI_LOG_INFO | CHIAKI_LOG_WARNING | CHIAKI_LOG_ERROR)

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
	PSSLogCallback cb;
	void *user;
} LogForward;

static void log_forward(ChiakiLogLevel level, const char *msg, void *user)
{
	LogForward *fwd = user;
	if(fwd && fwd->cb)
		fwd->cb((int)level, msg, fwd->user);
}

int pss_init(void)
{
	return (int)chiaki_lib_init();
}

const char *pss_error_string(int code)
{
	return chiaki_error_string((ChiakiErrorCode)code);
}

// MARK: - Discovery

#define PSS_DISCOVERY_MAX_BROADCAST 16

struct PSSDiscovery {
	ChiakiDiscoveryService service;
	ChiakiLog log;
	LogForward log_fwd;
	PSSDiscoveryCallback cb;
	void *user;
};

static void discovery_cb(ChiakiDiscoveryHost *hosts, size_t count, void *user)
{
	PSSDiscovery *d = user;
	if(!d->cb)
		return;
	PSSHostInfo *infos = count ? calloc(count, sizeof(PSSHostInfo)) : NULL;
	if(count && !infos)
		return;
	for(size_t i = 0; i < count; i++)
	{
		ChiakiDiscoveryHost *h = &hosts[i];
		PSSHostInfo *o = &infos[i];
		o->state = (PSSHostState)h->state;
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

PSSDiscovery *pss_discovery_start(PSSDiscoveryCallback cb, PSSLogCallback log_cb, void *user)
{
	PSSDiscovery *d = calloc(1, sizeof(PSSDiscovery));
	if(!d)
		return NULL;
	d->cb = cb;
	d->user = user;
	d->log_fwd.cb = log_cb;
	d->log_fwd.user = user;
	chiaki_log_init(&d->log, PSS_LOG_MASK, log_forward, &d->log_fwd);

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
	struct sockaddr_storage broadcasts[PSS_DISCOVERY_MAX_BROADCAST];
	size_t broadcast_count = 0;
	struct ifaddrs *ifs = NULL;
	if(getifaddrs(&ifs) == 0)
	{
		for(struct ifaddrs *ifa = ifs; ifa && broadcast_count < PSS_DISCOVERY_MAX_BROADCAST; ifa = ifa->ifa_next)
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

void pss_discovery_stop(PSSDiscovery *d)
{
	if(!d)
		return;
	chiaki_discovery_service_fini(&d->service);
	free(d);
}

int pss_wakeup(const char *host, const char regist_key[16], bool ps5, PSSLogCallback log_cb, void *user)
{
	LogForward fwd = { log_cb, user };
	ChiakiLog log;
	chiaki_log_init(&log, PSS_LOG_MASK, log_forward, &fwd);

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

struct PSSRegist {
	ChiakiRegist regist;
	ChiakiLog log;
	LogForward log_fwd;
	PSSRegistCallback cb;
	void *user;
	char *host;
	bool started;
};

static void regist_cb(ChiakiRegistEvent *event, void *user)
{
	PSSRegist *r = user;
	PSSRegistResult res = {0};
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

PSSRegist *pss_regist_start(const char *host, const uint8_t account_id[8], uint32_t pin, bool ps5,
		PSSRegistCallback cb, PSSLogCallback log_cb, void *user)
{
	PSSRegist *r = calloc(1, sizeof(PSSRegist));
	if(!r)
		return NULL;
	r->cb = cb;
	r->user = user;
	r->host = strdup(host);
	r->log_fwd.cb = log_cb;
	r->log_fwd.user = user;
	chiaki_log_init(&r->log, PSS_LOG_MASK, log_forward, &r->log_fwd);

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

void pss_regist_cancel(PSSRegist *r)
{
	if(r && r->started)
		chiaki_regist_stop(&r->regist);
}

void pss_regist_free(PSSRegist *r)
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

struct PSSSession {
	ChiakiSession session;
	ChiakiLog log;
	LogForward log_fwd;
	ChiakiOpusDecoder opus;
	PSSSessionCallbacks cb;
	char *host;
	bool started;
};

static void session_event_cb(ChiakiEvent *event, void *user)
{
	PSSSession *s = user;
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
				s->cb.rumble(event->rumble.left, event->rumble.right, s->cb.user);
			break;
		case CHIAKI_EVENT_TRIGGER_EFFECTS:
			if(s->cb.trigger_effects)
				s->cb.trigger_effects(event->trigger_effects.type_left, event->trigger_effects.left,
						event->trigger_effects.type_right, event->trigger_effects.right, s->cb.user);
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
	PSSSession *s = user;
	if(s->cb.video)
		return s->cb.video(buf, buf_size, frames_lost, frame_recovered, s->cb.user);
	return true;
}

static void haptics_frame_cb(uint8_t *buf, size_t buf_size, void *user)
{
	PSSSession *s = user;
	const size_t frame_bytes = 2 * sizeof(int16_t);
	if(!s->cb.haptics || buf_size < frame_bytes)
		return;
	// The buffer is not guaranteed to be 2-byte aligned; copy into an aligned scratch buffer.
	int16_t pcm[256];
	size_t frames = buf_size / frame_bytes;
	if(frames > sizeof(pcm) / frame_bytes)
		frames = sizeof(pcm) / frame_bytes;
	memcpy(pcm, buf, frames * frame_bytes);
	s->cb.haptics(pcm, frames, s->cb.user);
}

static void opus_settings_cb(uint32_t channels, uint32_t rate, void *user)
{
	PSSSession *s = user;
	if(s->cb.audio_format)
		s->cb.audio_format(channels, rate, s->cb.user);
}

static void opus_frame_cb(int16_t *buf, size_t samples_count, void *user)
{
	PSSSession *s = user;
	if(s->cb.audio_frames)
		s->cb.audio_frames(buf, samples_count, s->cb.user);
}

PSSSession *pss_session_create(const PSSSessionConfig *config, PSSSessionCallbacks callbacks, int *err_out)
{
	PSSSession *s = calloc(1, sizeof(PSSSession));
	if(!s)
	{
		if(err_out)
			*err_out = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	s->cb = callbacks;
	s->host = strdup(config->host);
	s->log_fwd.cb = callbacks.log;
	s->log_fwd.user = callbacks.user;
	chiaki_log_init(&s->log, PSS_LOG_MASK, log_forward, &s->log_fwd);

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
	info.video_profile.codec = config->ps5 && config->codec == PSS_CODEC_H265 ? CHIAKI_CODEC_H265 : CHIAKI_CODEC_H264;
	info.video_profile_auto_downgrade = true;
	info.enable_keyboard = false;
	info.enable_dualsense = config->enable_dualsense;
	info.audio_video_disabled = 0;
	info.auto_regist = false;
	info.holepunch_session = NULL;
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

int pss_session_start(PSSSession *s)
{
	ChiakiErrorCode err = chiaki_session_start(&s->session);
	if(err == CHIAKI_ERR_SUCCESS)
		s->started = true;
	return (int)err;
}

int pss_session_stop(PSSSession *s)
{
	return (int)chiaki_session_stop(&s->session);
}

void pss_session_free(PSSSession *s)
{
	if(!s)
		return;
	if(s->started)
	{
		chiaki_session_stop(&s->session);
		chiaki_session_join(&s->session);
	}
	chiaki_session_fini(&s->session);
	chiaki_opus_decoder_fini(&s->opus);
	free(s->host);
	free(s);
}

int pss_session_set_controller(PSSSession *s, const PSSControllerState *in)
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

int pss_session_set_login_pin(PSSSession *s, const char *pin)
{
	return (int)chiaki_session_set_login_pin(&s->session, (const uint8_t *)pin, strlen(pin));
}

int pss_session_request_idr(PSSSession *s)
{
	return (int)chiaki_session_request_idr(&s->session);
}

int pss_session_go_to_bed(PSSSession *s)
{
	return (int)chiaki_session_goto_bed(&s->session);
}

void pss_session_get_stats(PSSSession *s, PSSNetworkStats *out)
{
	memset(out, 0, sizeof(*out));
	if(!s)
		return;
	// Unlocked reads of plain scalars for display only; a stale value is fine.
	ChiakiSession *cs = &s->session;
	out->rtt_ms = (double)cs->rtt_us / 1000.0;
	out->mtu_in = cs->mtu_in;
	ChiakiStreamConnection *sc = &cs->stream_connection;
	out->packet_loss = sc->congestion_control.packet_loss;
	out->measured_bitrate_mbps = sc->measured_bitrate;
}

PSSControllerState pss_controller_idle(void)
{
	ChiakiControllerState st;
	chiaki_controller_state_set_idle(&st);
	PSSControllerState out = {0};
	out.touch_id[0] = -1;
	out.touch_id[1] = -1;
	out.accel_y = st.accel_y;
	out.orient_x = st.orient_x;
	out.orient_y = st.orient_y;
	out.orient_z = st.orient_z;
	out.orient_w = st.orient_w;
	return out;
}
