import Foundation
import Security

/// PSN OAuth tokens. Kept only while Internet Play is on.
struct PSNCredentials: Codable, Sendable {
	var accessToken: String
	var refreshToken: String
	var expiry: Date
}

/// The PSN sign-in internet play uses, in the login Keychain (this Mac only). Nothing is stored
/// unless Internet Play is on; turning it off deletes it. One actor, so two connects never refresh
/// the same token at once.
actor PSNTokens {
	static let shared = PSNTokens()

	private static let service = "com.elbeehq.couchwire.psn"
	private static let account = "tokens"
	/// Refresh this long before the access token expires, as chiaki-ng does.
	private static let margin: TimeInterval = 60

	private var isDemo: Bool { UserDefaults.standard.bool(forKey: "CouchwireDemo") }

	/// Whether a sign-in is stored.
	var isSignedIn: Bool { load() != nil }

	func save(_ credentials: PSNCredentials) {
		guard !isDemo, let data = try? JSONEncoder().encode(credentials) else { return }
		SecItemDelete(Self.query as CFDictionary)
		var add = Self.query
		add[kSecValueData as String] = data
		add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		SecItemAdd(add as CFDictionary, nil)
	}

	func delete() {
		guard !isDemo else { return }
		SecItemDelete(Self.query as CFDictionary)
	}

	/// A current access token, refreshed first if it's about to expire. Throws
	/// `PSNAuth.Failure.signInExpired` (and forgets the sign-in) when PSN wants a new sign-in.
	func accessToken() async throws -> String {
		guard var credentials = load() else { throw PSNAuth.Failure.signInExpired }
		if credentials.expiry.timeIntervalSinceNow > Self.margin { return credentials.accessToken }
		do {
			credentials = try await PSNAuth.refresh(credentials.refreshToken)
		} catch PSNAuth.Failure.signInExpired {
			delete()
			throw PSNAuth.Failure.signInExpired
		}
		save(credentials)
		return credentials.accessToken
	}

	private func load() -> PSNCredentials? {
		var query = Self.query
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var out: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
		return try? JSONDecoder().decode(PSNCredentials.self, from: data)
	}

	private static var query: [String: Any] {
		[kSecClass as String: kSecClassGenericPassword,
		 kSecAttrService as String: service,
		 kSecAttrAccount as String: account]
	}
}
