import Foundation

/// The app was renamed from PSStream (bundle ID `com.psstream.PSStream`) to Couchwire
/// (`com.elbeehq.couchwire`). A new bundle ID means a new UserDefaults domain, so paired
/// consoles, the PSN Account ID and settings would vanish. On first launch under the new
/// ID, copy everything across once. Pairing keys live in the Keychain under a service
/// name that did not change, so they need no migration.
enum LegacyDefaults {
	private static let legacyDomain = "com.psstream.PSStream"
	private static let migratedKey = "migratedFromPSStream"

	static func migrateIfNeeded() {
		let defaults = UserDefaults.standard
		guard !defaults.bool(forKey: migratedKey) else { return }
		defer { defaults.set(true, forKey: migratedKey) }
		guard let old = defaults.persistentDomain(forName: legacyDomain) else { return }
		for (key, value) in old where defaults.object(forKey: key) == nil {
			defaults.set(value, forKey: key)
		}
	}
}
