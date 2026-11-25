import AVFoundation
import QuartzCore
import Foundation
import Observation
import os

/// One Remote Play streaming session. Owns the libchiaki session plus the video, audio
/// and input pipelines. Media callbacks run on libchiaki threads and go straight to the
/// renderer / audio ring buffer without hopping to the main thread.
@MainActor
@Observable
final class StreamSession {
	enum Phase: Equatable {
		case connecting
		case streaming
		case needsPIN(incorrect: Bool)
		case ended(error: String?)
	}

	private(set) var phase: Phase = .connecting
	/// Still connecting (or waiting for the PIN).
	var isStarting: Bool {
		switch phase {
		case .connecting, .needsPIN: true
		case .streaming, .ended: false
		}
	}
	/// Internet play: how far the connection has got while `phase` is `.connecting`.
	private(set) var internetStep: CWPSNStep?
	/// Set for a session over the internet, nil for one on the home network.
	let internet: InternetTarget?

	/// Where to reach a console over the internet, via PSN.
	struct InternetTarget {
		let accessToken: String
		/// The console's 32-byte PSN device id.
		let deviceID: Data
		let forcePortGuessing: Bool
		/// Don't look for a UPnP router: mobile hotspots never have one.
		var skipRouterSearch = false
		/// Keep asking the console every few seconds within one PSN session (it's still letting go of
		/// our last stream), for up to a minute.
		var reaskConsole = false
	}
	/// Refreshed twice a second while streaming, for the performance overlay.
	private(set) var stats = StreamStats.Snapshot()
	/// What this session streams at.
	let settings: StreamSettings
	/// The kind of connection, for automatic quality.
	let link: ConnectionQuality.Link
	/// On the home network, as opposed to over the internet (through PSN or straight to an address).
	var isHome: Bool { link == .homeWired || link == .homeWireless }
	/// Set when connecting straight to an address away from home: said when the console can't be reached.
	var unreachableHint: String?
	/// Whether automatic quality chose `settings` (and learns from this session).
	let automaticQuality: Bool
	/// How frames are smoothed out before showing. Changing it applies straight away.
	var smoothing: SmoothingMode {
		didSet { pacer?.mode = smoothing.resolved(for: link) }
	}
	@ObservationIgnored private let pacer: FramePacer?
	/// The stream is stuttering now (most of the last 10 s); the window offers lower quality. Clears once it recovers.
	private(set) var struggling = false
	/// Why, once `struggling`.
	private(set) var struggleReason: StruggleDetector.Reason = .late
	/// Once `struggling` on Wi-Fi: AirDrop is on, which can cause it.
	private(set) var airDropMayCause = false

	/// Whether AirDrop is set to Contacts Only or Everyone. While it's on, the Wi-Fi radio keeps
	/// leaving the home network for a moment, so frames arrive late or get lost. Apple doesn't
	/// document this setting; if it moves, this reads false and the tip just doesn't show.
	private static var airDropOn: Bool {
		guard let mode = UserDefaults(suiteName: "com.apple.sharingd")?.string(forKey: "DiscoverableMode") else { return false }
		return mode != "Off"
	}
	/// The user closed the struggling banner without changing anything.
	var strugglingDismissed = false
	/// The PS5 is sending well below what it started this stream at, though the connection has recovered.
	/// It climbs back only about 1.3 Mbps a minute, while a fresh stream starts at full: the Sharpen banner.
	private(set) var pictureSoft = false
	/// The user closed the Sharpen banner; it comes back only after the bitrate recovers and drops again.
	var softDismissed = false
	@ObservationIgnored private var softLowTicks = 0
	@ObservationIgnored private var softCleanTicks = 0
	@ObservationIgnored private var softLastLost = 0
	/// The highest target the PS5 has reported in this stream: what a fresh stream gets.
	@ObservationIgnored private var softFull = 0.0
	@ObservationIgnored private var detector = StruggleDetector()
	/// The blip shield is running for this stream (at home, unless switched off).
	@ObservationIgnored private var shieldOn = false
	@ObservationIgnored private var shieldHidden: UInt32 = 0
	@ObservationIgnored private var shieldPassing = false
	/// libchiaki's latest network stats, for the shield's log lines.
	@ObservationIgnored private var lastNet = CWNetworkStats()
	@ObservationIgnored private var learned = false
	/// Running totals of lost frames and audio gaps over the last 30 s.
	@ObservationIgnored private var recentCounts: [(frames: Int, gaps: Int)] = []
	/// Whether your voice is going to the console.
	private(set) var micOn = false
	/// Set when the mic couldn't start (no permission, no input device).
	private(set) var micProblem: String?
	/// Game sound volume, 0...1. Kept for the next session.
	var volume: Float = StreamSession.savedVolume {
		didSet {
			if !UserDefaults.standard.bool(forKey: "CouchwireDemo") {
				UserDefaults.standard.set(volume, forKey: "gameVolume")
			}
			applyVolume()
		}
	}
	/// Game sound off, for this session only, so the next one never starts silent by surprise.
	var soundMuted = false {
		didSet { applyVolume() }
	}
	private static var savedVolume: Float {
		min(max(UserDefaults.standard.object(forKey: "gameVolume") as? Float ?? 1, 0), 1)
	}
	private func applyVolume() {
		media.audio.volume = soundMuted ? 0 : volume
	}
	let console: RegisteredConsole
	let displayLayer = AVSampleBufferDisplayLayer()
	/// Fed by the stream view's display link so we can measure time-to-refresh.
	let statsCollector: StreamStats

	@ObservationIgnored private nonisolated(unsafe) var handle: OpaquePointer?
	@ObservationIgnored private let media: MediaSink
	@ObservationIgnored private var input: ControllerInput?
	@ObservationIgnored private var activity: NSObjectProtocol?
	@ObservationIgnored private var box: Unmanaged<MediaSink>?
	@ObservationIgnored private var statsTimer: Timer?
	@ObservationIgnored private var pinger: ConsolePinger?
	/// Internet play: held while cw_session_psn_connect runs, so the session isn't freed under it.
	@ObservationIgnored private let connecting = DispatchGroup()

	init(console: RegisteredConsole, keys: ConsoleKeys, settings: StreamSettings, link: ConnectionQuality.Link,
		 automaticQuality: Bool, smoothing: SmoothingMode, internet: InternetTarget? = nil) {
		self.console = console
		self.internet = internet
		self.settings = settings
		self.link = link
		let home = link == .homeWired || link == .homeWireless
		self.automaticQuality = automaticQuality
		self.smoothing = smoothing
		// Frames carry host-clock times to show at, so the layer's clock must be the host clock. Always
		// set up, so smoothing can be switched on and off mid-stream.
		if let timebase = try? CMTimebase(sourceClock: .hostTimeClock) {
			try? timebase.setTime(CMClock.hostTimeClock.time)
			try? timebase.setRate(1)
			displayLayer.controlTimebase = timebase
			pacer = FramePacer(fps: settings.fps, maxHold: FramePacer.maxHold(for: link), mode: smoothing.resolved(for: link),
								 home: home)
		} else {
			pacer = nil
		}
		displayLayer.videoGravity = .resizeAspect
		displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
		if settings.codec == .hevcHDR {
			// Let PQ/HLG frames use the display's extra brightness headroom (EDR).
			displayLayer.wantsExtendedDynamicRangeContent = true
		}
		// Without a control timebase, samples are flagged DisplayImmediately and shown on decode.
		let collector = StreamStats(codec: settings.codec.rawValue, fps: settings.fps)
		statsCollector = collector
		media = MediaSink(
			decoder: VideoDecoder(codec: settings.codec.isHEVC ? .hevc : .h264, hdr: settings.codec == .hevcHDR,
								  renderer: displayLayer.sampleBufferRenderer, stats: collector,
								  pacer: pacer),
			stats: collector)
		media.owner = self
		media.audio.minimumLatency = home ? 0.02 : 0.06
		media.audio.maximumLatency = link == .internetMobile ? 0.25 : 0.15
		media.audio.fastRecovery = home
		applyVolume()

		var cfg = CWSessionConfig()
		// Kept until cw_session_create returns; libchiaki copies what it needs.
		let token = internet.map { strdup($0.accessToken) }
		defer { token.map { free($0) } }
		if let internet, let token {
			cfg.psn_token = UnsafePointer(token)
			withUnsafeMutableBytes(of: &cfg.psn_duid) { dst in internet.deviceID.prefix(32).copyBytes(to: dst.bindMemory(to: UInt8.self).baseAddress!, count: min(32, internet.deviceID.count)) }
			cfg.psn_force_port_guessing = internet.forcePortGuessing
			cfg.psn_skip_upnp = internet.skipRouterSearch
			cfg.psn_reask_ms = internet.reaskConsole ? 3000 : 0
		}
		let host = strdup(console.lastAddress)
		defer { free(host) }
		cfg.host = UnsafePointer(host)
		cfg.ps5 = console.isPS5
		withUnsafeMutableBytes(of: &cfg.regist_key) { dst in keys.registKey.copyBytes(to: dst.bindMemory(to: UInt8.self).baseAddress!, count: 16) }
		withUnsafeMutableBytes(of: &cfg.morning) { dst in keys.rpKey.copyBytes(to: dst.bindMemory(to: UInt8.self).baseAddress!, count: 16) }
		if let account = Data(base64Encoded: console.accountID), account.count == 8 {
			withUnsafeMutableBytes(of: &cfg.psn_account_id) { dst in account.copyBytes(to: dst.bindMemory(to: UInt8.self).baseAddress!, count: 8) }
		}
		let size = settings.resolution.size
		cfg.width = size.width
		cfg.height = size.height
		cfg.max_fps = UInt32(settings.fps)
		cfg.bitrate_kbps = UInt32(settings.bitrate)
		cfg.codec = switch settings.codec {
		case .h264: CW_CODEC_H264
		case .hevc: CW_CODEC_H265
		case .hevcHDR: CW_CODEC_H265_HDR
		}
		cfg.enable_dualsense = true

		let box = Unmanaged.passRetained(media)
		self.box = box
		var callbacks = CWSessionCallbacks()
		callbacks.user = box.toOpaque()
		callbacks.log = { level, msg, _ in logFromCore(level, msg) }
		callbacks.video = { buf, size, framesLost, _, user in
			let sink = Unmanaged<MediaSink>.fromOpaque(user!).takeUnretainedValue()
			sink.stats.frameArrived(bytes: size, framesLost: framesLost)
			if framesLost > 0 { sink.requestKeyframe() }
			return sink.decoder.decode(UnsafeBufferPointer(start: buf, count: size))
		}
		callbacks.audio_format = { channels, rate, user in
			let sink = Unmanaged<MediaSink>.fromOpaque(user!).takeUnretainedValue()
			sink.audio.configure(channels: Int(channels), sampleRate: Double(rate))
			sink.audioChannels = Int(channels)
		}
		callbacks.audio_frames = { buf, frames, user in
			let sink = Unmanaged<MediaSink>.fromOpaque(user!).takeUnretainedValue()
			sink.audio.enqueue(UnsafeBufferPointer(start: buf, count: frames * sink.audioChannels))
		}
		callbacks.connected = { user in
			let sink = Unmanaged<MediaSink>.fromOpaque(user!).takeUnretainedValue()
			Task { @MainActor in sink.owner?.didConnect() }
		}
		callbacks.login_pin_request = { incorrect, user in
			let sink = Unmanaged<MediaSink>.fromOpaque(user!).takeUnretainedValue()
			Task { @MainActor in sink.owner?.phase = .needsPIN(incorrect: incorrect) }
		}
		callbacks.rumble = { left, right, user in
			let sink = Unmanaged<MediaSink>.fromOpaque(user!).takeUnretainedValue()
			sink.input?.rumble(left: left, right: right)
		}
		callbacks.trigger_effects = { typeLeft, left, typeRight, right, user in
			let sink = Unmanaged<MediaSink>.fromOpaque(user!).takeUnretainedValue()
			guard let left, let right else { return }
			sink.input?.triggerEffects(typeLeft: typeLeft, left: Array(UnsafeBufferPointer(start: left, count: 10)),
									   typeRight: typeRight, right: Array(UnsafeBufferPointer(start: right, count: 10)))
		}
		callbacks.led_color = { r, g, b, user in
			let sink = Unmanaged<MediaSink>.fromOpaque(user!).takeUnretainedValue()
			sink.input?.lightbar(r: r, g: g, b: b)
		}
		callbacks.psn_progress = { step, user in
			let sink = Unmanaged<MediaSink>.fromOpaque(user!).takeUnretainedValue()
			Task { @MainActor in sink.owner?.internetProgress(CWPSNStep(UInt32(step))) }
		}
		callbacks.player_index = { index, user in
			let sink = Unmanaged<MediaSink>.fromOpaque(user!).takeUnretainedValue()
			sink.input?.playerIndex(index)
		}
		callbacks.haptics = { buf, frames, user in
			let sink = Unmanaged<MediaSink>.fromOpaque(user!).takeUnretainedValue()
			sink.input?.haptics(UnsafeBufferPointer(start: buf, count: frames * 2), frames: frames)
		}
		callbacks.quit = { code, isError, reason, user in
			let sink = Unmanaged<MediaSink>.fromOpaque(user!).takeUnretainedValue()
			let msg = isError ? reason.map { String(cString: $0) } ?? "Disconnected" : nil
			Task { @MainActor in sink.owner?.didQuit(reason: code, error: msg) }
		}

		var err: Int32 = 0
		handle = cw_session_create(&cfg, callbacks, &err)
		if handle == nil {
			phase = .ended(error: "Couldn’t start session: \(String(cString: cw_error_string(err)))")
			box.release()
			self.box = nil
			return
		}
	}

	func start() {
		guard let handle, phase == .connecting else { return }
		let h = handle
		media.requestKeyframe = { _ = cw_session_request_idr(h) }
		media.decoder.requestKeyframe = { _ = cw_session_request_idr(h) }
		// Created before the session starts so early trigger effects aren't lost; it only
		// starts reading the controller once we're connected.
		let input = ControllerInput(stats: statsCollector) { state in
			var s = state
			_ = cw_session_set_controller(h, &s)
		}
		input.onMuteButton = { [weak self] in self?.toggleMicrophone() }
		self.input = input
		media.input = input
		// Keep the system out of App Nap / timer coalescing while streaming.
		activity = ProcessInfo.processInfo.beginActivity(
			options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled],
			reason: "Remote Play streaming")
		if internet != nil {
			// Finding the console through PSN and opening a connection blocks for up to a minute.
			startedAt = CACurrentMediaTime()
			keepCoreLog = true
			Self.timing.notice("Internet connect started\(self.internet?.reaskConsole == true ? " (re-asking the console)" : "", privacy: .public)")
			internetStep = CW_PSN_STEP_ROUTER
			connecting.enter()
			DispatchQueue.global(qos: .userInitiated).async { [connecting] in
				let err = cw_session_psn_connect(h)
				connecting.leave()
				Task { @MainActor [weak self] in self?.internetConnectFinished(err) }
			}
			return
		}
		startedAt = CACurrentMediaTime()
		let err = cw_session_start(h)
		if err != 0 {
			phase = .ended(error: "Couldn’t start session: \(String(cString: cw_error_string(err)))")
		}
	}

	private func internetProgress(_ step: CWPSNStep) {
		guard phase == .connecting else { return }
		internetStep = step
		Self.timing.notice("Internet step \(step.rawValue, privacy: .public) after \(self.elapsed, privacy: .public) s")
	}

	/// Connection timings, kept by macOS's log so slow connections can be looked into later.
	static let timing = Logger(subsystem: "Couchwire", category: "Timing")
	@ObservationIgnored private var startedAt: CFTimeInterval = 0
	private var elapsed: String { String(format: "%.1f", CACurrentMediaTime() - startedAt) }

	/// The console answered but no direct connection could be opened to it: the networks in
	/// between don't allow one. Trying again on the same network rarely helps.
	private(set) var couldNotPunch = false

	private func internetConnectFinished(_ err: Int32) {
		guard err != 0, phase == .connecting else { return }
		keepCoreLog = false
		Self.timing.notice("Internet connect failed with \(err, privacy: .public) after \(self.elapsed, privacy: .public) s")
		couldNotPunch = err == CW_ERR_HOST_UNREACH
		let name = console.nickname
		let message: String? = switch err {
		case CW_ERR_CANCELED: nil
		case CW_ERR_HOST_DOWN:
			"\(name) didn’t answer over the internet. Check it’s switched on or in rest mode with “Stay Connected to the Internet” on, and signed in to your PSN account."
		case CW_ERR_HOST_UNREACH where PathWatcher.shared.usesVPN:
			"Couldn’t open a connection to \(name) while a VPN is on. Most VPNs block the direct connection Remote Play needs. Turn the VPN off, or exclude Couchwire from it, then try again."
		case CW_ERR_HOST_UNREACH where internet?.forcePortGuessing == true:
			"This network doesn’t allow a direct connection to \(name). Some mobile networks block it, for Sony’s own Remote Play app too. Try Wi-Fi or a different hotspot, or set up an away-from-home address in \(name)’s settings."
		case CW_ERR_HOST_UNREACH:
			"Couldn’t open a connection to \(name) through these networks. Turn on “Try harder on difficult networks” in Settings › Account, or try another network."
		default:
			"Couldn’t connect to \(name) over the internet (\(String(cString: cw_error_string(err))))."
		}
		phase = .ended(error: message)
		teardown()
	}

	func submitPIN(_ pin: String) {
		guard let handle else { return }
		phase = .connecting
		_ = cw_session_set_login_pin(handle, pin)
	}

	func stop() {
		teardown()
		if case .ended = phase {} else { phase = .ended(error: nil) }
	}

	func toggleMicrophone() {
		Task { await setMicrophone(!micOn) }
	}

	func setMicrophone(_ on: Bool) async {
		guard let h = handle, phase == .streaming else { return }
		micProblem = nil
		if on {
			guard await MicrophoneCapture.requestAccess() else {
				micProblem = "Allow Couchwire in System Settings › Privacy & Security › Microphone."
				return
			}
			guard handle == h else { return }
			media.audio.microphone.send = { cw_session_mic_frame(h, $0) }
			guard media.audio.setMicrophone(true) else {
				micProblem = "Couldn’t use the microphone."
				return
			}
			_ = cw_session_mic_set_muted(h, false)
			micOn = true
			input?.muteLight(false)
		} else {
			media.audio.setMicrophone(false)
			_ = cw_session_mic_set_muted(h, true)
			micOn = false
			// Orange means muted, like on a PS5. Left dark until the mic has been used.
			input?.muteLight(true)
		}
	}

	func putConsoleToSleep() {
		if let handle { _ = cw_session_go_to_bed(handle) }
	}

	private func didConnect() {
		keepCoreLog = false
		Self.timing.notice("Streaming after \(self.elapsed, privacy: .public) s (\(self.internet != nil ? "internet" : self.isHome ? "home" : "direct", privacy: .public))")
		phase = .streaming
		hasStreamed = true
		// Just after a network change (a reconnect, usually) the Wi-Fi is still settling: give it longer
		// before judging the stream, so the banner and automatic quality aren't misled.
		detector = StruggleDetector(afterNetworkChange: PathWatcher.shared.secondsSinceChange < 60)
		if BlipShield.isOn, isHome, let handle {
			cw_session_set_blip_shield(handle, BlipShield.cap)
			cw_session_watch_console_bitrate(handle)
			shieldOn = true
			Self.timing.notice("Blip shield on")
		}
		startStatsTimer()
		// The live ping goes to the console's home address, which only answers on the home network.
		if isHome {
			let collector = statsCollector
			pinger = ConsolePinger(address: console.lastAddress) { collector.ping($0) }
			pinger?.start()
		}
		input?.start()
	}

	/// libchiaki quit reasons (ChiakiQuitReason) that mean the console wasn't ready to start a session yet,
	/// as happens for a few seconds after it wakes from rest mode or is switched on.
	private static let notReadyReasons: Set<Int32> = [
		2, // SESSION_REQUEST_UNKNOWN
		3, // SESSION_REQUEST_CONNECTION_REFUSED
		7, // CTRL_UNKNOWN
		8, // CTRL_CONNECT_FAILED
		9, // CTRL_CONNECTION_REFUSED
	]

	/// SESSION_REQUEST_RP_IN_USE: the console is still holding a stream, often the one that just ended.
	private static let inUseReason: Int32 = 4

	/// Asked when the session fails before any video because the console wasn't ready, or (`inUse`) was still
	/// busy with a stream. Return true to say a new attempt is coming: this session then stays "connecting"
	/// instead of showing the error.
	@ObservationIgnored var retryWhenNotReady: ((StreamSession, _ inUse: Bool) -> Bool)?
	/// This attempt follows an "already in use" refusal: the console is letting go of the last stream.
	var waitingForRelease = false
	/// Video arrived at some point, so the console now holds a stream for this Mac.
	private(set) var hasStreamed = false

	private func didQuit(reason: Int32, error: String?) {
		keepCoreLog = false
		Self.timing.notice("Quit with reason \(reason, privacy: .public) after \(self.elapsed, privacy: .public) s: \(error ?? "no error", privacy: .public)")
		// The connection broke just after the Mac changed network: reconnect rather than show an error.
		if phase == .streaming, error != nil, PathWatcher.shared.secondsSinceChange < 30, onConnectionLost != nil, !lostReported {
			reportLost()
			return
		}
		if phase == .connecting, Self.notReadyReasons.contains(reason) || reason == Self.inUseReason,
		   retryWhenNotReady?(self, reason == Self.inUseReason) == true {
			teardown()
			return
		}
		var error = error
		if reason == 13 { // PSN_REGIST_FAILED
			error = "\(console.nickname) didn’t accept this Mac over the internet. Make sure you signed in to Internet Play with the PSN account you use on it."
		} else if phase == .connecting, Self.notReadyReasons.contains(reason), let hint = unreachableHint {
			error = hint
		} else if phase == .connecting, Self.notReadyReasons.contains(reason) {
			error = "\(console.nickname) isn’t ready to stream yet. Wait a moment, then press Play again."
		}
		if let e = error, e.contains("AvCap failed to initialize video") {
			// The console's encoder refused the requested resolution or codec.
			error = "The PS5 couldn’t start video with these settings. Try 1080p, or a different codec, in this console’s settings."
		}
		phase = .ended(error: error)
		teardown()
	}

	private func startStatsTimer() {
		statsTimer?.invalidate()
		let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.refreshStats() }
		}
		RunLoop.main.add(timer, forMode: .common)
		statsTimer = timer
	}

	private func refreshStats() {
		guard let handle, phase == .streaming else { return }
		// No video at all: the PS5 sends frames continuously, even for a still picture, so silence
		// means the connection has gone. Quickly after a network change, more slowly otherwise.
		let silent = statsCollector.secondsSinceLastFrame
		if silent > (PathWatcher.shared.secondsSinceChange < 15 ? 1.5 : 6) {
			reportLost()
			return
		}
		var snapshot = statsCollector.snapshot()
		var net = CWNetworkStats()
		cw_session_get_stats(handle, &net)
		snapshot.rttMs = net.rtt_ms
		snapshot.packetLoss = net.packet_loss
		lastNet = net
		if let audio = media.audio.status {
			snapshot.audioBufferMs = audio.targetMs
			snapshot.audioGaps = audio.gaps
		}
		recentCounts.append((snapshot.framesLost + snapshot.decodeErrors, snapshot.audioGaps))
		if recentCounts.count > 60 { recentCounts.removeFirst() } // 30 s of half-second samples
		if let oldest = recentCounts.first {
			snapshot.recentFramesLost = snapshot.framesLost + snapshot.decodeErrors - oldest.frames
			snapshot.recentAudioGaps = snapshot.audioGaps - oldest.gaps
		}
		stats = snapshot
		detector.add(snapshot)
		watchShield()
		watchSharpness(snapshot)
		logStats(snapshot)
		// The banner follows how the stream is doing now; learning uses whether it ever struggled.
		if detector.strugglingNow != struggling {
			struggleReason = detector.reason
			if detector.strugglingNow { airDropMayCause = link != .homeWired && Self.airDropOn }
			struggling = detector.strugglingNow
			Self.timing.notice("\(self.struggling ? "Struggling" : "No longer struggling", privacy: .public) after \(self.elapsed, privacy: .public) s\(self.struggling ? " (AirDrop \(self.airDropMayCause ? "on" : "off or wired"))" : "", privacy: .public)")
		}
	}

	/// Whether the picture is softer than it needs to be: the PS5's target under 60% of its highest in this
	/// stream (what a fresh stream starts at) for 30 s, with the last 20 s clean. Clears once the target is
	/// back over 80%, or the stream starts struggling again. Judged against the PS5's own start rather than
	/// the bitrate asked for, in case it caps some settings lower: then a restart wouldn't help. Needs the
	/// PS5's target, which is read at home.
	private func watchSharpness(_ s: StreamStats.Snapshot) {
		let lost = s.framesLost - softLastLost
		softLastLost = s.framesLost
		let target = Double(lastNet.console_target_bitrate)
		guard shieldOn, target > 0 else { return }
		let asked = Double(settings.bitrate) * 1000
		softFull = max(softFull, min(target, asked))
		let full = softFull
		let clean = lost == 0 && s.lateFrameRatio <= 0.1 && !struggling
		softCleanTicks = clean ? softCleanTicks + 1 : 0
		softLowTicks = target < full * 0.6 ? softLowTicks + 1 : 0
		let soft: Bool
		if target >= full * 0.8 || struggling {
			soft = false
			if target >= full * 0.8 { softDismissed = false }
		} else {
			soft = pictureSoft || (softLowTicks >= 60 && softCleanTicks >= 40)
		}
		if soft != pictureSoft {
			pictureSoft = soft
			Self.timing.notice("Picture \(soft ? "softer than it needs to be" : "sharp again", privacy: .public) after \(self.elapsed, privacy: .public) s (PS5 target \(target / 1_000_000, format: .fixed(precision: 1)) of \(full / 1_000_000, format: .fixed(precision: 1)) Mbps highest, \(asked / 1_000_000, format: .fixed(precision: 0)) asked)")
		}
	}

	/// Logs what the blip shield did since the last tick, with the PS5's target to see the effect.
	private func watchShield() {
		guard shieldOn else { return }
		let net = lastNet
		if net.shield_hidden != shieldHidden {
			Self.timing.notice("Shield: hid \(net.shield_hidden - self.shieldHidden, privacy: .public) report(s) with loss (last \(net.shield_last_hidden * 100, format: .fixed(precision: 1)) %, \(net.shield_hidden, privacy: .public) so far) after \(self.elapsed, privacy: .public) s, PS5 target \(Double(net.console_target_bitrate) / 1_000_000, format: .fixed(precision: 1)) Mbps")
			shieldHidden = net.shield_hidden
		}
		if net.shield_passing != shieldPassing {
			shieldPassing = net.shield_passing
			Self.timing.notice("Shield: \(self.shieldPassing ? "loss is lasting, passing it on" : "hiding stalls again", privacy: .public) after \(self.elapsed, privacy: .public) s, PS5 target \(Double(net.console_target_bitrate) / 1_000_000, format: .fixed(precision: 1)) Mbps")
		}
	}

	/// Called once when the stream has stopped arriving, typically because the Mac moved to another
	/// network: the console keeps sending to the old address, and nothing can move a live stream over.
	/// The session is still running; the handler ends it and connects again.
	@ObservationIgnored var onConnectionLost: ((StreamSession) -> Void)?
	@ObservationIgnored private var lostReported = false

	private func reportLost() {
		guard !lostReported, let onConnectionLost else { return }
		lostReported = true
		onConnectionLost(self)
	}

	/// Don't learn from this session when it ends: the caller already has.
	func skipLearning() { learned = true }

	@ObservationIgnored private var statsTicks = 0

	/// Every 10 s, one line of what the performance panel shows, so a slow or uneven stream can be
	/// looked into afterwards (macOS keeps the log for a few days).
	private func logStats(_ s: StreamStats.Snapshot) {
		statsTicks += 1
		guard statsTicks % 20 == 0 else { return }
		let line = String(format: "%3.0fs %@ %@ %dfps %.0fMbps | total %.1f = controller %.1f + network %.1f + decode %.1f + smoothing %.1f + display %.1f ms (%.0f Hz) | jitter %.1f ms, loss %.1f%%, late %.0f%%, lost %d (%d recent), audio %.0f ms %d gaps (%d recent), %.0f fps, %.1f Mbps, %@ %@",
			Double(statsTicks) / 2, link.rawValue, settings.resolution.rawValue, settings.fps, Double(settings.bitrate) / 1000,
			s.observedMs, s.controllerMs, s.networkRttMs, s.decodeAvgMs, s.smoothingMs, s.displayWaitAvgMs, s.refreshHz,
			s.pingJitterMs, s.packetLoss * 100, s.lateFrameRatio * 100, s.framesLost, s.recentFramesLost,
			s.audioBufferMs, s.audioGaps, s.recentAudioGaps, s.fps, s.bitrateMbps, s.codec, s.dynamicRange.isEmpty ? "?" : s.dynamicRange)
		let smoothingNote = pacer.map { $0.mode == .automatic ? ($0.steppedUp ? "automatic, steadiest" : "automatic, balanced") : $0.mode.rawValue } ?? "none"
		let shieldNote = shieldOn ? String(format: ", shield %@ (%u hidden, PS5 target %.1f Mbps)",
			lastNet.shield_passing ? "passing" : "hiding", lastNet.shield_hidden, Double(lastNet.console_target_bitrate) / 1_000_000) : ""
		Self.timing.notice("Stats \(line, privacy: .public), smoothing \(smoothingNote, privacy: .public)\(shieldNote, privacy: .public)")
	}

	/// How the stream went, for automatic quality to learn from. Nil if it was too short to tell.
	var outcome: ConnectionQuality.Outcome? { detector.outcome }

	private func teardown() {
		if automaticQuality, let outcome = detector.outcome, !learned {
			learned = true
			let before = ConnectionQuality.step(for: link)
			ConnectionQuality.record(outcome, link: link)
			Self.timing.notice("Quality on \(self.link.rawValue, privacy: .public): \(String(describing: outcome), privacy: .public), step \(before) → \(ConnectionQuality.step(for: self.link))")
		}
		statsTimer?.invalidate()
		statsTimer = nil
		pinger?.stop()
		pinger = nil
		media.input = nil
		input?.stop()
		input = nil
		media.audio.stop()
		micOn = false
		if let activity { ProcessInfo.processInfo.endActivity(activity) }
		activity = nil
		internetStep = nil
		guard let h = handle else { return }
		handle = nil
		let box = self.box
		self.box = nil
		// Stop an internet connection that's still being set up; it must finish before the free.
		if internet != nil { cw_session_psn_cancel(h) }
		// cw_session_free joins libchiaki's thread; never do that on the main thread.
		DispatchQueue.global(qos: .userInitiated).async { [connecting] in
			connecting.wait()
			cw_session_free(h)
			box?.release()
		}
	}
}

/// State touched from libchiaki's threads. Kept separate from the main-actor session.
final class MediaSink: @unchecked Sendable {
	let decoder: VideoDecoder
	let audio = AudioPlayer()
	var audioChannels = 2
	var requestKeyframe: () -> Void = {}
	weak var owner: StreamSession?

	/// Read from libchiaki threads, written on the main thread: guard the reference.
	private var _input: ControllerInput?
	private var inputLock = os_unfair_lock()
	var input: ControllerInput? {
		get { os_unfair_lock_lock(&inputLock); defer { os_unfair_lock_unlock(&inputLock) }; return _input }
		set { os_unfair_lock_lock(&inputLock); _input = newValue; os_unfair_lock_unlock(&inputLock) }
	}

	let stats: StreamStats

	init(decoder: VideoDecoder, stats: StreamStats) {
		self.decoder = decoder
		self.stats = stats
	}
}
