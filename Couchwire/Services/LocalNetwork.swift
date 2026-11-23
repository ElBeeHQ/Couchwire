import Darwin
import Foundation

/// The Mac's own IPv4 networks, for telling whether an address is on one of them.
enum LocalNetwork {
	/// Whether `address` is on a network one of the Mac's interfaces (Wi-Fi, Ethernet) is on now.
	static func contains(_ address: String) -> Bool {
		var target = in_addr()
		guard inet_pton(AF_INET, address, &target) == 1 else { return false }
		var list: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&list) == 0, let first = list else { return false }
		defer { freeifaddrs(list) }
		for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
			let flags = Int32(entry.pointee.ifa_flags)
			guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
				  flags & IFF_POINTOPOINT == 0, // VPN tunnels
				  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
				  let mask = entry.pointee.ifa_netmask else { continue }
			let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
			let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
			if ip & m == target.s_addr & m { return true }
		}
		return false
	}
}
