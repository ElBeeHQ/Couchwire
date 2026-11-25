import Foundation

/// A console seen on the local network via discovery.
struct DiscoveredConsole: Identifiable, Hashable, Sendable {
	enum State: Sendable { case unknown, ready, standby }

	var id: String { hostID }
	let hostID: String          // MAC address as uppercase hex
	let name: String
	let address: String
	let isPS5: Bool
	let state: State
	let systemVersion: String
	let runningApp: String?

	init(hostID: String, name: String, address: String, state: State) {
		self.hostID = hostID
		self.name = name
		self.address = address
		isPS5 = true
		self.state = state
		systemVersion = ""
		runningApp = nil
	}

	init(_ info: CWHostInfo) {
		var info = info
		hostID = cString(&info.host_id).uppercased()
		name = cString(&info.name)
		address = cString(&info.address)
		isPS5 = info.is_ps5
		state = switch info.state {
		case CW_HOST_STATE_READY: .ready
		case CW_HOST_STATE_STANDBY: .standby
		default: .unknown
		}
		systemVersion = cString(&info.system_version)
		let app = cString(&info.running_app_name)
		runningApp = app.isEmpty ? nil : app
	}
}

/// A console this Mac has been paired with. Keys are stored in the Keychain.
struct RegisteredConsole: Codable, Identifiable, Hashable, Sendable {
	var id: String { hostID }
	let hostID: String
	var nickname: String
	var lastAddress: String
	let isPS5: Bool
	/// PSN account id (base64) used when pairing; also sent on every session.
	let accountID: String
	/// Internet play: the console's PSN device id (64 hex characters), matched by name from the
	/// consoles on the signed-in PSN account.
	var psnDeviceID: String? = nil
}

/// Per-console preferences. Stream settings fall back to the app-wide defaults unless
/// `customStream` is set.
struct ConsoleProfile: Codable, Hashable, Sendable {
	var customStream: StreamSettings?
	var autoWake = true
	var autoFullScreen = false
	/// Where to reach the console directly when away from home: the home's public address or a
	/// dynamic DNS name, with the PS5's ports forwarded on the router. Empty to use PSN instead.
	var awayAddress = ""

	init() {}

	// Decode field by field so profiles saved by older versions keep loading as fields are added.
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		customStream = try c.decodeIfPresent(StreamSettings.self, forKey: .customStream)
		autoWake = try c.decodeIfPresent(Bool.self, forKey: .autoWake) ?? true
		autoFullScreen = try c.decodeIfPresent(Bool.self, forKey: .autoFullScreen) ?? false
		awayAddress = try c.decodeIfPresent(String.self, forKey: .awayAddress) ?? ""
	}
}

struct ConsoleKeys: Codable, Sendable {
	let registKey: Data // 16 bytes
	let rpKey: Data     // 16 bytes ("morning")
}

struct StreamSettings: Codable, Hashable, Sendable {
	enum Resolution: String, Codable, CaseIterable, Identifiable {
		// The PS5's Remote Play encoder refuses anything above 1080p ("AvCap failed to
		// initialize video"), so 1440p and 4K aren't offered.
		case p720 = "720p", p1080 = "1080p"
		var id: String { rawValue }
		var size: (width: UInt32, height: UInt32) {
			switch self {
			case .p720: (1280, 720)
			case .p1080: (1920, 1080)
			}
		}

		/// Settings saved with a resolution that's since been removed load as 1080p.
		init(from decoder: Decoder) throws {
			self = Resolution(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .p1080
		}
	}

	enum Codec: String, Codable, CaseIterable, Identifiable {
		case h264 = "H.264", hevc = "HEVC", hevcHDR = "HEVC HDR"
		var id: String { rawValue }
		var isHEVC: Bool { self != .h264 }
	}

	var resolution: Resolution = .p1080
	var fps: Int = 60
	var codec: Codec = .hevc
	/// Kbps. PS5 accepts up to ~50 Mbps at 1080p over LAN.
	var bitrate: Int = 30_000
}

func cString<T>(_ tuple: inout T) -> String {
	withUnsafePointer(to: &tuple) {
		$0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
	}
}

extension Data {
	/// Bytes from a hex string (either case), or nil if it isn't one: an odd length or any
	/// character that isn't 0–9, a–f or A–F.
	init?(hexString: String) {
		let chars = Array(hexString.utf8)
		guard chars.count % 2 == 0 else { return nil }
		func nibble(_ c: UInt8) -> UInt8? {
			switch c {
			case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
			case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
			case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
			default: nil
			}
		}
		var bytes: [UInt8] = []
		bytes.reserveCapacity(chars.count / 2)
		for i in stride(from: 0, to: chars.count, by: 2) {
			guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
			bytes.append(hi << 4 | lo)
		}
		self.init(bytes)
	}

	var hexString: String { map { String(format: "%02X", $0) }.joined() }
}
