import Foundation
import IOKit.hid
import os

/// Sends output reports straight to a DualSense over IOKit HID.
///
/// GameController's adaptive-trigger API doesn't reliably reach the controller on every
/// macOS/firmware combination, so trigger effects go out as raw DualSense output reports
/// instead. That also passes the console's effect bytes through untouched, so every effect
/// type is reproduced exactly. Same report format SDL (and therefore chiaki-ng/Steam) uses.
final class DualSenseHID: @unchecked Sendable {
	private static let sonyVendorID = 0x054C
	private static let productIDs = [0x0CE6 /* DualSense */, 0x0DF2 /* DualSense Edge */]

	private let manager: IOHIDManager
	private let device: IOHIDDevice
	let isBluetooth: Bool
	/// Called once, on the HID queue, the first time a report fails to send — typically
	/// because the controller disconnected or switched between Bluetooth and USB.
	var onFailure: (() -> Void)?
	private var failed = false
	private let queue = DispatchQueue(label: "Couchwire.hid", qos: .userInteractive)
	private let log = Logger(subsystem: "Couchwire", category: "Feedback")
	private let reports: InputReports?

	/// Owns the input-report buffer and callback; released by the device's cancel handler,
	/// so it outlives any callback still in flight.
	private final class InputReports {
		let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
		let handler: (UInt64, UInt8?) -> Void
		init(handler: @escaping (UInt64, UInt8?) -> Void) { self.handler = handler }
		deinit { buffer.deallocate() }
	}

	private init(manager: IOHIDManager, device: IOHIDDevice, isBluetooth: Bool, onInputReport: ((UInt64, UInt8?) -> Void)?) {
		self.manager = manager
		self.device = device
		self.isBluetooth = isBluetooth
		if let onInputReport {
			let reports = InputReports(handler: onInputReport)
			self.reports = reports
			let context = Unmanaged.passRetained(reports)
			IOHIDDeviceSetDispatchQueue(device, queue)
			IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, reports.buffer, 128, { ctx, _, _, _, reportID, report, length, timeStamp in
				guard let ctx else { return }
				Unmanaged<InputReports>.fromOpaque(ctx).takeUnretainedValue()
					.handler(timeStamp, DualSenseHID.systemButtons(reportID: reportID, report: report, length: length))
			}, context.toOpaque())
			IOHIDDeviceSetCancelHandler(device) { context.release() }
			IOHIDDeviceActivate(device)
		} else {
			reports = nil
		}
	}

	/// Bit 0 of `systemButtons`: PS. macOS keeps it from GameController (it opens the Games
	/// overlay), so the raw report is the only reliable way to see it.
	static let psBit: UInt8 = 0x01
	/// Bit 2 of `systemButtons`: the microphone mute button, which GameController doesn't expose.
	static let muteBit: UInt8 = 0x04

	/// The PS / touchpad / mute button byte from the raw input report.
	/// The buffer starts with the report ID. Byte offsets are from the DualSense report layout.
	static func systemButtons(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) -> UInt8? {
		let index: Int
		switch (reportID, length) {
		case (0x01, 64...): index = 10 // USB
		case (0x31, 12...): index = 11 // Bluetooth, full report
		case (0x01, 8...): index = 7   // Bluetooth, basic report
		default: return nil
		}
		return report[index]
	}

	deinit {
		if reports != nil { IOHIDDeviceCancel(device) }
		IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
		IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
	}

	/// Opens the first connected DualSense, or returns nil. `onInputReport` is called on the
	/// HID queue for every input report with the kernel's arrival time (mach absolute time).
	static func open(onInputReport: ((UInt64, UInt8?) -> Void)? = nil) -> DualSenseHID? {
		let log = Logger(subsystem: "Couchwire", category: "Feedback")
		let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
		let matches = productIDs.map { [kIOHIDVendorIDKey: sonyVendorID, kIOHIDProductIDKey: $0] as CFDictionary }
		IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
		let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
		guard openResult == kIOReturnSuccess else {
			log.error("IOHIDManagerOpen failed: \(openResult)")
			return nil
		}
		guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first else {
			IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
			return nil
		}
		let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
		guard result == kIOReturnSuccess else {
			log.error("IOHIDDeviceOpen failed: \(result)")
			IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
			return nil
		}
		let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
		let bt = transport.localizedCaseInsensitiveContains("bluetooth")
		log.info("DualSense HID opened over \(transport, privacy: .public)")
		return DualSenseHID(manager: manager, device: device, isBluetooth: bt, onInputReport: onInputReport)
	}

	/// Sets both adaptive triggers from raw effect blocks (type byte + 10 parameter bytes).
	func setTriggers(left: [UInt8], right: [UInt8]) {
		var effects = [UInt8](repeating: 0, count: 47)
		effects[0] = 0x04 | 0x08 // valid flags: right + left trigger effects
		for i in 0..<min(11, right.count) { effects[10 + i] = right[i] }
		for i in 0..<min(11, left.count) { effects[21 + i] = left[i] }
		send(effects: effects)
	}

	/// Rumble-emulation motor levels (0...255). Over Bluetooth this is how the console's
	/// haptics are felt: the voice coils are driven to imitate the two classic motors.
	/// Uses the "improved rumble" mode that firmware 2.24+ requires.
	func setRumble(left: UInt8, right: UInt8) {
		var effects = [UInt8](repeating: 0, count: 47)
		effects[0] = 0x02          // valid flag: audio haptics off, so rumble emulation takes over
		effects[2] = right         // high-frequency (right) motor
		effects[3] = left          // low-frequency (left) motor
		effects[38] = 0x04         // valid flag 3: improved rumble emulation
		send(effects: effects)
	}

	/// Lightbar colour and player-indicator LEDs.
	func setLights(r: UInt8, g: UInt8, b: UInt8, playerLEDs: UInt8) {
		var effects = [UInt8](repeating: 0, count: 47)
		effects[1] = 0x04 | 0x10   // valid flag 1: lightbar colour + player LEDs
		effects[43] = playerLEDs   // 5-bit mask, left to right
		effects[44] = r
		effects[45] = g
		effects[46] = b
		send(effects: effects)
	}

	private func send(effects: [UInt8]) {
		queue.async { [self] in
			var report: [UInt8]
			if isBluetooth {
				report = [UInt8](repeating: 0, count: 78)
				report[0] = 0x31 // Bluetooth output report
				report[1] = 0x00 // tag / sequence
				report[2] = 0x10 // magic
				for (i, b) in effects.enumerated() { report[3 + i] = b }
				// CRC32 over the HID-P header byte 0xA2 + report bytes 0..<74, little-endian.
				var crc = CRC32.update(0, [0xA2])
				crc = CRC32.update(crc, report[0..<74])
				withUnsafeBytes(of: crc.littleEndian) { for i in 0..<4 { report[74 + i] = $0[i] } }
			} else {
				report = [0x02] + effects // USB output report
			}
			let result = report.withUnsafeBufferPointer {
				IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(report[0]), $0.baseAddress!, $0.count)
			}
			if result != kIOReturnSuccess, !failed {
				failed = true
				log.error("DualSense output report failed (\(result)); reconnecting")
				onFailure?()
			}
		}
	}
}

enum CRC32 {
	private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
		var c = UInt32(i)
		for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
		return c
	}

	/// zlib-compatible CRC-32 (pass 0 to start).
	static func update<S: Sequence>(_ crc: UInt32, _ bytes: S) -> UInt32 where S.Element == UInt8 {
		var c = ~crc
		for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
		return ~c
	}
}
