import AVFoundation
import os

/// Turns the Mac's microphone into the 48 kHz stereo 16-bit frames libchiaki's Opus encoder
/// wants. It taps the input node of the same engine that plays the game audio, with Apple's
/// voice processing switched on, so the echo canceller hears the game and removes it from
/// your voice. Voice processing stays on from the first time the mic is used until the session ends.
final class MicrophoneCapture: @unchecked Sendable {
	static let sampleRate = Double(CW_MIC_SAMPLE_RATE)
	static let frameSamples = Int(CW_MIC_FRAME_SAMPLES)

	private let log = Logger(subsystem: "Couchwire", category: "Microphone")
	private var converter: AVAudioConverter?
	private let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
										   channels: 1, interleaved: false)!
	/// Mono samples waiting to fill the next 480-sample frame. Only touched on the tap thread.
	private var pending: [Float] = []
	private var frame = [Int16](repeating: 0, count: frameSamples * 2)

	/// While true, frames are captured but dropped (the mic is muted).
	var paused: Bool {
		get { os_unfair_lock_lock(&sendLock); defer { os_unfair_lock_unlock(&sendLock) }; return _paused }
		set { os_unfair_lock_lock(&sendLock); _paused = newValue; os_unfair_lock_unlock(&sendLock) }
	}
	private var _paused = true

	private var sendLock = os_unfair_lock()
	private var _send: ((UnsafeMutablePointer<Int16>) -> Void)?
	/// Receives each frame (960 interleaved samples). Cleared before the session is freed.
	var send: ((UnsafeMutablePointer<Int16>) -> Void)? {
		get { os_unfair_lock_lock(&sendLock); defer { os_unfair_lock_unlock(&sendLock) }; return _send }
		set { os_unfair_lock_lock(&sendLock); _send = newValue; os_unfair_lock_unlock(&sendLock) }
	}

	static func requestAccess() async -> Bool {
		switch AVCaptureDevice.authorizationStatus(for: .audio) {
		case .authorized: return true
		case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
		default: return false
		}
	}

	/// Starts capturing on `engine`, which must be stopped. Returns false if the input can't be used.
	func install(on engine: AVAudioEngine) -> Bool {
		let input = engine.inputNode
		do {
			try input.setVoiceProcessingEnabled(true)
		} catch {
			log.error("Voice processing unavailable: \(error.localizedDescription, privacy: .public)")
			return false
		}
		// Don't turn other apps down while chatting.
		input.voiceProcessingOtherAudioDuckingConfiguration =
			AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
		let format = input.outputFormat(forBus: 0)
		guard format.sampleRate > 0, format.channelCount > 0,
			  let converter = AVAudioConverter(from: format, to: monoFormat) else {
			log.error("No usable microphone input (\(format, privacy: .public))")
			try? input.setVoiceProcessingEnabled(false)
			return false
		}
		// Only the first channel is the processed voice; the rest are references.
		converter.channelMap = [0]
		self.converter = converter
		pending.removeAll(keepingCapacity: true)
		input.installTap(onBus: 0, bufferSize: 480, format: format) { [weak self] buffer, _ in
			self?.process(buffer)
		}
		log.info("Microphone on: \(format.channelCount) ch @ \(format.sampleRate) Hz, voice processing")
		return true
	}

	/// Stops capturing on `engine`, which must be stopped.
	func uninstall(from engine: AVAudioEngine) {
		guard converter != nil else { return }
		engine.inputNode.removeTap(onBus: 0)
		try? engine.inputNode.setVoiceProcessingEnabled(false)
		converter = nil
		paused = true
		log.info("Microphone removed")
	}

	private func process(_ buffer: AVAudioPCMBuffer) {
		guard let converter, !paused else { pending.removeAll(keepingCapacity: true); return }
		let ratio = monoFormat.sampleRate / buffer.format.sampleRate
		let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
		guard let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity) else { return }
		var fed = false
		var error: NSError?
		converter.convert(to: out, error: &error) { _, status in
			if fed { status.pointee = .noDataNow; return nil }
			fed = true
			status.pointee = .haveData
			return buffer
		}
		guard error == nil, let samples = out.floatChannelData?[0] else { return }
		pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))

		let n = Self.frameSamples
		while pending.count >= n {
			for i in 0..<n {
				let v = Int16(max(-1, min(1, pending[i])) * 32767)
				frame[2 * i] = v
				frame[2 * i + 1] = v
			}
			pending.removeFirst(n)
			if let send { frame.withUnsafeMutableBufferPointer { send($0.baseAddress!) } }
		}
	}
}
