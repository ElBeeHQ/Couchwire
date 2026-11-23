import Foundation
import QuartzCore
import os

/// Measures the live network round trip to the console with ICMP echo, four times a second.
///
/// libchiaki only measures the round trip once, before the stream starts. This keeps measuring
/// while playing, so Wi-Fi congestion or a busy link shows up as it happens. It uses an
/// unprivileged ICMP datagram socket, so it needs no root, and costs ~100 bytes per probe.
final class ConsolePinger: @unchecked Sendable {
	private let address: String
	private let interval: TimeInterval
	private let onResult: (_ rttMs: Double?) -> Void
	private var thread: Thread?
	private var stopped = false
	private let lock = NSLock()
	private let log = Logger(subsystem: "PSStream", category: "Ping")

	/// `onResult` is called on the ping thread: the round trip in ms, or nil for a lost probe.
	init(address: String, interval: TimeInterval = 0.25, onResult: @escaping (_ rttMs: Double?) -> Void) {
		self.address = address
		self.interval = interval
		self.onResult = onResult
	}

	func start() {
		let t = Thread { [weak self] in self?.run() }
		t.name = "PSStream.ping"
		t.qualityOfService = .utility
		thread = t
		t.start()
	}

	func stop() {
		lock.lock(); stopped = true; lock.unlock()
	}

	private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

	private func run() {
		var dest = sockaddr_in()
		dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		dest.sin_family = sa_family_t(AF_INET)
		guard inet_pton(AF_INET, address, &dest.sin_addr) == 1 else {
			log.error("Ping: \(self.address, privacy: .public) is not an IPv4 address")
			return
		}
		let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
		guard fd >= 0 else {
			log.error("Ping: socket failed (\(errno))")
			return
		}
		defer { close(fd) }
		var timeout = timeval(tv_sec: 0, tv_usec: Int32(interval * 1_000_000))
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

		let ident = UInt16.random(in: 1...UInt16.max)
		var seq: UInt16 = 0
		var buffer = [UInt8](repeating: 0, count: 256)
		while !isStopped {
			seq &+= 1
			let packet = Self.echoRequest(ident: ident, seq: seq)
			let sentAt = CACurrentMediaTime()
			let sent = packet.withUnsafeBytes { raw in
				withUnsafePointer(to: &dest) {
					$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
						sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
					}
				}
			}
			var rtt: Double?
			if sent == packet.count {
				let deadline = sentAt + interval
				// Read until our reply arrives or the interval runs out; skip stale or foreign replies.
				while rtt == nil, CACurrentMediaTime() < deadline {
					let n = recv(fd, &buffer, buffer.count, 0)
					guard n > 0 else { break }
					if Self.isReply(buffer[0..<n], seq: seq) {
						rtt = (CACurrentMediaTime() - sentAt) * 1000
					}
				}
			}
			onResult(rtt)
			let remaining = sentAt + interval - CACurrentMediaTime()
			if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
		}
	}

	private static func echoRequest(ident: UInt16, seq: UInt16) -> [UInt8] {
		var p: [UInt8] = [8, 0, 0, 0, UInt8(ident >> 8), UInt8(ident & 0xFF), UInt8(seq >> 8), UInt8(seq & 0xFF)]
		p += [UInt8](repeating: 0x50, count: 24) // payload
		let sum = checksum(p)
		p[2] = UInt8(sum >> 8)
		p[3] = UInt8(sum & 0xFF)
		return p
	}

	/// macOS delivers ICMP datagram replies with the IP header still attached.
	private static func isReply(_ data: ArraySlice<UInt8>, seq: UInt16) -> Bool {
		var icmp = data
		if let first = icmp.first, first >> 4 == 4 {
			icmp = icmp.dropFirst(Int(first & 0x0F) * 4)
		}
		guard icmp.count >= 8 else { return false }
		let b = Array(icmp.prefix(8))
		// The kernel may rewrite the identifier for datagram sockets, so match type and sequence.
		return b[0] == 0 && b[6] == UInt8(seq >> 8) && b[7] == UInt8(seq & 0xFF)
	}

	private static func checksum(_ bytes: [UInt8]) -> UInt16 {
		var sum: UInt32 = 0
		var i = 0
		while i + 1 < bytes.count {
			sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
			i += 2
		}
		if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
		while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
		return ~UInt16(sum)
	}
}
