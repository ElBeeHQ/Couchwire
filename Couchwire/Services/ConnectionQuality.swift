import Foundation
import Network
import QuartzCore

/// Automatic quality: picks the stream settings each session starts with from the kind of
/// connection and how earlier sessions on it went, never above the settings the user chose.
///
/// The PS5 fixes resolution, frame rate and bitrate when a session starts, so quality can only
/// change between sessions. Each session's result moves that connection one step down the ladder
/// (it struggled) or one step up (it ran smoothly for a while). A session that was clearly excellent
/// (a short, steady round trip and nothing lost) goes straight back to 30 Mbps at 1080p.
enum ConnectionQuality {
	/// The kind of link a session runs over. Each remembers its own step.
	enum Link: String {
		case homeWired, homeWireless, internet, internetMobile

		var name: String {
			switch self {
			case .homeWired: "Home network, wired"
			case .homeWireless: "Home network, Wi-Fi"
			case .internet: "Internet"
			case .internetMobile: "Internet, mobile hotspot"
			}
		}

		/// Where a connection starts before Couchwire has learned anything about it.
		fileprivate var defaultStep: Int {
			switch self {
			case .homeWired: 1
			case .homeWireless: 2
			case .internet: 4
			case .internetMobile: 5
			}
		}

		/// The best step this link can reach. 50 Mbps is for home networks only: over the internet the
		/// home connection's upload speed is the limit.
		fileprivate var topStep: Int {
			switch self {
			case .homeWired, .homeWireless: 0
			case .internet, .internetMobile: 1
			}
		}

		fileprivate var isHome: Bool { self == .homeWired || self == .homeWireless }
	}

	struct Step: Equatable {
		let resolution: StreamSettings.Resolution
		let fps: Int
		/// Kbps.
		let bitrate: Int
	}

	/// Best first. Bitrate drops before resolution, and frame rate goes last.
	static let ladder: [Step] = [
		Step(resolution: .p1080, fps: 60, bitrate: 50_000),
		Step(resolution: .p1080, fps: 60, bitrate: 30_000),
		Step(resolution: .p1080, fps: 60, bitrate: 20_000),
		Step(resolution: .p1080, fps: 60, bitrate: 15_000),
		Step(resolution: .p720, fps: 60, bitrate: 10_000),
		Step(resolution: .p720, fps: 60, bitrate: 6_000),
		Step(resolution: .p720, fps: 30, bitrate: 3_000),
	]

	static var isOn: Bool {
		UserDefaults.standard.object(forKey: "autoQuality") as? Bool ?? true
	}

	/// The link this Mac is on right now. Home sessions are wired or Wi-Fi; internet sessions on a
	/// metered or Low Data Mode connection (a phone hotspot, tethering) count as mobile.
	static func currentLink(internet: Bool) -> Link {
		let path = PathWatcher.shared.path
		if internet {
			// macOS marks hotspots as expensive or, more often, Low Data Mode ("constrained"). iPhone
			// hotspots also always hand out 172.20.10.x.
			let mobile = path.map { $0.isExpensive || $0.isConstrained || $0.usesInterfaceType(.cellular) } ?? false
				|| LocalNetwork.contains("172.20.10.1")
			return mobile ? .internetMobile : .internet
		}
		let wired = path?.usesInterfaceType(.wiredEthernet) ?? false
		return wired ? .homeWired : .homeWireless
	}

	/// The step to start this link at.
	static func step(for link: Link) -> Int {
		let defaults = UserDefaults.standard
		var stored = defaults.object(forKey: key(link)) as? Int
		// Before 50 Mbps joined the top of the ladder, steps were saved one lower.
		if stored == nil, let old = defaults.object(forKey: legacyKey(link)) as? Int {
			stored = old + 1
		}
		return min(max(stored ?? link.defaultStep, link.topStep), ladder.count - 1)
	}

	/// The settings to stream with: the link's step, capped by the user's own settings (their
	/// codec always applies).
	static func settings(for link: Link, ceiling: StreamSettings) -> StreamSettings {
		apply(ladder[step(for: link)], ceiling: ceiling)
	}

	static func apply(_ step: Step, ceiling: StreamSettings) -> StreamSettings {
		var s = ceiling
		if step.resolution == .p720 { s.resolution = .p720 }
		s.fps = min(step.fps, ceiling.fps)
		s.bitrate = min(step.bitrate, ceiling.bitrate)
		return s
	}

	static func setStep(_ step: Int, for link: Link) {
		guard !UserDefaults.standard.bool(forKey: "CouchwireDemo") else { return }
		UserDefaults.standard.set(min(max(step, link.topStep), ladder.count - 1), forKey: key(link))
	}

	/// The step for 1080p at 60 fps and 30 Mbps, where an excellent session jumps to.
	private static let fullHD = 1

	enum Outcome {
		case struggled, smooth
		/// Smooth, and the network was clearly good: a short, steady round trip with nothing lost.
		case excellent
	}

	/// Learn from a finished session.
	static func record(_ outcome: Outcome, link: Link) {
		let s = step(for: link)
		// Only a home network's round trip is measured live, so only home sessions can be excellent.
		let outcome = outcome == .excellent && !link.isHome ? .smooth : outcome
		let next = switch outcome {
		case .struggled: s + 1
		case .smooth: s - 1
		// Straight back to 1080p at 30 Mbps. 50 Mbps still takes one more good session at 30.
		case .excellent: s > fullHD ? fullHD : s - 1
		}
		let clamped = min(max(next, link.topStep), ladder.count - 1)
		if clamped != s { setStep(clamped, for: link) }
	}

	/// Forget what's been learned, so every link starts from its default again.
	static func reset() {
		for link in [Link.homeWired, .homeWireless, .internet, .internetMobile] {
			UserDefaults.standard.removeObject(forKey: key(link))
			UserDefaults.standard.removeObject(forKey: legacyKey(link))
		}
	}

	private static func key(_ link: Link) -> String { "qualityStep.\(link.rawValue)" }
	private static func legacyKey(_ link: Link) -> String { "quality.\(link.rawValue)" }
}

/// Keeps the Mac's current network path, for telling wired from Wi-Fi and spotting hotspots.
final class PathWatcher: @unchecked Sendable {
	static let shared = PathWatcher()
	private let monitor = NWPathMonitor()
	private let lock = NSLock()
	private var _path: NWPath?
	private var signature = ""
	private var changedAt: CFTimeInterval = 0

	var path: NWPath? {
		lock.lock(); defer { lock.unlock() }
		return _path
	}

	/// Seconds since the Mac last moved to a different network (or lost or regained one).
	var secondsSinceChange: Double {
		lock.lock(); defer { lock.unlock() }
		return changedAt > 0 ? CACurrentMediaTime() - changedAt : .infinity
	}

	private init() {
		monitor.pathUpdateHandler = { [weak self] p in
			guard let self else { return }
			// Moving between Wi-Fi networks keeps the same interface (en0), so compare the
			// gateways too: they change with the network.
			let sig = "\(p.status) \(p.availableInterfaces.map(\.name)) \(p.gateways.map(\.debugDescription))"
			lock.lock()
			if _path != nil, sig != signature { changedAt = CACurrentMediaTime() }
			_path = p
			signature = sig
			lock.unlock()
		}
		monitor.start(queue: DispatchQueue(label: "Couchwire.path"))
	}

	/// Start watching early, so the first session already knows the path.
	static func start() { _ = shared }

	/// Whether traffic is going through a VPN: the path's main interface is a tunnel (utun,
	/// ipsec, ppp) rather than Wi-Fi or Ethernet.
	var usesVPN: Bool {
		guard let p = path, let first = p.availableInterfaces.first else { return false }
		return first.type == .other && ["utun", "ipsec", "ppp", "tun", "tap", "wg"].contains { first.name.hasPrefix($0) }
	}
}

/// Watches a running stream and decides whether it's struggling. Fed the twice-a-second stats.
struct StruggleDetector {
	/// Seconds of stats kept.
	private static let window = 20 // half-second samples: 10 s
	/// Ignore the first few seconds: the stream settles and the first keyframe is big.
	private static let grace = 12 // samples: 6 s

	private var samples: [Bool] = []
	private var count = 0
	private var badTotal = 0
	private var lastFramesLost = 0
	/// Half-seconds with a live round trip under 10 ms and jitter under 3 ms, and whether any frame was lost.
	private var steadyCount = 0
	private var anyLost = false

	/// True once the last 10 s were mostly bad.
	private(set) var struggling = false
	/// What went wrong most often, once struggling.
	private(set) var reason: Reason = .late
	private var lossCount = 0, lateCount = 0

	enum Reason { case loss, late }

	/// Whether one half-second of stats looks bad: real packet loss, frames lost on the way, or
	/// many frames arriving well behind the beat.
	mutating func add(_ s: StreamStats.Snapshot) {
		count += 1
		let lost = s.framesLost - lastFramesLost
		lastFramesLost = s.framesLost
		guard count > Self.grace else { return }
		if lost > 0 { anyLost = true }
		if let ping = s.pingMs, ping < 10, s.pingJitterMs < 3 { steadyCount += 1 }
		let lossy = s.packetLoss > 0.02 || lost > 1
		let late = s.lateFrameRatio > 0.1
		let bad = lossy || late
		if bad { badTotal += 1 }
		if lossy { lossCount += 1 }
		if late { lateCount += 1 }
		samples.append(bad)
		if samples.count > Self.window { samples.removeFirst() }
		if samples.count == Self.window, samples.filter({ $0 }).count >= Self.window * 6 / 10 {
			struggling = true
			reason = lossCount >= lateCount ? .loss : .late
		}
	}

	/// How the session went, once it has run long enough to tell.
	var outcome: ConnectionQuality.Outcome? {
		if struggling { return .struggled }
		let measured = count - Self.grace
		// Smooth: at least 90 s with under 3% bad samples.
		guard measured >= 180, Double(badTotal) / Double(measured) < 0.03 else { return nil }
		// Excellent: nothing bad or lost, and the round trip short and steady 95% of the time.
		if badTotal == 0, !anyLost, Double(steadyCount) / Double(measured) >= 0.95 { return .excellent }
		return .smooth
	}
}
