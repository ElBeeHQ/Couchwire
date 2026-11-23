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
	}
	/// Refreshed twice a second while streaming, for the performance overlay.
	private(set) var stats = StreamStats.Snapshot()
	/// What this session streams at.
	let settings: StreamSettings
	/// The kind of connection, for automatic quality.
	let link: ConnectionQuality.Link
	/// Whether automatic quality chose `settings` (and learns from this session).
	let automaticQuality: Bool
	/// How frames are smoothed out before showing. Changing it applies straight away.
	var smoothing: SmoothingMode {
		didSet { pacer?.mode = smoothing.resolved(for: link) }
	}
	@ObservationIgnored private let pacer: FramePacer?
	/// The stream has kept stuttering for a while; the window offers lower quality.
	private(set) var struggling = false
	/// Why, once `struggling`.
	private(set) var struggleReason: StruggleDetector.Reason = .late
	/// The user closed the struggling banner without changing anything.
	var strugglingDismissed = false
	@ObservationIgnored private var detector = StruggleDetector()
	@ObservationIgnored private var learned = false
	/// Running totals of lost frames and audio gaps over the last 30 s.
	@ObservationIgnored private var recentCounts: [(frames: Int, gaps: Int)] = []
	/// Whether your voice is going to the console.
	private(set) var micOn = false
	/// Set when the mic couldn't start (no permission, no input device).
	private(set) var micProblem: String?
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
		self.automaticQuality = automaticQuality
		self.smoothing = smoothing
		// Frames carry host-clock times to show at, so the layer's clock must be the host clock. Always
		// set up, so smoothing can be switched on and off mid-stream.
		if let timebase = try? CMTimebase(sourceClock: .hostTimeClock) {
			try? timebase.setTime(CMClock.hostTimeClock.time)
			try? timebase.setRate(1)
			displayLayer.controlTimebase = timebase
			pacer = FramePacer(fps: settings.fps, maxHold: FramePacer.maxHold(for: link), mode: smoothing.resolved(for: link),
								 home: internet == nil)
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
		media.audio.minimumLatency = internet == nil ? 0.02 : 0.06
		media.audio.maximumLatency = link == .internetMobile ? 0.25 : 0.15
		media.audio.fastRecovery = internet == nil

		var cfg = CWSessionConfig()
		// Kept until cw_session_create returns; libchiaki copies what it needs.
		let token = internet.map { strdup($0.accessToken) }
		defer { token.map { free($0) } }
		if let internet, let token {
			cfg.psn_token = UnsafePointer(token)
			withUnsafeMutableBytes(of: &cfg.psn_duid) { dst in internet.deviceID.prefix(32).copyBytes(to: dst.bindMemory(to: UInt8.self).baseAddress!, count: min(32, internet.deviceID.count)) }
			cfg.psn_force_port_guessing = internet.forcePortGuessing
			cfg.psn_skip_upnp = internet.skipRouterSearch
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
			Self.timing.notice("Internet connect started")
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
			"This network doesn’t allow a direct connection to \(name). Some mobile networks block it, for Sony’s own Remote Play app too. Try Wi-Fi or a different hotspot."
		case CW_ERR_HOST_UNREACH:
			"Couldn’t open a connection to \(name) through these networks. Turn on “Try harder on difficult networks” in Settings › Internet Play, or try another network."
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
		Self.timing.notice("Streaming after \(self.elapsed, privacy: .public) s (\(self.internet == nil ? "home" : "internet", privacy: .public))")
		phase = .streaming
		startStatsTimer()
		// The live ping goes to the console's home address, which only answers on the home network.
		if internet == nil {
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

	/// Asked when the session fails before any video because the console wasn't ready. Return true to say a
	/// new attempt is coming: this session then stays "connecting" instead of showing the error.
	@ObservationIgnored var retryWhenNotReady: ((StreamSession) -> Bool)?

	private func didQuit(reason: Int32, error: String?) {
		Self.timing.notice("Quit with reason \(reason, privacy: .public) after \(self.elapsed, privacy: .public) s: \(error ?? "no error", privacy: .public)")
		// The connection broke just after the Mac changed network: reconnect rather than show an error.
		if phase == .streaming, error != nil, PathWatcher.shared.secondsSinceChange < 30, onConnectionLost != nil, !lostReported {
			reportLost()
			return
		}
		if phase == .connecting, Self.notReadyReasons.contains(reason), retryWhenNotReady?(self) == true {
			teardown()
			return
		}
		var error = error
		if reason == 13 { // PSN_REGIST_FAILED
			error = "\(console.nickname) didn’t accept this Mac over the internet. Make sure you signed in to Internet Play with the PSN account you use on it."
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
		logStats(snapshot)
		if detector.struggling, !struggling {
			struggleReason = detector.reason
			struggling = true
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
		let line = String(format: "%3.0fs %@ %@ %dfps %.0fMbps | total %.1f = controller %.1f + network %.1f + decode %.1f + smoothing %.1f + display %.1f ms (%.0f Hz) | jitter %.1f ms, loss %.1f%%, late %.0f%%, lost %d (%d recent), audio %.0f ms %d gaps (%d recent), %.0f fps, %.1f Mbps",
			Double(statsTicks) / 2, link.rawValue, settings.resolution.rawValue, settings.fps, Double(settings.bitrate) / 1000,
			s.observedMs, s.controllerMs, s.networkRttMs, s.decodeAvgMs, s.smoothingMs, s.displayWaitAvgMs, s.refreshHz,
			s.pingJitterMs, s.packetLoss * 100, s.lateFrameRatio * 100, s.framesLost, s.recentFramesLost,
			s.audioBufferMs, s.audioGaps, s.recentAudioGaps, s.fps, s.bitrateMbps)
		Self.timing.notice("Stats \(line, privacy: .public)")
	}

	/// How the stream went, for automatic quality to learn from. Nil if it was too short to tell.
	var outcome: ConnectionQuality.Outcome? { detector.outcome }

	private func teardown() {
		if automaticQuality, let outcome = detector.outcome, !learned {
			learned = true
			ConnectionQuality.record(outcome, link: link)
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
