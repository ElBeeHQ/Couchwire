import XCTest
@testable import Couchwire

/// Only the parts that don't read or write the app's saved settings: the test host shares
/// Couchwire's defaults, so `record` and `step(for:)` aren't called here.
final class ConnectionQualityTests: XCTestCase {
	func testLadderGetsWorseStepByStep() {
		let ladder = ConnectionQuality.ladder
		for (better, worse) in zip(ladder, ladder.dropFirst()) {
			XCTAssertGreaterThan(better.bitrate, worse.bitrate)
			XCTAssertGreaterThanOrEqual(better.fps, worse.fps)
		}
		XCTAssertEqual(ladder.first, .init(resolution: .p1080, fps: 60, bitrate: 50_000))
	}

	func testApplyNeverGoesAboveTheUsersSettings() {
		var ceiling = StreamSettings()
		ceiling.resolution = .p720
		ceiling.fps = 30
		ceiling.bitrate = 8_000
		ceiling.codec = .h264
		let s = ConnectionQuality.apply(ConnectionQuality.ladder[0], ceiling: ceiling)
		XCTAssertEqual(s.resolution, .p720)
		XCTAssertEqual(s.fps, 30)
		XCTAssertEqual(s.bitrate, 8_000)
		XCTAssertEqual(s.codec, .h264, "the user's codec always applies")
	}

	func testApplyStepsDown() {
		let s = ConnectionQuality.apply(.init(resolution: .p720, fps: 60, bitrate: 6_000), ceiling: StreamSettings())
		XCTAssertEqual(s.resolution, .p720)
		XCTAssertEqual(s.bitrate, 6_000)
	}
}

final class StruggleDetectorTests: XCTestCase {
	private func snapshot(loss: Double = 0, late: Double = 0, framesLost: Int = 0, ping: Double? = 5, jitter: Double = 1) -> StreamStats.Snapshot {
		var s = StreamStats.Snapshot()
		s.packetLoss = loss
		s.lateFrameRatio = late
		s.framesLost = framesLost
		s.pingMs = ping
		s.pingJitterMs = jitter
		return s
	}

	func testIgnoresTheFirstSeconds() {
		var d = StruggleDetector()
		for _ in 0..<12 { d.add(snapshot(loss: 0.5)) }
		XCTAssertFalse(d.struggling)
		XCTAssertNil(d.outcome)
	}

	func testMostlyBadIsStrugglingAndRecovers() {
		var d = StruggleDetector()
		for _ in 0..<12 { d.add(snapshot()) }
		for _ in 0..<20 { d.add(snapshot(loss: 0.05)) }
		XCTAssertTrue(d.struggling)
		XCTAssertTrue(d.strugglingNow)
		XCTAssertEqual(d.reason, .loss)
		for _ in 0..<20 { d.add(snapshot()) }
		XCTAssertFalse(d.strugglingNow, "the banner goes once things are fine again")
		XCTAssertTrue(d.struggling, "the session still counts as struggling")
		XCTAssertEqual(d.outcome, .struggled)
	}

	func testLateFramesAreTheReason() {
		var d = StruggleDetector()
		for _ in 0..<(12 + 20) { d.add(snapshot(late: 0.3)) }
		XCTAssertEqual(d.reason, .late)
	}

	func testSmoothAndExcellent() {
		var steady = StruggleDetector()
		for _ in 0..<(12 + 180) { steady.add(snapshot()) }
		XCTAssertEqual(steady.outcome, .excellent)

		var noPing = StruggleDetector()
		for _ in 0..<(12 + 180) { noPing.add(snapshot(ping: nil)) }
		XCTAssertEqual(noPing.outcome, .smooth)

		var short = StruggleDetector()
		for _ in 0..<(12 + 100) { short.add(snapshot()) }
		XCTAssertNil(short.outcome, "too short to tell")
	}

	func testLongerGraceAfterANetworkChange() {
		var d = StruggleDetector(afterNetworkChange: true)
		for _ in 0..<60 { d.add(snapshot(loss: 0.5)) }
		XCTAssertFalse(d.struggling)
	}
}

final class LatencyRatingTests: XCTestCase {
	func testThresholds() {
		XCTAssertEqual(LatencyRating(ms: 0), .measuring)
		XCTAssertEqual(LatencyRating(ms: 19.9), .excellent)
		XCTAssertEqual(LatencyRating(ms: 20), .good)
		XCTAssertEqual(LatencyRating(ms: 34.9), .good)
		XCTAssertEqual(LatencyRating(ms: 35), .noticeable)
	}
}
