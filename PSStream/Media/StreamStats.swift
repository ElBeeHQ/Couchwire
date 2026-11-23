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
	}

	static let historyLength = 240

	struct Snapshot: Equatable {
		var fps: Double = 0
		var bitrateMbps: Double = 0
		var decodeAvgMs: Double = 0
		var decodeMaxMs: Double = 0
		var displayWaitAvgMs: Double = 0
		var frameJitterMs: Double = 0
		var refreshHz: Double = 0
		var framesLost = 0
		var decodeErrors = 0
		var resolution = ""
		var codec = ""
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
		/// Mac-side latency: from the whole frame arriving to it being on screen.
		var clientMs: Double { decodeAvgMs + displayWaitAvgMs }
		/// Everything we can measure from button to photon: our input handling, the network
		/// both ways (input up, video down) and the client side. Excludes the PS5's own game
		/// frame and capture/encode time, which no client can see.
		var observedMs: Double { inputAvgMs + networkRttMs + clientMs }
	}

	private var lock = os_unfair_lock()
	private var window = Window()
	private var framesLostTotal = 0
	private var decodeErrorsTotal = 0
	private var lastArrival: CFTimeInterval = 0
	private var vsyncTimestamp: CFTimeInterval = 0
	private var vsyncDuration: CFTimeInterval = 0
	private var resolution = ""
	private let codec: String
	private var lastInterval: Double = 0
	private var history: [FrameSample] = []
	private var historyHead = 0
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
	}

	init(codec: String) {
		self.codec = codec
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
			}
			s.refreshHz = vsyncDuration > 0 ? 1 / vsyncDuration : 0
			s.framesLost = framesLostTotal
			s.decodeErrors = decodeErrorsTotal
			s.resolution = resolution
			s.codec = codec
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
