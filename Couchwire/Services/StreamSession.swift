import AVFoundation
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
	/// Refreshed twice a second while streaming, for the performance overlay.
	private(set) var stats = StreamStats.Snapshot()
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

	init(console: RegisteredConsole, keys: ConsoleKeys, settings: StreamSettings) {
		self.console = console
		displayLayer.videoGravity = .resizeAspect
		displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
		if settings.codec == .hevcHDR {
			// Let PQ/HLG frames use the display's extra brightness headroom (EDR).
			displayLayer.wantsExtendedDynamicRangeContent = true
		}
		// No control timebase: samples are flagged DisplayImmediately and shown on decode.
		let collector = StreamStats(codec: settings.codec.rawValue)
		statsCollector = collector
		media = MediaSink(
			decoder: VideoDecoder(codec: settings.codec.isHEVC ? .hevc : .h264, hdr: settings.codec == .hevcHDR,
								  renderer: displayLayer.sampleBufferRenderer, stats: collector),
			stats: collector)
		media.owner = self

		var cfg = CWSessionConfig()
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
		callbacks.player_index = { index, user in
			let sink = Unmanaged<MediaSink>.fromOpaque(user!).takeUnretainedValue()
			sink.input?.playerIndex(index)
		}
		callbacks.haptics = { buf, frames, user in
			let sink = Unmanaged<MediaSink>.fromOpaque(user!).takeUnretainedValue()
			sink.input?.haptics(UnsafeBufferPointer(start: buf, count: frames * 2), frames: frames)
		}
		callbacks.quit = { _, isError, reason, user in
			let sink = Unmanaged<MediaSink>.fromOpaque(user!).takeUnretainedValue()
			let msg = isError ? reason.map { String(cString: $0) } ?? "Disconnected" : nil
			Task { @MainActor in sink.owner?.didQuit(error: msg) }
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
		self.input = input
		media.input = input
		// Keep the system out of App Nap / timer coalescing while streaming.
		activity = ProcessInfo.processInfo.beginActivity(
			options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled],
			reason: "Remote Play streaming")
		let err = cw_session_start(h)
		if err != 0 {
			phase = .ended(error: "Couldn’t start session: \(String(cString: cw_error_string(err)))")
		}
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
				media.audio.microphone.send = nil
				micProblem = "Couldn’t use the microphone."
				return
			}
			_ = cw_session_mic_set_muted(h, false)
			micOn = true
		} else {
			_ = cw_session_mic_set_muted(h, true)
			media.audio.setMicrophone(false)
			media.audio.microphone.send = nil
			micOn = false
		}
	}

	func putConsoleToSleep() {
		if let handle { _ = cw_session_go_to_bed(handle) }
	}

	private func didConnect() {
		phase = .streaming
		startStatsTimer()
		let collector = statsCollector
		pinger = ConsolePinger(address: console.lastAddress) { collector.ping($0) }
		pinger?.start()
		input?.start()
	}

	private func didQuit(error: String?) {
		var error = error
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
		var snapshot = statsCollector.snapshot()
		var net = CWNetworkStats()
		cw_session_get_stats(handle, &net)
		snapshot.rttMs = net.rtt_ms
		snapshot.packetLoss = net.packet_loss
		stats = snapshot
	}

	private func teardown() {
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
		guard let h = handle else { return }
		handle = nil
		let box = self.box
		self.box = nil
		// cw_session_free joins libchiaki's thread; never do that on the main thread.
		DispatchQueue.global(qos: .userInitiated).async {
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
