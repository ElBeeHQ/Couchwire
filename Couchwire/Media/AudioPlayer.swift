import AVFoundation
import os

/// Plays the decoded PCM stream through AVAudioEngine. A small ring buffer sits between
/// libchiaki's network thread (producer) and the real-time render callback (consumer),
/// keeping just enough in reserve to cover the network's unevenness.
final class AudioPlayer: @unchecked Sendable {
	private let engine = AVAudioEngine()
	private var sourceNode: AVAudioSourceNode?
	private var ring: PCMRingBuffer?
	/// Runs on its own engine; see MicrophoneCapture.
	let microphone = MicrophoneCapture()
	private let log = Logger(subsystem: "Couchwire", category: "Audio")

	/// The smallest audio reserve. More over the internet, where packets arrive less evenly.
	var minimumLatency: TimeInterval = 0.02
	/// The largest it may grow to. Mobile networks need more.
	var maximumLatency: TimeInterval = 0.15
	private var sampleRate: Double = 48_000

	/// The reserve now and how many gaps there have been, for the stats panel.
	var status: (bufferedMs: Double, targetMs: Double, gaps: Int)? {
		ring?.status(sampleRate: sampleRate)
	}

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
		let ring = PCMRingBuffer(sampleRate: sampleRate, channels: channels,
								 minimum: minimumLatency, maximum: maximumLatency)
		self.ring = ring
		self.sampleRate = sampleRate

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

	/// How long the mic keeps running after a mute before the input is released (and the
	/// orange indicator goes out). Quick mute/unmute within this window is seamless.
	static let micReleaseDelay: TimeInterval = 5 * 60
	private var micRelease: DispatchWorkItem?

	/// Unmutes (starting the mic if needed) or mutes. Muting drops your voice at once and
	/// releases the input after `micReleaseDelay`. Main thread only. Returns whether it's live.
	@discardableResult
	func setMicrophone(_ on: Bool) -> Bool {
		micRelease?.cancel()
		micRelease = nil
		if on {
			microphone.muted = false
			return microphone.start()
		}
		microphone.muted = true
		let release = DispatchWorkItem { [microphone] in microphone.stop() }
		micRelease = release
		DispatchQueue.main.asyncAfter(deadline: .now() + Self.micReleaseDelay, execute: release)
		return false
	}

	func stop() {
		microphone.send = nil
		micRelease?.cancel()
		micRelease = nil
		microphone.stop()
		engine.stop()
		if let sourceNode {
			engine.detach(sourceNode)
		}
		sourceNode = nil
		ring = nil
	}
}

/// Single-producer/single-consumer interleaved Int16 ring buffer that de-interleaves to
/// Float32 on read, with an adaptive reserve (jitter buffer). Guarded by an unfair lock;
/// critical sections are tiny memcpy-like loops.
///
/// The reserve starts at `minimum` and grows by 20 ms each time it runs dry (a gap you'd hear),
/// up to `maximum`. After 10 s without a gap it shrinks by 5 ms, back towards `minimum`. A backlog
/// is worked off by playing about 2% faster, which you can't hear, rather than by skipping ahead.
final class PCMRingBuffer: @unchecked Sendable {
	private var storage: [Int16]
	private var readIndex = 0
	/// Samples (not frames) buffered.
	private var count = 0
	private let channels: Int
	private var lock = os_unfair_lock()
	private var primed = false

	private let minTarget: Int
	private let maxTarget: Int
	private let step: Int
	private let shrinkStep: Int
	private let calmFrames: Int
	/// Frames to have buffered before playing.
	private var target: Int
	private var framesPlayed = 0
	private var lastChange = 0
	private var skipPhase = 0
	private var underrunsTotal = 0
	/// Ramps the first few frames after a gap up from silence, so restarts don't click.
	private var fadeIn = 0

	init(sampleRate: Double, channels: Int, minimum: TimeInterval, maximum: TimeInterval) {
		self.channels = channels
		// Room for 1 s, far beyond the largest reserve.
		storage = [Int16](repeating: 0, count: Int(sampleRate) * channels)
		minTarget = Int(sampleRate * minimum)
		maxTarget = Int(sampleRate * maximum)
		step = Int(sampleRate * 0.02)
		shrinkStep = Int(sampleRate * 0.005)
		calmFrames = Int(sampleRate * 10)
		target = minTarget
	}

	/// The reserve now, in ms, and how many gaps there have been.
	func status(sampleRate: Double) -> (bufferedMs: Double, targetMs: Double, gaps: Int) {
		os_unfair_lock_lock(&lock)
		defer { os_unfair_lock_unlock(&lock) }
		return (Double(count / channels) / sampleRate * 1000, Double(target) / sampleRate * 1000, underrunsTotal)
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
		// Hopelessly behind (a long stall, then everything at once): skip to the reserve rather
		// than play seconds late.
		let frames = count / channels
		if frames > target + maxTarget * 2 {
			let drop = (frames - target) * channels
			readIndex = (readIndex + drop) % cap
			count -= drop
		}
	}

	func read(into abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
		os_unfair_lock_lock(&lock)
		defer { os_unfair_lock_unlock(&lock) }
		let cap = storage.count
		for frame in 0..<frames {
			if !primed && count / channels >= target {
				primed = true
				fadeIn = 64
			}
			let available = primed && count >= channels
			if available {
				let gain: Float = fadeIn > 0 ? Float(64 - fadeIn) / 64 : 1
				if fadeIn > 0 { fadeIn -= 1 }
				for ch in 0..<min(channels, abl.count) {
					abl[ch].mData!.assumingMemoryBound(to: Float.self)[frame] =
						Float(storage[(readIndex + ch) % cap]) / 32768.0 * gain
				}
				readIndex = (readIndex + channels) % cap
				count -= channels
				// Well over the reserve: drop one frame in 50 to catch up gently.
				if count / channels > target * 2 + step {
					skipPhase += 1
					if skipPhase >= 50, count >= channels {
						skipPhase = 0
						readIndex = (readIndex + channels) % cap
						count -= channels
					}
				}
			} else {
				for ch in 0..<min(channels, abl.count) {
					abl[ch].mData!.assumingMemoryBound(to: Float.self)[frame] = 0
				}
				if primed {
					// Ran dry: a gap. Keep more in reserve from now on.
					primed = false
					underrunsTotal += 1
					target = min(target + step, maxTarget)
					lastChange = framesPlayed
				}
			}
			framesPlayed += 1
			if framesPlayed - lastChange > calmFrames, target > minTarget {
				target = max(target - shrinkStep, minTarget)
				lastChange = framesPlayed
			}
		}
	}
}
