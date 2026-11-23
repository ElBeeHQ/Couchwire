import AVFoundation
import os

/// Plays the decoded PCM stream through AVAudioEngine. A small ring buffer sits between
/// libchiaki's network thread (producer) and the real-time render callback (consumer),
/// keeping latency at roughly two Opus frames.
final class AudioPlayer: @unchecked Sendable {
	private let engine = AVAudioEngine()
	private var sourceNode: AVAudioSourceNode?
	private var ring: PCMRingBuffer?
	let microphone = MicrophoneCapture()
	/// Whether the mic tap (and voice processing) is installed. Once on it stays on for the
	/// session: switching voice processing back off leaves the engine unable to restart
	/// (error -10875), which silenced the game. Muting just stops sending.
	private var micInstalled = false
	private let log = Logger(subsystem: "Couchwire", category: "Audio")

	var volume: Float {
		get { engine.mainMixerNode.outputVolume }
		set { engine.mainMixerNode.outputVolume = newValue }
	}

	func configure(channels: Int, sampleRate: Double) {
		if let sourceNode {
			engine.stop()
			engine.detach(sourceNode)
			self.sourceNode = nil
		}
		// ~100 ms of capacity; we trim to a low target latency on underrun/overrun.
		let ring = PCMRingBuffer(capacity: Int(sampleRate / 10) * channels, channels: channels)
		self.ring = ring

		guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
										 channels: AVAudioChannelCount(channels), interleaved: false) else { return }

		let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
			ring.read(into: UnsafeMutableAudioBufferListPointer(audioBufferList), frames: Int(frameCount))
			return noErr
		}
		sourceNode = node
		engine.attach(node)
		engine.connect(node, to: engine.mainMixerNode, format: format)
		do {
			try engine.start()
			log.info("Audio started: \(channels) ch @ \(sampleRate) Hz")
		} catch {
			log.error("Audio engine failed to start: \(error.localizedDescription, privacy: .public)")
		}
	}

	func enqueue(_ samples: UnsafeBufferPointer<Int16>) {
		ring?.write(samples)
	}

	/// Starts or pauses sending your voice. The first time, voice processing is switched on
	/// and the engine restarts, so game audio drops out for a moment. Returns whether the
	/// mic is now live.
	@discardableResult
	func setMicrophone(_ on: Bool) -> Bool {
		if on && !micInstalled {
			engine.stop()
			micInstalled = microphone.install(on: engine)
			do { try engine.start() } catch {
				log.error("Audio engine failed to restart with the mic: \(error.localizedDescription, privacy: .public)")
			}
		}
		microphone.paused = !(on && micInstalled)
		return on && micInstalled
	}

	func stop() {
		microphone.send = nil
		engine.stop()
		if micInstalled {
			microphone.uninstall(from: engine)
			micInstalled = false
		}
		if let sourceNode {
			engine.detach(sourceNode)
		}
		sourceNode = nil
		ring = nil
	}
}

/// Single-producer/single-consumer interleaved Int16 ring buffer that de-interleaves to
/// Float32 on read. Guarded by an unfair lock; critical sections are tiny memcpy-like loops.
final class PCMRingBuffer: @unchecked Sendable {
	private var storage: [Int16]
	private var readIndex = 0
	private var count = 0
	private let channels: Int
	private var lock = os_unfair_lock()
	private var primed = false
	/// Start playback only once ~20 ms is buffered, to absorb network jitter.
	private let primeThreshold: Int

	init(capacity: Int, channels: Int) {
		storage = [Int16](repeating: 0, count: capacity)
		self.channels = channels
		primeThreshold = capacity / 5
	}

	func write(_ samples: UnsafeBufferPointer<Int16>) {
		os_unfair_lock_lock(&lock)
		defer { os_unfair_lock_unlock(&lock) }
		let cap = storage.count
		for s in samples {
			if count == cap { // overrun: drop oldest to stay live
				readIndex = (readIndex + 1) % cap
				count -= 1
			}
			storage[(readIndex + count) % cap] = s
			count += 1
		}
		// Latency cap: if a network burst piled up more than ~3x the target, skip ahead
		// to the target instead of letting audio drift behind the video.
		let maxBuffered = primeThreshold * 3
		if count > maxBuffered {
			var drop = count - primeThreshold
			drop -= drop % channels
			readIndex = (readIndex + drop) % cap
			count -= drop
		}
	}

	func read(into abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
		os_unfair_lock_lock(&lock)
		defer { os_unfair_lock_unlock(&lock) }
		if !primed && count >= primeThreshold { primed = true }
		let cap = storage.count
		for frame in 0..<frames {
			let available = primed && count >= channels
			for ch in 0..<min(channels, abl.count) {
				let out = abl[ch].mData!.assumingMemoryBound(to: Float.self)
				if available {
					out[frame] = Float(storage[(readIndex + ch) % cap]) / 32768.0
				} else {
					out[frame] = 0
				}
			}
			if available {
				readIndex = (readIndex + channels) % cap
				count -= channels
			} else {
				primed = false // underrun: re-prime
			}
		}
	}
}
