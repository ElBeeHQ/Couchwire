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
	var accountID: String = ConsoleStore.accountID {
		didSet { ConsoleStore.accountID = accountID }
	}
	private(set) var session: StreamSession?
	private(set) var waking: Set<String> = []
	var lastError: String?

	@ObservationIgnored private var discovery: DiscoveryService?

	init() {
		_ = pss_init()
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

	func forget(_ console: RegisteredConsole) {
		ConsoleStore.deleteKeys(for: console.hostID)
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

		if discoveredState(of: console)?.state == .standby {
			waking.insert(console.hostID)
			defer { waking.remove(console.hostID) }
			_ = DiscoveryService.wake(address: console.lastAddress, keys: keys, ps5: console.isPS5)
			// Wait up to 45 s for the console to report ready.
			for _ in 0..<90 {
				try? await Task.sleep(for: .milliseconds(500))
				if discoveredState(of: console)?.state == .ready { break }
			}
			guard discoveredState(of: console)?.state == .ready else {
				lastError = "\(console.nickname) didn’t wake up. Make sure “Enable Turning On PS5 from Network” is on in Settings › System › Power Saving."
				return nil
			}
		}

		let current = registered.first { $0.hostID == console.hostID } ?? console
		let s = StreamSession(console: current, keys: keys, settings: settings)
		session = s
		s.start()
		return s
	}

	func endSession() {
		session?.stop()
		session = nil
	}
}
