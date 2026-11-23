import Foundation
import Observation

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
	private(set) var session: StreamSession?
	/// Bumped by the Show Stream Controls command; the stream window reveals its controls.
	var controlsRequest = 0
	/// Shows the first-run setup over the console list.
	var showingOnboarding = false
	private(set) var waking: Set<String> = []
	var lastError: String?

	@ObservationIgnored private var discovery: DiscoveryService?

	init() {
		_ = cw_init()
	}

	func startDiscovery() {
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

		let s = makeSession(console, keys: keys, settings: profile.customStream ?? settings, retries: 3)
		session = s
		s.start()
		return s
	}

	/// A session that, if the console turns out not to be ready yet, quietly tries again a few seconds later
	/// (the stream window keeps showing "Connecting…").
	private func makeSession(_ console: RegisteredConsole, keys: ConsoleKeys, settings: StreamSettings, retries: Int) -> StreamSession {
		let current = registered.first { $0.hostID == console.hostID } ?? console
		let s = StreamSession(console: current, keys: keys, settings: settings)
		s.retryWhenNotReady = { [weak self] failed in
			guard let self, retries > 0, self.session === failed else { return false }
			Task { @MainActor in
				try? await Task.sleep(for: .seconds(3))
				// Ended or replaced in the meantime (the user closed the window).
				guard self.session === failed else { return }
				let next = self.makeSession(console, keys: keys, settings: settings, retries: retries - 1)
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

	func endSession() {
		session?.stop()
		session = nil
	}
}
