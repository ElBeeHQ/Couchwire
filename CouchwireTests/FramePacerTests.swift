import XCTest
@testable import Couchwire

final class FramePacerTests: XCTestCase {
	private let frame = 1.0 / 60

	func testSteadyFramesAreShownAtOnce() {
		let pacer = FramePacer(fps: 60, maxHold: 0.05, mode: .balanced, home: true)
		for i in 0..<300 {
			let t = 100 + Double(i) * frame
			XCTAssertEqual(pacer.schedule(decodedAt: t), t, accuracy: 1e-9, "frame \(i)")
		}
	}

	func testOffNeverHolds() {
		let pacer = FramePacer(fps: 60, maxHold: 0.05, mode: .off, home: true)
		var t = 100.0
		for i in 0..<200 {
			t += i % 10 == 0 ? 0.08 : frame // a late frame every 10
			XCTAssertEqual(pacer.schedule(decodedAt: t), t)
		}
	}

	func testBurstyFramesAreHeldButNotPastMaxHold() {
		let maxHold = 0.05
		let pacer = FramePacer(fps: 60, maxHold: maxHold, mode: .balanced, home: true)
		var t = 100.0
		var last = 0.0
		var held = 0.0
		for i in 0..<600 {
			// Every 20th frame arrives 40 ms late, and the next two right behind it.
			t += i % 20 == 0 ? frame + 0.04 : (i % 20 < 3 ? 0.002 : frame)
			let show = pacer.schedule(decodedAt: t)
			XCTAssertGreaterThanOrEqual(show, t)
			XCTAssertLessThanOrEqual(show - t, maxHold + 1e-9)
			if last > 0 { XCTAssertGreaterThan(show, last, "frames stay in order") }
			last = show
			held = max(held, show - t)
		}
		XCTAssertGreaterThan(held, 0.005, "bunched frames are spread out")
	}

	func testAutomaticStepsUpAfterRepeatedLongGaps() {
		let pacer = FramePacer(fps: 60, maxHold: 0.1, mode: .automatic, home: false)
		var t = 100.0
		for _ in 0..<60 { t += frame; _ = pacer.schedule(decodedAt: t) }
		XCTAssertFalse(pacer.steppedUp)
		for _ in 0..<3 {
			t += 0.15 // a long gap
			_ = pacer.schedule(decodedAt: t)
			for _ in 0..<60 { t += frame; _ = pacer.schedule(decodedAt: t) }
		}
		XCTAssertTrue(pacer.steppedUp)
		// A minute and a bit of calm steps back down.
		for _ in 0..<(65 * 60) { t += frame; _ = pacer.schedule(decodedAt: t) }
		XCTAssertFalse(pacer.steppedUp)
	}

	func testSmoothingModeResolution() {
		XCTAssertEqual(SmoothingMode.automatic.resolved(for: .internetMobile), .automatic)
		XCTAssertEqual(SmoothingMode.automatic.resolved(for: .homeWireless), .balanced)
		XCTAssertEqual(SmoothingMode.steadiest.resolved(for: .homeWired), .steadiest)
	}
}
