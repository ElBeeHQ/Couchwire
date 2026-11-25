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
	/// At home: once the network has been calm for a while, bring the reserve back down quickly
	/// after a burst (a Wi-Fi scan, say), so the sound doesn't trail the picture for minutes.
	var fastRecovery = false
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
								 minimum: minimumLatency, maximum: maximumLatency, fastRecovery: fastRecovery)
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
/// Float32 on read, with an adaptive reserve (jitter buffer). Lock-free: the writer and the
/// real-time reader share only two running sample counts, so the audio callback never waits.
///
/// The reserve starts at `minimum` and grows by 20 ms each time it runs dry (a gap you'd hear),
/// up to `maximum`. After 10 s without a gap it shrinks by 5 ms, back towards `minimum`. A backlog
/// is worked off by playing about 2% faster, which you can't hear, rather than by skipping ahead.
///
/// With `fastRecovery` (home), once there's been no gap for 30 s it shrinks by 10 ms every 3 s
/// instead, and works off anything over the reserve, so it's back to normal in about half a
/// minute. While gaps keep coming it stays up, as before.
final class PCMRingBuffer: @unchecked Sendable {
	private let storage: UnsafeMutablePointer<Int16>
	private let capacity: Int
	/// Shared counts (atomics): samples ever written, samples ever read, and for the stats panel
	/// the reserve (frames) and gaps so far. Only the writer stores `written`; only the reader
	/// stores the rest.
	private let shared: UnsafeMutablePointer<Int64>
	private static let written = 0, readCount = 1, targetShown = 2, gapsShown = 3
	private let channels: Int

	// Reader-only state from here on.
	private var primed = false
	private var readTotal = 0
	private let minTarget: Int
	private let maxTarget: Int
	private let step: Int
	private let shrinkStep: Int
	private let calmFrames: Int
	private let fastRecovery: Bool
	private let settledFrames: Int
	private let fastShrinkStep: Int
	private let fastCalmFrames: Int
	private var lastGap = 0
	/// Frames to have buffered before playing.
	private var target: Int
	private var framesPlayed = 0
	private var lastChange = 0
	private var skipPhase = 0
	private var underrunsTotal = 0
	/// Ramps the first few frames after a gap up from silence, so restarts don't click.
	private var fadeIn = 0

	init(sampleRate: Double, channels: Int, minimum: TimeInterval, maximum: TimeInterval, fastRecovery: Bool = false) {
		self.channels = channels
		// Room for 1 s, far beyond the largest reserve.
		capacity = Int(sampleRate) * channels
		storage = .allocate(capacity: capacity)
		storage.initialize(repeating: 0, count: capacity)
		shared = .allocate(capacity: 4)
		shared.initialize(repeating: 0, count: 4)
		minTarget = Int(sampleRate * minimum)
		maxTarget = Int(sampleRate * maximum)
		step = Int(sampleRate * 0.02)
		shrinkStep = Int(sampleRate * 0.005)
		calmFrames = Int(sampleRate * 10)
		self.fastRecovery = fastRecovery
		settledFrames = Int(sampleRate * 30)
		fastShrinkStep = Int(sampleRate * 0.01)
		fastCalmFrames = Int(sampleRate * 3)
		target = minTarget
		cw_atomic_store(shared + Self.targetShown, Int64(target))
	}

	deinit {
		storage.deallocate()
		shared.deallocate()
	}

	/// The reserve now, in ms, and how many gaps there have been. Any thread.
	func status(sampleRate: Double) -> (bufferedMs: Double, targetMs: Double, gaps: Int) {
		let read = cw_atomic_load(shared + Self.readCount)
		let count = Int(cw_atomic_load(shared + Self.written) - read)
		let target = Int(cw_atomic_load(shared + Self.targetShown))
		return (Double(count / channels) / sampleRate * 1000, Double(target) / sampleRate * 1000,
				Int(cw_atomic_load(shared + Self.gapsShown)))
	}

	/// The producer (libchiaki's audio thread). If the ring is full, the newest whole frames are
	/// dropped; the reader skips ahead once it's far behind, so that only happens after a long stall.
	func write(_ samples: UnsafeBufferPointer<Int16>) {
		let written = Int(shared[Self.written]) // only this thread stores it
		let count = written - Int(cw_atomic_load(shared + Self.readCount))
		var n = min(samples.count, capacity - count)
		n -= n % channels
		guard n > 0 else { return }
		for i in 0..<n {
			storage[(written + i) % capacity] = samples[i]
		}
		cw_atomic_store(shared + Self.written, Int64(written + n))
	}

	/// The consumer: the real-time render callback. Never blocks.
	func read(into abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
		let cap = capacity
		var readIndex = readTotal
		var count = Int(cw_atomic_load(shared + Self.written)) - readIndex
		// Full: playback stalled and the writer has been dropping the newest sound, so what's here is
		// stale. Throw it all away and rebuild the reserve from live sound.
		if count >= capacity - channels {
			readIndex += count
			count = 0
		}
		// Hopelessly behind (a long stall, then everything at once): skip to the reserve rather
		// than play seconds late.
		if count / channels > target + maxTarget * 2 {
			let drop = (count / channels - target) * channels
			readIndex += drop
			count -= drop
		}
		let gapsBefore = underrunsTotal
		let targetBefore = target
		for frame in 0..<frames {
			// Fast recovery only once there's been no gap for a while.
			let settled = fastRecovery && framesPlayed - lastGap > settledFrames
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
				readIndex += channels
				count -= channels
				// Well over the reserve: drop one frame in 50 to catch up gently.
				if count / channels > (settled ? target + step : target * 2 + step) {
					skipPhase += 1
					if skipPhase >= 50, count >= channels {
						skipPhase = 0
						readIndex += channels
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
					lastGap = framesPlayed
				}
			}
			framesPlayed += 1
			if framesPlayed - lastChange > (settled ? fastCalmFrames : calmFrames), target > minTarget {
				target = max(target - (settled ? fastShrinkStep : shrinkStep), minTarget)
				lastChange = framesPlayed
			}
		}
		readTotal = readIndex
		cw_atomic_store(shared + Self.readCount, Int64(readIndex))
		if target != targetBefore { cw_atomic_store(shared + Self.targetShown, Int64(target)) }
		if underrunsTotal != gapsBefore { cw_atomic_store(shared + Self.gapsShown, Int64(underrunsTotal)) }
	}
}
