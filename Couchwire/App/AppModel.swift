import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
	private(set) var discovered: [DiscoveredConsole] = []
	private(set) var registered: [RegisteredConsole] = ConsoleStore.loadConsoles()
	var settings: StreamSettings = ConsoleStore.loadSettings() {
		didSet { ConsoleStore.saveSettings(settings) }
	}
	/// Keyed by host ID.
	var profiles: [String: ConsoleProfile] = ConsoleStore.loadProfiles() {
		didSet { ConsoleStore.saveProfiles(profiles) }
	}
	var accountID: String = ConsoleStore.accountID {
		didSet { ConsoleStore.accountID = accountID }
	}
	/// Internet play: stay signed in to PSN so consoles can be reached away from home. Off by default;
	/// turning it off deletes the stored sign-in.
	var internetPlay: Bool = UserDefaults.standard.bool(forKey: "internetPlay") {
		didSet {
			if !Self.isDemo { UserDefaults.standard.set(internetPlay, forKey: "internetPlay") }
			if !internetPlay { signOutOfPSN() }
		}
	}
	/// Internet play: guess ports even on friendly-looking networks (double NAT, some hotspots).
	var forcePortGuessing: Bool = UserDefaults.standard.bool(forKey: "psnForcePortGuessing") {
		didSet { if !Self.isDemo { UserDefaults.standard.set(forcePortGuessing, forKey: "psnForcePortGuessing") } }
	}
	/// Automatic quality: start each stream at what the connection can handle, up to `settings`.
	var autoQuality: Bool = ConnectionQuality.isOn {
		didSet { if !Self.isDemo { UserDefaults.standard.set(autoQuality, forKey: "autoQuality") } }
	}
	/// Hold frames back slightly so they play out evenly on an uneven network.
	var smoothing: SmoothingMode = AppModel.savedSmoothing {
		didSet {
			if !Self.isDemo { UserDefaults.standard.set(smoothing.rawValue, forKey: "smoothingMode") }
			// Applies to the stream that's playing, so you can compare.
			session?.smoothing = smoothing
		}
	}
	private static var savedSmoothing: SmoothingMode {
		if let raw = UserDefaults.standard.string(forKey: "smoothingMode"), let mode = SmoothingMode(rawValue: raw) { return mode }
		// Earlier builds had an on/off switch.
		return UserDefaults.standard.object(forKey: "smoothing") as? Bool == false ? .off : .automatic
	}
	/// Whether a PSN sign-in is stored for internet play.
	private(set) var psnSignedIn = false
	private(set) var session: StreamSession?
	/// Bumped by the Show Stream Controls command; the stream window reveals its controls.
	var controlsRequest = 0
	/// Shows the first-run setup over the console list.
	var showingOnboarding = false
	private(set) var waking: Set<String> = []
	var lastError: String?

	@ObservationIgnored private var discovery: DiscoveryService?

	/// Demo mode for screenshots: made-up consoles, no network, and nothing saved. Launch with
	/// `-CouchwireDemo YES`; your real consoles and settings are untouched.
	static let isDemo = UserDefaults.standard.bool(forKey: "CouchwireDemo")
	/// Demo mode only: `-CouchwireAppearance light` or `dark` for screenshots in either look.
	static let demoColorScheme: ColorScheme? = switch isDemo ? UserDefaults.standard.string(forKey: "CouchwireAppearance") : nil {
	case "light": .light
	case "dark": .dark
	default: nil
	}

	init() {
		_ = cw_init()
		PathWatcher.start()
		Task { await checkPSNSignIn(); await refreshPSNDevices() }
		if Self.isDemo {
			registered = [
				RegisteredConsole(hostID: "DEMO01", nickname: "Living Room PS5", lastAddress: "192.168.1.20", isPS5: true, accountID: ""),
				RegisteredConsole(hostID: "DEMO02", nickname: "Bedroom PS5", lastAddress: "192.168.1.21", isPS5: true, accountID: ""),
			]
			discovered = [
				DiscoveredConsole(hostID: "DEMO01", name: "Living Room PS5", address: "192.168.1.20", state: .ready),
				DiscoveredConsole(hostID: "DEMO02", name: "Bedroom PS5", address: "192.168.1.21", state: .standby),
				DiscoveredConsole(hostID: "DEMO03", name: "Study PS5", address: "192.168.1.22", state: .ready),
			]
		}
	}

	// MARK: PSN sign-in

	/// After a sign-in: keep the Account ID, and the tokens only if Internet Play is on.
	func signedIn(_ result: PSNAuth.SignIn) {
		accountID = result.accountID
		guard internetPlay else { return }
		psnSignedIn = true
		Task {
			await PSNTokens.shared.save(result.credentials)
			await refreshPSNDevices()
		}
	}

	func signOutOfPSN() {
		psnSignedIn = false
		Task { await PSNTokens.shared.delete() }
	}

	/// Refreshes `psnSignedIn` from the Keychain.
	func checkPSNSignIn() async {
		psnSignedIn = internetPlay ? await PSNTokens.shared.isSignedIn : false
	}

	/// A current PSN access token for internet play, or nil (with `psnSignedIn` cleared) when the
	/// sign-in has expired.
	func psnAccessToken() async throws -> String {
		do {
			return try await PSNTokens.shared.accessToken()
		} catch PSNAuth.Failure.signInExpired {
			psnSignedIn = false
			throw PSNAuth.Failure.signInExpired
		}
	}

	/// Matches the consoles on the PSN account to the paired ones by name, for internet play.
	func refreshPSNDevices() async {
		guard internetPlay, psnSignedIn, !Self.isDemo, let token = try? await psnAccessToken() else { return }
		let devices: [(name: String, id: String)] = await Task.detached {
			var list: UnsafeMutablePointer<CWPSNDevice>?
			var count = 0
			guard cw_psn_list_devices(token, &list, &count, cLog, nil) == 0, let list else { return [] }
			defer { cw_psn_free_devices(list) }
			return (0..<count).compactMap { i -> (String, String)? in
				var d = list[i]
				guard d.remote_play_enabled else { return nil }
				let name = withUnsafeBytes(of: &d.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
				let id = withUnsafeBytes(of: &d.duid) { $0.map { String(format: "%02x", $0) }.joined() }
				return (name, id)
			}
		}.value
		var changed = false
		for (i, console) in registered.enumerated() {
			let match = devices.first { $0.name.caseInsensitiveCompare(console.nickname) == .orderedSame }?.id
			if let match, match != console.psnDeviceID {
				registered[i].psnDeviceID = match
				changed = true
			}
		}
		if changed { ConsoleStore.saveConsoles(registered) }
	}

	/// Whether Play would go over the internet: the console isn't on this network, and it's
	/// reachable through PSN.
	func playsOverInternet(_ console: RegisteredConsole) -> Bool {
		internetPlay && psnSignedIn && console.psnDeviceID != nil && discoveredState(of: console) == nil
	}

	func startDiscovery() {
		guard !Self.isDemo else { return }
		if discovery == nil {
			discovery = DiscoveryService { [weak self] list in self?.updateDiscovered(list) }
		}
		discovery?.start()
	}

	func stopDiscovery() {
		discovery?.stop()
	}

	private func updateDiscovered(_ list: [DiscoveredConsole]) {
		discovered = list.sorted { $0.name < $1.name }
		// Follow DHCP changes: keep each paired console's address current.
		var changed = false
		for host in list {
			if let i = registered.firstIndex(where: { $0.hostID == host.hostID }),
			   registered[i].lastAddress != host.address || registered[i].nickname != host.name {
				registered[i].lastAddress = host.address
				if !host.name.isEmpty { registered[i].nickname = host.name }
				changed = true
			}
		}
		if changed { ConsoleStore.saveConsoles(registered) }
	}

	func discoveredState(of console: RegisteredConsole) -> DiscoveredConsole? {
		discovered.first { $0.hostID == console.hostID }
	}

	/// Discovered consoles that aren't paired yet.
	var unpaired: [DiscoveredConsole] {
		discovered.filter { d in !registered.contains { $0.hostID == d.hostID } }
	}

	// MARK: Pairing

	func pair(address: String, isPS5: Bool, pin: String) async throws {
		let service = RegistrationService()
		let result = try await service.register(address: address, accountID: accountID, pin: pin, ps5: isPS5)
		ConsoleStore.saveKeys(result.keys, for: result.hostID)
		let name = discovered.first { $0.hostID == result.hostID }?.name ?? result.nickname
		let console = RegisteredConsole(hostID: result.hostID, nickname: name, lastAddress: address,
										isPS5: result.isPS5, accountID: accountID)
		registered.removeAll { $0.hostID == console.hostID }
		registered.append(console)
		ConsoleStore.saveConsoles(registered)
	}

	func profile(for hostID: String) -> ConsoleProfile {
		profiles[hostID] ?? ConsoleProfile()
	}

	func forget(_ console: RegisteredConsole) {
		ConsoleStore.deleteKeys(for: console.hostID)
		profiles[console.hostID] = nil
		registered.removeAll { $0.hostID == console.hostID }
		ConsoleStore.saveConsoles(registered)
	}

	// MARK: Streaming

	/// Wakes the console if needed, then starts a session. Returns the session to show.
	func connect(_ console: RegisteredConsole) async -> StreamSession? {
		guard session == nil else { return session }
		guard let keys = ConsoleStore.loadKeys(for: console.hostID) else {
			lastError = "The pairing keys for \(console.nickname) are missing. Forget the console and pair it again."
			return nil
		}

		let profile = profile(for: console.hostID)
		if internetPlay, psnSignedIn, discoveredState(of: console) == nil {
			return await connectOverInternet(console, keys: keys, ceiling: profile.customStream ?? settings)
		}
		if discoveredState(of: console)?.state == .standby {
			guard profile.autoWake else {
				lastError = "\(console.nickname) is in rest mode. Turn on “Wake from Rest Mode” in its settings, or switch it on with the controller."
				return nil
			}
			waking.insert(console.hostID)
			defer { waking.remove(console.hostID) }
			await wakeAndWait(console, keys: keys)
			guard discoveredState(of: console)?.state == .ready else {
				lastError = "\(console.nickname) didn’t wake up. Make sure “Enable Turning On PS5 from Network” is on in Settings › System › Power Saving."
				return nil
			}
			// A PS5 reports "ready" a few seconds before Remote Play will accept a session.
			try? await Task.sleep(for: .seconds(3))
		}

		let s = makeSession(console, keys: keys, ceiling: profile.customStream ?? settings, retries: 3)
		session = s
		s.start()
		return s
	}

	/// Internet play: PSN wakes the console and sets up the connection; the session window shows
	/// the steps. A fresh access token is fetched first, as the session keeps the one it starts with.
	private func connectOverInternet(_ console: RegisteredConsole, keys: ConsoleKeys, ceiling: StreamSettings) async -> StreamSession? {
		let token: String
		do {
			token = try await psnAccessToken()
		} catch {
			lastError = error.localizedDescription
			return nil
		}
		if registered.first(where: { $0.hostID == console.hostID })?.psnDeviceID == nil {
			await refreshPSNDevices()
		}
		let current = registered.first { $0.hostID == console.hostID } ?? console
		guard let hex = current.psnDeviceID, let deviceID = Data(hex: hex), deviceID.count == 32 else {
			lastError = "Couldn’t find \(console.nickname) on your PlayStation Network account. Check it’s signed in to the same account, with Remote Play on, and that its name hasn’t changed since you paired it."
			return nil
		}
		let link = ConnectionQuality.currentLink(internet: true)
		let s = StreamSession(console: current, keys: keys, settings: streamSettings(link, ceiling: ceiling), link: link,
							  automaticQuality: autoQuality, smoothing: smoothing,
							  internet: .init(accessToken: token, deviceID: deviceID, forcePortGuessing: forcePortGuessing))
		session = s
		s.start()
		return s
	}

	/// A session that, if the console turns out not to be ready yet, quietly tries again a few seconds later
	/// (the stream window keeps showing "Connecting…").
	private func makeSession(_ console: RegisteredConsole, keys: ConsoleKeys, ceiling: StreamSettings, retries: Int) -> StreamSession {
		let current = registered.first { $0.hostID == console.hostID } ?? console
		let link = ConnectionQuality.currentLink(internet: false)
		let s = StreamSession(console: current, keys: keys, settings: streamSettings(link, ceiling: ceiling), link: link,
							  automaticQuality: autoQuality, smoothing: smoothing)
		s.retryWhenNotReady = { [weak self] failed in
			guard let self, retries > 0, self.session === failed else { return false }
			Task { @MainActor in
				try? await Task.sleep(for: .seconds(3))
				// Ended or replaced in the meantime (the user closed the window).
				guard self.session === failed else { return }
				let next = self.makeSession(console, keys: keys, ceiling: ceiling, retries: retries - 1)
				self.session = next
				next.start()
			}
			return true
		}
		return s
	}

	/// Wakes a console from rest mode without connecting.
	func wake(_ console: RegisteredConsole) {
		guard let keys = ConsoleStore.loadKeys(for: console.hostID) else {
			lastError = "The pairing keys for \(console.nickname) are missing. Forget the console and pair it again."
			return
		}
		waking.insert(console.hostID)
		Task {
			await wakeAndWait(console, keys: keys)
			waking.remove(console.hostID)
		}
	}

	/// Sends the wake signal and waits up to 45 s for the console to report ready. The signal is one UDP
	/// packet that can be lost, and a PS5 that has only just gone into rest mode ignores it while it settles,
	/// so it's sent again every 5 s for as long as the console still reports rest mode.
	private func wakeAndWait(_ console: RegisteredConsole, keys: ConsoleKeys) async {
		for tick in 0..<90 {
			if tick % 10 == 0, discoveredState(of: console)?.state != .ready,
			   tick == 0 || discoveredState(of: console)?.state == .standby {
				let address = registered.first { $0.hostID == console.hostID }?.lastAddress ?? console.lastAddress
				_ = DiscoveryService.wake(address: address, keys: keys, ps5: console.isPS5)
			}
			try? await Task.sleep(for: .milliseconds(500))
			if discoveredState(of: console)?.state == .ready { return }
		}
	}

	/// The settings to stream with over `link`: the user's own, or automatic quality's pick under them.
	private func streamSettings(_ link: ConnectionQuality.Link, ceiling: StreamSettings) -> StreamSettings {
		autoQuality ? ConnectionQuality.settings(for: link, ceiling: ceiling) : ceiling
	}

	/// Whether there's a lower quality to drop to from this session.
	func canLowerQuality(_ s: StreamSession) -> Bool {
		s.settings != ConnectionQuality.apply(ConnectionQuality.ladder.last!, ceiling: s.settings)
	}

	/// The stream is struggling: remember a lower quality for this connection and reconnect with it.
	/// Turns automatic quality on, since that's what picks the lower settings.
	func reconnectAtLowerQuality() async -> StreamSession? {
		guard let s = session else { return nil }
		let console = s.console
		// Step down from wherever this session actually was.
		let current = ConnectionQuality.ladder.lastIndex { ConnectionQuality.apply($0, ceiling: s.settings) == s.settings } ?? 0
		let stored = ConnectionQuality.step(for: s.link)
		if !autoQuality || stored <= current {
			ConnectionQuality.setStep(current + 1, for: s.link)
		}
		autoQuality = true
		s.skipLearning()
		endSession()
		// Let the console notice the old session has gone before asking for a new one.
		try? await Task.sleep(for: .seconds(2))
		return await connect(console)
	}

	func endSession() {
		session?.stop()
		session = nil
	}
}

private extension Data {
	/// Bytes from a hex string, or nil if it isn't one.
	init?(hex: String) {
		guard hex.count % 2 == 0 else { return nil }
		var bytes = [UInt8]()
		var index = hex.startIndex
		while index < hex.endIndex {
			let next = hex.index(index, offsetBy: 2)
			guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
			bytes.append(byte)
			index = next
		}
		self.init(bytes)
	}
}
