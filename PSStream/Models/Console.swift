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

	init(_ info: PSSHostInfo) {
		var info = info
		hostID = cString(&info.host_id).uppercased()
		name = cString(&info.name)
		address = cString(&info.address)
		isPS5 = info.is_ps5
		state = switch info.state {
		case PSS_HOST_STATE_READY: .ready
		case PSS_HOST_STATE_STANDBY: .standby
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
}

struct ConsoleKeys: Codable, Sendable {
	let registKey: Data // 16 bytes
	let rpKey: Data     // 16 bytes ("morning")
}

struct StreamSettings: Codable, Hashable, Sendable {
	enum Resolution: String, Codable, CaseIterable, Identifiable {
		case p720 = "720p", p1080 = "1080p"
		var id: String { rawValue }
		var size: (width: UInt32, height: UInt32) {
			switch self {
			case .p720: (1280, 720)
			case .p1080: (1920, 1080)
			}
		}
	}

	enum Codec: String, Codable, CaseIterable, Identifiable {
		case h264 = "H.264", hevc = "HEVC"
		var id: String { rawValue }
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
	init?(hexString: String) {
		let chars = Array(hexString.utf8)
		guard chars.count % 2 == 0 else { return nil }
		var bytes: [UInt8] = []
		bytes.reserveCapacity(chars.count / 2)
		for i in stride(from: 0, to: chars.count, by: 2) {
			guard let b = UInt8(String(decoding: chars[i...i + 1], as: UTF8.self), radix: 16) else { return nil }
			bytes.append(b)
		}
		self.init(bytes)
	}

	var hexString: String { map { String(format: "%02X", $0) }.joined() }
}
