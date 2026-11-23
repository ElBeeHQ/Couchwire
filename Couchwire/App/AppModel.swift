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
	/// Set while reconnecting after the stream was lost (the Mac changed network). The stream
	/// window shows it in place of the frozen picture.
	private(set) var reconnecting: RegisteredConsole?
	/// Which try this is while reconnecting (1 for the first), for the stream window.
	private(set) var reconnectAttempt = 0
	/// Why reconnecting gave up, shown in the stream window.
	private(set) var reconnectError: String?
	@ObservationIgnored private var reconnectTask: Task<Void, Never>?
	/// Shown to the user, and written to the Timing log so a failed connect can be looked into later.
	var lastError: String? {
		didSet {
			if let lastError { StreamSession.timing.notice("Error shown: \(lastError, privacy: .public)") }
		}
	}

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
		let seen = discoveredState(of: console).map { "\($0.state) at \($0.address)" } ?? "not seen on this network"
		StreamSession.timing.notice("Connect to \(console.nickname, privacy: .public): \(seen, privacy: .public)")
		// Over the internet when the console can't be seen here. A console still listed from the network
		// the Mac has just left doesn't count: its address isn't on this one.
		let current = registered.first { $0.hostID == console.hostID } ?? console
		let away = discoveredState(of: console) == nil || !LocalNetwork.contains(current.lastAddress)
		let awayAddress = profile.awayAddress.trimmingCharacters(in: .whitespaces)
		if away, !awayAddress.isEmpty {
			return connectDirect(console, keys: keys, address: awayAddress, profile: profile)
		}
		if internetPlay, psnSignedIn, away {
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
							  internet: .init(accessToken: token, deviceID: deviceID, forcePortGuessing: forcePortGuessing,
											  skipRouterSearch: link == .internetMobile))
		s.onConnectionLost = { [weak self] in self?.streamLost($0) }
		session = s
		s.start()
		return s
	}

	/// Away from home, straight to the address the user gave (port forwarding on their router), without PSN.
	/// Works on networks where PSN can't open a direct connection, such as mobile data. A console in rest
	/// mode is woken first; it can't be watched from here, so the session simply keeps trying while it starts.
	private func connectDirect(_ console: RegisteredConsole, keys: ConsoleKeys, address: String, profile: ConsoleProfile) -> StreamSession {
		StreamSession.timing.notice("Connecting straight to \(address, privacy: .private)")
		if profile.autoWake {
			let sent = DiscoveryService.wake(address: address, keys: keys, ps5: console.isPS5)
			StreamSession.timing.notice("Wake \(sent ? "sent" : "failed to send", privacy: .public) to the away address")
		}
		// Up to about a minute of tries (each waits up to 5 s for an answer, then 3 s), enough for a PS5 to wake
		// from rest mode. A wrong address or a missing port forward fails after that.
		let s = makeSession(console, keys: keys, ceiling: profile.customStream ?? settings, retries: 7, address: address)
		session = s
		s.start()
		return s
	}

	/// A session that, if the console turns out not to be ready yet, quietly tries again a few seconds later
	/// (the stream window keeps showing "Connecting…"). `address` connects straight to an address away from home.
	private func makeSession(_ console: RegisteredConsole, keys: ConsoleKeys, ceiling: StreamSettings, retries: Int,
							 address: String? = nil) -> StreamSession {
		var current = registered.first { $0.hostID == console.hostID } ?? console
		if let address { current.lastAddress = address }
		let link = ConnectionQuality.currentLink(internet: address != nil)
		let s = StreamSession(console: current, keys: keys, settings: streamSettings(link, ceiling: ceiling), link: link,
							  automaticQuality: autoQuality, smoothing: smoothing)
		if let address {
			s.unreachableHint = "Couldn’t reach \(console.nickname) at \(address). Check that your router forwards the PS5’s ports (9295 TCP and UDP, and 9296, 9297 and 9302 UDP) to it, and that the address is your home’s current one."
		}
		s.onConnectionLost = { [weak self] in self?.streamLost($0) }
		s.retryWhenNotReady = { [weak self] failed in
			guard let self, retries > 0, self.session === failed else { return false }
			Task { @MainActor in
				try? await Task.sleep(for: .seconds(3))
				// Ended or replaced in the meantime (the user closed the window).
				guard self.session === failed else { return }
				let next = self.makeSession(console, keys: keys, ceiling: ceiling, retries: retries - 1, address: address)
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
				let sent = DiscoveryService.wake(address: address, keys: keys, ps5: console.isPS5)
				StreamSession.timing.notice("Wake \(sent ? "sent" : "failed to send", privacy: .public) to \(address, privacy: .public) at \(Double(tick) / 2, privacy: .public) s")
			}
			try? await Task.sleep(for: .milliseconds(500))
			if discoveredState(of: console)?.state == .ready {
				StreamSession.timing.notice("Console ready after \(Double(tick + 1) / 2, privacy: .public) s")
				return
			}
		}
		StreamSession.timing.notice("Console didn’t wake in 45 s")
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
		reconnectTask?.cancel()
		reconnectTask = nil
		reconnecting = nil
		reconnectError = nil
		session?.stop()
		session = nil
	}

	/// The stream stopped arriving, usually because the Mac moved to another network. End it, wait
	/// for the new network, then connect again the best way from there: at home if the console can
	/// be found, otherwise over the internet.
	private func streamLost(_ lost: StreamSession) {
		guard session === lost, reconnecting == nil else { lost.stop(); return }
		let console = lost.console
		reconnecting = console
		reconnectError = nil
		StreamSession.timing.notice("Stream lost; reconnecting")
		// A network switch says nothing about the connection's quality.
		lost.skipLearning()
		lost.stop()
		session = nil
		reconnectTask = Task { [weak self] in
			await self?.reconnect(console)
		}
	}

	private func reconnect(_ console: RegisteredConsole) async {
		// Wait up to 30 s for the Mac to be on a network again.
		for _ in 0..<60 where PathWatcher.shared.path?.status != .satisfied {
			try? await Task.sleep(for: .milliseconds(500))
			if Task.isCancelled { return }
		}
		StreamSession.timing.notice("Network ready")
		// Keep trying for up to 2 minutes. The console holds on to the lost stream for a while (it never
		// heard it end) and ignores new requests until it lets go, so an unanswered request is
		// abandoned after 8 s and made again, rather than waiting out libchiaki's 30 s.
		let deadline = ContinuousClock.now + .seconds(120)
		var attempt = 0
		// Tries in a row that reached the console but couldn't open a direct connection to it.
		var punchFailures = 0
		while ContinuousClock.now < deadline {
			// On a different network from the console: go over the internet straight away. Otherwise
			// give discovery a moment to find it here (it forgets a console 3 s after it stops
			// answering), so a home connection is used when there is one.
			let current = registered.first { $0.hostID == console.hostID } ?? console
			let away = internetPlay && psnSignedIn && !LocalNetwork.contains(current.lastAddress)
			try? await Task.sleep(for: .seconds(attempt == 0 ? (away ? 0.5 : 4) : (away ? 1 : 5)))
			attempt += 1
			reconnectAttempt = attempt
			if Task.isCancelled { return }
			lastError = nil
			guard await connect(console) != nil else {
				// Not even started (no sign-in, console not found on PSN): trying again won't help.
				if !away { continue }
				break
			}
			// Wait for this attempt to stream or fail (over the internet that can take a minute). Follow
			// `session` rather than the first one: a console that isn't ready yet gets fresh sessions.
			var waitingSince: ContinuousClock.Instant?
			while let s = session, s.isStarting {
				try? await Task.sleep(for: .milliseconds(500))
				if Task.isCancelled { return }
				if s.internetStep == CW_PSN_STEP_CONSOLE {
					let since = waitingSince ?? ContinuousClock.now
					waitingSince = since
					if ContinuousClock.now - since > .seconds(8) {
						StreamSession.timing.notice("Console didn’t answer in 8 s; asking again")
						break
					}
				} else {
					waitingSince = nil
				}
			}
			if session?.phase == .streaming {
				reconnecting = nil
				return
			}
			if let s = session, s.couldNotPunch {
				punchFailures += 1
				// Twice on the same network: this network won't allow it, so say so now rather
				// than retrying for two minutes.
				if punchFailures >= 2 {
					if case .ended(let message) = s.phase { lastError = message }
					StreamSession.timing.notice("No direct connection on this network after \(punchFailures, privacy: .public) tries; giving up")
					s.stop()
					session = nil
					break
				}
			} else {
				punchFailures = 0
			}
			session?.stop()
			session = nil
		}
		if Task.isCancelled { return }
		reconnecting = nil
		reconnectError = lastError ?? "Couldn’t reconnect to \(console.nickname) on this network."
			+ (internetPlay ? "" : " To play away from home, turn on Internet Play in Settings.")
		lastError = nil
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
