import Foundation
import Security

/// Persists paired consoles. Metadata lives in UserDefaults; the per-console
/// registration keys live in the login Keychain.
enum ConsoleStore {
	private static let consolesKey = "registeredConsoles"
	private static let settingsKey = "streamSettings"
	private static let accountKey = "psnAccountID"
	private static let profilesKey = "consoleProfiles"
	/// Kept from before the rename to Couchwire, so existing pairing keys stay readable.
	private static let keychainService = "PSStream.consoleKeys"

	static func loadConsoles() -> [RegisteredConsole] {
		guard let data = UserDefaults.standard.data(forKey: consolesKey) else { return [] }
		return (try? JSONDecoder().decode([RegisteredConsole].self, from: data)) ?? []
	}

	/// Demo mode (`-CouchwireDemo YES`) never writes over your real consoles, settings or keys.
	private static var isDemo: Bool { UserDefaults.standard.bool(forKey: "CouchwireDemo") }

	static func saveConsoles(_ consoles: [RegisteredConsole]) {
		guard !isDemo else { return }
		UserDefaults.standard.set(try? JSONEncoder().encode(consoles), forKey: consolesKey)
	}

	static func loadSettings() -> StreamSettings {
		guard let data = UserDefaults.standard.data(forKey: settingsKey),
			  let s = try? JSONDecoder().decode(StreamSettings.self, from: data) else { return StreamSettings() }
		return s
	}

	static func saveSettings(_ s: StreamSettings) {
		guard !isDemo else { return }
		UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: settingsKey)
	}

	static func loadProfiles() -> [String: ConsoleProfile] {
		guard let data = UserDefaults.standard.data(forKey: profilesKey) else { return [:] }
		return (try? JSONDecoder().decode([String: ConsoleProfile].self, from: data)) ?? [:]
	}

	static func saveProfiles(_ profiles: [String: ConsoleProfile]) {
		guard !isDemo else { return }
		UserDefaults.standard.set(try? JSONEncoder().encode(profiles), forKey: profilesKey)
	}

	static var accountID: String {
		get { UserDefaults.standard.string(forKey: accountKey) ?? "" }
		set { if !isDemo { UserDefaults.standard.set(newValue, forKey: accountKey) } }
	}

	// MARK: Keychain

	static func saveKeys(_ keys: ConsoleKeys, for hostID: String) {
		guard !isDemo else { return }
		guard let data = try? JSONEncoder().encode(keys) else { return }
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: keychainService,
			kSecAttrAccount as String: hostID,
		]
		SecItemDelete(query as CFDictionary)
		var add = query
		add[kSecValueData as String] = data
		add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		SecItemAdd(add as CFDictionary, nil)
	}

	static func loadKeys(for hostID: String) -> ConsoleKeys? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: keychainService,
			kSecAttrAccount as String: hostID,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne,
		]
		var out: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
		return try? JSONDecoder().decode(ConsoleKeys.self, from: data)
	}

	static func deleteKeys(for hostID: String) {
		guard !isDemo else { return }
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: keychainService,
			kSecAttrAccount as String: hostID,
		]
		SecItemDelete(query as CFDictionary)
	}
}
