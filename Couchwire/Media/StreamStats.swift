import Foundation
import QuartzCore
import os

/// Thread-safe accumulator for per-frame timings. Written from libchiaki's receive thread,
/// VideoToolbox's output thread and the display link; read twice a second by the overlay.
final class StreamStats: @unchecked Sendable {
	/// One decoded frame, for the frame-pacing graph.
	struct FrameSample: Equatable {
		/// Time since the previous frame finished arriving from the network.
		var intervalMs: Double
		var decodeMs: Double
		var displayWaitMs: Double
		/// Time since the previous frame was due on screen: what you actually see.
		var shownIntervalMs: Double = 0
	}

	static let historyLength = 240

	struct Snapshot: Equatable {
		var fps: Double = 0
		var bitrateMbps: Double = 0
		var decodeAvgMs: Double = 0
		var decodeMaxMs: Double = 0
		var displayWaitAvgMs: Double = 0
		var frameJitterMs: Double = 0
		/// Share of frames that arrived more than a whole frame behind the stream's usual rhythm.
		var lateFrameRatio: Double = 0
		/// How long smoothing held frames back, on average.
		var smoothingMs: Double = 0
		/// Audio held in reserve against uneven arrival, and the gaps heard when it ran dry.
		var audioBufferMs: Double = 0
		var audioGaps = 0
		/// Lost frames and audio gaps in the last 30 seconds, so a single old blip doesn't keep a
		/// figure orange for the rest of the session.
		var recentFramesLost = 0
		var recentAudioGaps = 0
		var refreshHz: Double = 0
		var framesLost = 0
		var decodeErrors = 0
		var resolution = ""
		var codec = ""
		var dynamicRange = ""
		// Input: controller event to hand-off to libchiaki's send thread.
		var inputAvgMs: Double = 0
		var inputMaxMs: Double = 0
		/// Controller reports per second (motion updates arrive once per HID report).
		var inputRateHz: Double = 0
		// Live network, from ICMP echo to the console.
		var pingMs: Double?
		var pingJitterMs: Double = 0
		var pingLost = 0
		var pingHistory: [Double] = []
		var history: [FrameSample] = []
		// Filled from libchiaki
		/// Measured once, before streaming starts.
		var rttMs: Double = 0
		var packetLoss: Double = 0

		/// Live round trip if we have one, else libchiaki's start-of-stream measurement.
		var networkRttMs: Double { pingMs ?? rttMs }
		/// Average wait for the controller's next report: half its report interval.
		var controllerPollMs: Double { inputRateHz > 0 ? 500 / inputRateHz : 0 }
		/// Controller polling plus our handling.
		var controllerMs: Double { controllerPollMs + inputAvgMs }
		/// Mac-side latency: from the whole frame arriving to it being on screen.
		var clientMs: Double { decodeAvgMs + smoothingMs + displayWaitAvgMs }
		/// Everything we can measure from button to photon: our input handling, the network
		/// both ways (input up, video down) and the client side. Excludes the PS5's own game
		/// frame and capture/encode time, which no client can see.
		var observedMs: Double { controllerMs + networkRttMs + clientMs }
	}

	private var lock = os_unfair_lock()
	private var window = Window()
	private var framesLostTotal = 0
	private var decodeErrorsTotal = 0
	private var lastArrival: CFTimeInterval = 0
	private var vsyncTimestamp: CFTimeInterval = 0
	private var vsyncDuration: CFTimeInterval = 0
	private var resolution = ""
	private var dynamicRange = ""
	private let codec: String
	private var lastInterval: Double = 0
	private var history: [FrameSample] = []
	private var historyHead = 0
	private var lastShown: CFTimeInterval = 0
	private var pings: [Double] = []
	private var pingLostTotal = 0

	private struct Window {
		var start: CFTimeInterval = CACurrentMediaTime()
		var frames = 0
		var bytes = 0
		var decodeSum: Double = 0
		var decodeMax: Double = 0
		var waitSum: Double = 0
		var waitCount = 0
		var intervals: [Double] = []
		var inputSum: Double = 0
		var inputMax: Double = 0
		var inputCount = 0
		var reports = 0
		var leadSum: Double = 0
		var leadCount = 0
	}

	/// The stream's frame rate, for spotting late frames.
	private let targetFps: Double

	init(codec: String, fps: Int = 60) {
		self.codec = codec
		targetFps = Double(fps)
	}

	/// How long since the last frame arrived; 0 before the first.
	var secondsSinceLastFrame: Double {
		let now = CACurrentMediaTime()
		return locked { lastArrival > 0 ? now - lastArrival : 0 }
	}

	/// The latest frame is due on screen at `at` (host time).
	func frameShown(at: CFTimeInterval) {
		locked {
			defer { lastShown = at }
			guard lastShown > 0, !history.isEmpty else { return }
			let latest = history.count < Self.historyLength ? history.count - 1
				: (historyHead + Self.historyLength - 1) % Self.historyLength
			history[latest].shownIntervalMs = (at - lastShown) * 1000
		}
	}

	/// Smoothing scheduled a frame this far after it was decoded.
	func frameScheduled(leadMs: Double) {
		locked {
			window.leadSum += leadMs
			window.leadCount += 1
		}
	}

	// MARK: Producers

	func frameArrived(bytes: Int, framesLost: Int32) {
		let now = CACurrentMediaTime()
		locked {
			window.bytes += bytes
			if framesLost > 0 { framesLostTotal += Int(framesLost) }
			if lastArrival > 0 {
				lastInterval = (now - lastArrival) * 1000
				window.intervals.append(lastInterval)
			}
			lastArrival = now
		}
	}

	/// Called when VideoToolbox hands back a decoded frame. Returns nothing; also estimates
	/// how long the frame will wait for the next display refresh.
	func frameDecoded(submittedAt: CFTimeInterval, decodedAt: CFTimeInterval) {
		locked {
			let decodeMs = (decodedAt - submittedAt) * 1000
			window.frames += 1
			window.decodeSum += decodeMs
			window.decodeMax = max(window.decodeMax, decodeMs)
			var waitMs = 0.0
			if vsyncDuration > 0 {
				let elapsed = decodedAt - vsyncTimestamp
				let periods = max(0, ceil(elapsed / vsyncDuration))
				let nextVsync = vsyncTimestamp + periods * vsyncDuration
				waitMs = (nextVsync - decodedAt) * 1000
				window.waitSum += waitMs
				window.waitCount += 1
			}
			let sample = FrameSample(intervalMs: lastInterval, decodeMs: decodeMs, displayWaitMs: waitMs)
			if history.count < Self.historyLength {
				history.append(sample)
			} else {
				history[historyHead] = sample
				historyHead = (historyHead + 1) % Self.historyLength
			}
		}
	}

	/// A controller state change reached libchiaki. Both times are on the same clock
	/// (GameController's event timestamps are Unix time).
	func inputSent(eventAt: TimeInterval, sentAt: TimeInterval) {
		let ms = (sentAt - eventAt) * 1000
		guard ms >= 0, ms < 250 else { return } // ignore stale or clock-mismatched timestamps
		locked {
			window.inputSum += ms
			window.inputMax = max(window.inputMax, ms)
			window.inputCount += 1
		}
	}

	/// One controller HID report received.
	func inputReport() {
		locked { window.reports += 1 }
	}

	/// A ping result, or nil if the probe was lost.
	func ping(_ rttMs: Double?) {
		locked {
			if let rttMs {
				pings.append(rttMs)
				if pings.count > 120 { pings.removeFirst(pings.count - 120) }
			} else {
				pingLostTotal += 1
			}
		}
	}

	func decodeFailed() {
		locked { decodeErrorsTotal += 1 }
	}

	func setDynamicRange(_ range: String) {
		locked { dynamicRange = range }
	}

	func setResolution(width: Int32, height: Int32) {
		locked { resolution = "\(width)×\(height)" }
	}

	/// From the stream view's display link: the timestamp of the refresh being composited.
	func vsync(timestamp: CFTimeInterval, duration: CFTimeInterval) {
		locked {
			vsyncTimestamp = timestamp
			vsyncDuration = duration
		}
	}

	// MARK: Consumer

	func snapshot() -> Snapshot {
		let now = CACurrentMediaTime()
		return locked {
			let w = window
			window = Window(start: now)
			let seconds = max(now - w.start, 0.001)
			var s = Snapshot()
			s.fps = Double(w.frames) / seconds
			s.bitrateMbps = Double(w.bytes) * 8 / seconds / 1_000_000
			s.decodeAvgMs = w.frames > 0 ? w.decodeSum / Double(w.frames) : 0
			s.decodeMaxMs = w.decodeMax
			s.displayWaitAvgMs = w.waitCount > 0 ? w.waitSum / Double(w.waitCount) : 0
			if w.intervals.count > 1 {
				let mean = w.intervals.reduce(0, +) / Double(w.intervals.count)
				let variance = w.intervals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(w.intervals.count)
				s.frameJitterMs = variance.squareRoot()
				// Late against the stream's real rhythm, not its nominal rate: a 30 fps game in a
				// 60 fps stream sends a frame every 33 ms, and that's on time.
				let sorted = w.intervals.sorted()
				let beat = max(sorted[sorted.count / 2], 1000 / targetFps)
				s.lateFrameRatio = Double(w.intervals.filter { $0 > beat * 2 }.count) / Double(w.intervals.count)
			}
			s.smoothingMs = w.leadCount > 0 ? w.leadSum / Double(w.leadCount) : 0
			s.refreshHz = vsyncDuration > 0 ? 1 / vsyncDuration : 0
			s.framesLost = framesLostTotal
			s.decodeErrors = decodeErrorsTotal
			s.resolution = resolution
			s.codec = codec
			s.dynamicRange = dynamicRange
			s.inputAvgMs = w.inputCount > 0 ? w.inputSum / Double(w.inputCount) : 0
			s.inputMaxMs = w.inputMax
			s.inputRateHz = Double(w.reports) / seconds
			s.history = Array(history[historyHead...] + history[..<historyHead])
			if !pings.isEmpty {
				// Latest few probes for the headline; RFC 3550-style jitter over the window.
				let recent = pings.suffix(4)
				s.pingMs = recent.reduce(0, +) / Double(recent.count)
				if pings.count > 1 {
					let diffs = zip(pings.dropFirst(), pings).map { abs($0 - $1) }
					s.pingJitterMs = diffs.reduce(0, +) / Double(diffs.count)
				}
				s.pingHistory = pings
			}
			s.pingLost = pingLostTotal
			return s
		}
	}

	private func locked<T>(_ body: () -> T) -> T {
		os_unfair_lock_lock(&lock)
		defer { os_unfair_lock_unlock(&lock) }
		return body()
	}
}
