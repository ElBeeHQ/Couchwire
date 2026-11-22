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
	let console: RegisteredConsole
	let displayLayer = AVSampleBufferDisplayLayer()

	@ObservationIgnored private nonisolated(unsafe) var handle: OpaquePointer?
	@ObservationIgnored private let media: MediaSink
	@ObservationIgnored private var input: ControllerInput?
	@ObservationIgnored private var activity: NSObjectProtocol?
	@ObservationIgnored private var box: Unmanaged<MediaSink>?

	init(console: RegisteredConsole, keys: ConsoleKeys, settings: StreamSettings) {
		self.console = console
		displayLayer.videoGravity = .resizeAspect
		displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
		// No control timebase: samples are flagged DisplayImmediately and shown on decode.
		media = MediaSink(
			decoder: VideoDecoder(codec: settings.codec == .hevc ? .hevc : .h264,
								  renderer: displayLayer.sampleBufferRenderer))
		media.owner = self

		var cfg = PSSSessionConfig()
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
		cfg.codec = settings.codec == .hevc ? PSS_CODEC_H265 : PSS_CODEC_H264
		cfg.enable_dualsense = true

		let box = Unmanaged.passRetained(media)
		self.box = box
		var callbacks = PSSSessionCallbacks()
		callbacks.user = box.toOpaque()
		callbacks.log = { level, msg, _ in logFromCore(level, msg) }
		callbacks.video = { buf, size, framesLost, _, user in
			let sink = Unmanaged<MediaSink>.fromOpaque(user!).takeUnretainedValue()
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
			sink.rumble?(left, right)
		}
		callbacks.quit = { _, isError, reason, user in
			let sink = Unmanaged<MediaSink>.fromOpaque(user!).takeUnretainedValue()
			let msg = isError ? reason.map { String(cString: $0) } ?? "Disconnected" : nil
			Task { @MainActor in sink.owner?.didQuit(error: msg) }
		}

		var err: Int32 = 0
		handle = pss_session_create(&cfg, callbacks, &err)
		if handle == nil {
			phase = .ended(error: "Couldn’t start session: \(String(cString: pss_error_string(err)))")
			box.release()
			self.box = nil
			return
		}
	}

	func start() {
		guard let handle, phase == .connecting else { return }
		let h = handle
		media.requestKeyframe = { _ = pss_session_request_idr(h) }
		media.decoder.requestKeyframe = { _ = pss_session_request_idr(h) }
		// Keep the system out of App Nap / timer coalescing while streaming.
		activity = ProcessInfo.processInfo.beginActivity(
			options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled],
			reason: "Remote Play streaming")
		let err = pss_session_start(h)
		if err != 0 {
			phase = .ended(error: "Couldn’t start session: \(String(cString: pss_error_string(err)))")
		}
	}

	func submitPIN(_ pin: String) {
		guard let handle else { return }
		phase = .connecting
		_ = pss_session_set_login_pin(handle, pin)
	}

	func stop() {
		teardown()
		if case .ended = phase {} else { phase = .ended(error: nil) }
	}

	func putConsoleToSleep() {
		if let handle { _ = pss_session_go_to_bed(handle) }
	}

	private func didConnect() {
		phase = .streaming
		guard let handle else { return }
		let h = handle
		let input = ControllerInput { state in
			var s = state
			_ = pss_session_set_controller(h, &s)
		}
		media.rumble = { [weak input] l, r in input?.rumble(left: l, right: r) }
		input.start()
		self.input = input
	}

	private func didQuit(error: String?) {
		phase = .ended(error: error)
		teardown()
	}

	private func teardown() {
		input?.stop()
		input = nil
		media.rumble = nil
		media.audio.stop()
		if let activity { ProcessInfo.processInfo.endActivity(activity) }
		activity = nil
		guard let h = handle else { return }
		handle = nil
		let box = self.box
		self.box = nil
		// pss_session_free joins libchiaki's thread; never do that on the main thread.
		DispatchQueue.global(qos: .userInitiated).async {
			pss_session_free(h)
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
	var rumble: ((UInt8, UInt8) -> Void)?
	weak var owner: StreamSession?

	init(decoder: VideoDecoder) {
		self.decoder = decoder
	}
}
