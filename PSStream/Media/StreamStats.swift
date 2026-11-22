import Foundation
import QuartzCore
import os

/// Thread-safe accumulator for per-frame timings. Written from libchiaki's receive thread,
/// VideoToolbox's output thread and the display link; read twice a second by the overlay.
final class StreamStats: @unchecked Sendable {
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
		// Filled from libchiaki
		var rttMs: Double = 0
		var packetLoss: Double = 0

		/// Mac-side latency: from the whole frame arriving to it being on screen.
		var clientMs: Double { decodeAvgMs + displayWaitAvgMs }
		/// Everything we can observe: half the round trip + client side. Excludes the
		/// PS5's own capture/encode time, which no client can measure.
		var observedMs: Double { rttMs / 2 + clientMs }
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

	private struct Window {
		var start: CFTimeInterval = CACurrentMediaTime()
		var frames = 0
		var bytes = 0
		var decodeSum: Double = 0
		var decodeMax: Double = 0
		var waitSum: Double = 0
		var waitCount = 0
		var intervals: [Double] = []
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
			if lastArrival > 0 { window.intervals.append((now - lastArrival) * 1000) }
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
			if vsyncDuration > 0 {
				let elapsed = decodedAt - vsyncTimestamp
				let periods = max(0, ceil(elapsed / vsyncDuration))
				let nextVsync = vsyncTimestamp + periods * vsyncDuration
				window.waitSum += (nextVsync - decodedAt) * 1000
				window.waitCount += 1
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
			return s
		}
	}

	private func locked<T>(_ body: () -> T) -> T {
		os_unfair_lock_lock(&lock)
		defer { os_unfair_lock_unlock(&lock) }
		return body()
	}
}
