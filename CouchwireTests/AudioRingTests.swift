import AVFoundation
import XCTest
@testable import Couchwire

/// A two-channel float output buffer list for `PCMRingBuffer.read`.
private final class Output {
	let list: UnsafeMutableAudioBufferListPointer
	let frames: Int
	init(frames: Int, channels: Int = 2) {
		self.frames = frames
		list = AudioBufferList.allocate(maximumBuffers: channels)
		for ch in 0..<channels {
			let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
			p.initialize(repeating: .nan, count: frames)
			list[ch] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: p)
		}
	}
	deinit {
		for b in list { b.mData?.deallocate() }
		free(list.unsafeMutablePointer)
	}
	func channel(_ ch: Int) -> [Float] {
		Array(UnsafeBufferPointer(start: list[ch].mData!.assumingMemoryBound(to: Float.self), count: frames))
	}
}

final class PCMRingBufferTests: XCTestCase {
	/// 1 kHz "sample rate" keeps the numbers small: a 20 ms reserve is 20 frames.
	private func ring(min: Double = 0.02, max: Double = 0.1) -> PCMRingBuffer {
		PCMRingBuffer(sampleRate: 1000, channels: 2, minimum: min, maximum: max)
	}

	private func write(_ ring: PCMRingBuffer, frames: Range<Int>) {
		let samples = frames.flatMap { [Int16($0), Int16(-$0)] }
		samples.withUnsafeBufferPointer { ring.write($0) }
	}

	func testWaitsForTheReserveThenDeinterleaves() {
		let ring = ring()
		write(ring, frames: 1..<11) // 10 frames: under the 20-frame reserve
		let out = Output(frames: 5)
		ring.read(into: out.list, frames: 5)
		XCTAssertEqual(out.channel(0), [0, 0, 0, 0, 0], "silent until the reserve is full")

		write(ring, frames: 11..<101)
		let out2 = Output(frames: 80)
		ring.read(into: out2.list, frames: 80)
		let left = out2.channel(0), right = out2.channel(1)
		// After the 64-frame fade-in, the samples come through in order, left and right apart.
		XCTAssertEqual(left[70], Float(71) / 32768, accuracy: 1e-7)
		XCTAssertEqual(right[70], -Float(71) / 32768, accuracy: 1e-7)
		XCTAssertEqual(left[0], 0, "the fade-in starts from silence")
		XCTAssertEqual(ring.status(sampleRate: 1000).gaps, 0)
	}

	func testRunningDryCountsAGapAndGrowsTheReserve() {
		let ring = ring()
		write(ring, frames: 1..<31)
		let out = Output(frames: 40)
		ring.read(into: out.list, frames: 40)
		let status = ring.status(sampleRate: 1000)
		XCTAssertEqual(status.gaps, 1)
		XCTAssertEqual(status.targetMs, 40, accuracy: 0.01, "20 ms plus one 20 ms step")
		XCTAssertEqual(status.bufferedMs, 0)
	}

	func testSkipsAheadWhenFarBehind() {
		let ring = ring(min: 0.02, max: 0.1)
		write(ring, frames: 1..<501) // far past target + 2 × maximum (220 frames)
		XCTAssertEqual(ring.status(sampleRate: 1000).bufferedMs, 500)
		let out = Output(frames: 1)
		ring.read(into: out.list, frames: 1)
		XCTAssertLessThanOrEqual(ring.status(sampleRate: 1000).bufferedMs, 20)
	}

	func testFullRingIsThrownAwayAsStale() {
		let ring = ring(min: 0.02, max: 0.1) // room for 1 s: 1000 frames
		write(ring, frames: 0..<1200)
		XCTAssertEqual(ring.status(sampleRate: 1000).bufferedMs, 1000, "the newest are dropped when full")
		let out = Output(frames: 1)
		ring.read(into: out.list, frames: 1)
		XCTAssertEqual(ring.status(sampleRate: 1000).bufferedMs, 0, "stale sound is discarded")
		XCTAssertEqual(out.channel(0), [0])
	}

	/// The writer and the real-time reader on two threads: every sample read is newer than the last.
	func testConcurrentWriterAndReaderStayInOrder() {
		let ring = PCMRingBuffer(sampleRate: 48_000, channels: 2, minimum: 0.02, maximum: 0.15)
		let done = DispatchSemaphore(value: 0)
		let batches = 120, batch = 240 // 28 800 frames: values stay under Int16.max
		let writer = Thread {
			for n in 0..<batches {
				let samples = (0..<batch).flatMap { i -> [Int16] in
					// Left counts up; right is a constant marker, scaled only during a fade-in.
					return [Int16(n * batch + i + 1), 16_384]
				}
				samples.withUnsafeBufferPointer { ring.write($0) }
				usleep(UInt32.random(in: 500...3000))
			}
			done.signal()
		}
		writer.start()
		var last: Float = 0
		var read = 0
		let out = Output(frames: 256)
		var finished = false
		var drains = 0
		while drains < 40 {
			if !finished { finished = done.wait(timeout: .now()) == .success }
			if finished { drains += 1 }
			ring.read(into: out.list, frames: 256)
			for (l, r) in zip(out.channel(0), out.channel(1)) {
				// Skip silence and the fade-in after a gap.
				guard r == 0.5 else { continue }
				XCTAssertGreaterThan(l, last, "samples never come out of order")
				last = l
				read += 1
			}
			usleep(UInt32.random(in: 500...3000))
		}
		XCTAssertGreaterThan(read, 10_000)
	}
}

final class StereoFloatRingTests: XCTestCase {
	func testPassesFramesThroughAfterPriming() {
		let ring = StereoFloatRing(capacity: 4800)
		let samples = (0..<2000).map { Float($0) }
		samples.withUnsafeBufferPointer { ring.write($0) }
		var left = [Float](repeating: -1, count: 10), right = left
		ring.read(left: &left, right: &right, frames: 10)
		XCTAssertEqual(left, (0..<10).map { Float($0 * 2) })
		XCTAssertEqual(right, (0..<10).map { Float($0 * 2 + 1) })
	}

	func testSilentUntilPrimed() {
		let ring = StereoFloatRing(capacity: 4800)
		let samples = [Float](repeating: 1, count: 100)
		samples.withUnsafeBufferPointer { ring.write($0) }
		var left = [Float](repeating: -1, count: 10), right = left
		ring.read(left: &left, right: &right, frames: 10)
		XCTAssertEqual(left, [Float](repeating: 0, count: 10))
	}
}
