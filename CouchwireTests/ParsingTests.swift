import XCTest
@testable import Couchwire

final class AnnexBTests: XCTestCase {
	private func ranges(_ bytes: [UInt8]) -> [[UInt8]] {
		bytes.withUnsafeBufferPointer { buf in VideoDecoder.nalRanges(buf).map { Array(buf[$0]) } }
	}

	func testSplitsOnThreeAndFourByteStartCodes() {
		let stream: [UInt8] = [0, 0, 0, 1, 0x40, 1, 2, 0, 0, 1, 0x42, 3, 0, 0, 0, 1, 0x26, 9, 9]
		XCTAssertEqual(ranges(stream), [[0x40, 1, 2], [0x42, 3], [0x26, 9, 9]])
	}

	func testEmptyAndOddInputs() {
		XCTAssertEqual(ranges([]), [])
		XCTAssertEqual(ranges([1, 2, 3]), [], "no start code, no units")
		XCTAssertEqual(ranges([0, 0, 1]), [], "a start code with nothing after it")
		XCTAssertEqual(ranges([0, 0, 1, 0, 0, 1, 7]), [[7]], "empty units are left out")
		XCTAssertEqual(ranges([0, 0, 1, 1, 1, 0, 1]), [[1, 1, 0, 1]], "01 bytes inside a unit aren't start codes")
	}

	/// Matches the old byte-by-byte splitter on random streams made mostly of 00 and 01.
	func testMatchesASimpleSplitter() {
		func simple(_ buf: [UInt8]) -> [[UInt8]] {
			var result: [[UInt8]] = []
			var i = 0, start = -1
			while i + 2 < buf.count {
				if buf[i] == 0, buf[i + 1] == 0, buf[i + 2] == 1 {
					if start >= 0 {
						var end = i
						if end > start, buf[end - 1] == 0 { end -= 1 }
						if end > start { result.append(Array(buf[start..<end])) }
					}
					i += 3
					start = i
				} else { i += 1 }
			}
			if start >= 0, start < buf.count { result.append(Array(buf[start...])) }
			return result
		}
		for _ in 0..<5000 {
			let bytes = (0..<Int.random(in: 0...48)).map { _ in [0, 0, 0, 1, 2, 0x40].randomElement()! as UInt8 }
			XCTAssertEqual(ranges(bytes), simple(bytes), "\(bytes)")
		}
	}

	func testPacksWithBigEndianLengths() {
		let stream: [UInt8] = [0, 0, 0, 1, 0x26, 1, 2, 0, 0, 1, 0x02, 3]
		var out = [UInt8](repeating: 0xEE, count: 4 + 3 + 4 + 2)
		stream.withUnsafeBufferPointer { buf in
			let nals = VideoDecoder.nalRanges(buf)
			out.withUnsafeMutableBytes { VideoDecoder.packAVCC(buf, nals: nals, into: $0) }
		}
		XCTAssertEqual(out, [0, 0, 0, 3, 0x26, 1, 2, 0, 0, 0, 2, 0x02, 3])
	}
}

final class CRC32Tests: XCTestCase {
	func testKnownValues() {
		XCTAssertEqual(CRC32.update(0, Array("123456789".utf8)), 0xCBF4_3926)
		XCTAssertEqual(CRC32.update(0, [UInt8]()), 0)
		// Feeding in pieces gives the same result, as the Bluetooth report does.
		let whole = CRC32.update(0, [0xA2, 1, 2, 3, 4])
		XCTAssertEqual(CRC32.update(CRC32.update(0, [0xA2]), [1, 2, 3, 4]), whole)
	}
}

final class HexTests: XCTestCase {
	func testRoundTrip() {
		let data = Data([0x00, 0x7F, 0xA5, 0xFF])
		XCTAssertEqual(data.hexString, "007FA5FF")
		XCTAssertEqual(Data(hexString: "007FA5FF"), data)
		XCTAssertEqual(Data(hexString: "007fa5ff"), data)
		XCTAssertEqual(Data(hexString: ""), Data())
	}

	func testRejectsWhatIsNotHex() {
		XCTAssertNil(Data(hexString: "ABC"), "odd length")
		XCTAssertNil(Data(hexString: "zz"))
		XCTAssertNil(Data(hexString: "+f"), "a sign inside a byte")
		XCTAssertNil(Data(hexString: "0 "))
		XCTAssertNil(Data(hexString: "é1"))
	}
}

final class TriggerEffectTests: XCTestCase {
	private func params(_ bytes: [UInt8]) -> [UInt8] { bytes + [UInt8](repeating: 0, count: 10 - bytes.count) }

	func testOffAndUnknown() {
		XCTAssertEqual(TriggerEffect(type: 0x00, params: params([])), .off)
		XCTAssertEqual(TriggerEffect(type: 0x05, params: params([])), .off)
		XCTAssertNil(TriggerEffect(type: 0x7F, params: params([])))
		XCTAssertNil(TriggerEffect(type: 0x21, params: [1, 2]), "too few bytes")
	}

	func testSimpleWeapon() {
		XCTAssertEqual(TriggerEffect(type: 0x02, params: params([51, 102, 255])),
					   .weapon(start: 0.2, end: 0.4, strength: 1))
	}

	func testZonedFeedback() {
		// Zones 0 and 9 on; zone 0 strength 7 (full), zone 9 strength 0 (one eighth).
		let mask: UInt16 = 1 | 1 << 9
		let effect = TriggerEffect(type: 0x21, params: params([UInt8(mask & 0xFF), UInt8(mask >> 8), 7, 0, 0, 0]))
		guard case .feedback(let s)? = effect else { return XCTFail("\(String(describing: effect))") }
		XCTAssertEqual(s.count, 10)
		XCTAssertEqual(s[0], 1)
		XCTAssertEqual(s[9], 0.125)
		XCTAssertEqual(s[1...8].reduce(0, +), 0)
	}

	func testZonedWeaponUsesFirstAndLastZone() {
		let mask: UInt16 = 1 << 2 | 1 << 5
		let effect = TriggerEffect(type: 0x25, params: params([UInt8(mask & 0xFF), UInt8(mask >> 8), 3]))
		XCTAssertEqual(effect, .weapon(start: 2.0 / 9, end: 5.0 / 9, strength: 0.5))
		XCTAssertEqual(TriggerEffect(type: 0x25, params: params([0, 0, 3])), .off, "no zones")
	}
}

final class LogMaskingTests: XCTestCase {
	func testHidesAddresses() {
		XCTAssertEqual(maskAddresses("Connecting to 192.168.1.20:9295"), "Connecting to <address>:9295")
		XCTAssertEqual(maskAddresses("candidate fe80::1c2b:3a4d:5e6f:7a8b%en0"), "candidate <address>%en0")
		XCTAssertEqual(maskAddresses("mac a0:b1:c2:d3:e4:f5 seen"), "mac <address> seen")
	}

	func testLeavesOrdinaryTextAlone() {
		for line in ["PSN: no answer from the console yet; asking again",
					 "session.c:123: something", "Bitrate 15.5 Mbps", "at 12:30"] {
			XCTAssertEqual(maskAddresses(line), line)
		}
	}
}
