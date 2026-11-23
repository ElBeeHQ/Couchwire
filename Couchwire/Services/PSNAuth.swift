import Foundation

/// Signs in to PlayStation Network with the Remote Play app's OAuth client (same flow as the
/// official app) to get the PSN account ID needed for pairing, and the tokens internet play needs.
///
/// The sign-in web view uses a non-persistent data store. The caller decides whether to keep the
/// tokens: only with Internet Play on (see PSNTokens); otherwise they're dropped straight away.
enum PSNAuth {
	static let redirectURI = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
	private static let clientID = "ba495a24-818c-472b-b12d-ff231c1b5745"
	private static let clientSecret = "mvaiZkRsAsI1IBkY"
	private static let tokenURL = URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token")!
	private static let scope = "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"

	enum Failure: LocalizedError {
		case badRedirect, server(String), malformed, signInExpired
		var errorDescription: String? {
			switch self {
			case .signInExpired: "Your PlayStation Network sign-in has expired. Sign in again in Settings › Account."
			case .badRedirect: "Sign-in didn’t return an authorization code. Please try again."
			case .server(let msg): "PlayStation Network returned an error: \(msg)"
			case .malformed: "PlayStation Network sent a response Couchwire couldn’t read."
			}
		}
	}

	static var authorizeURL: URL {
		var c = URLComponents(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize")!
		c.queryItems = [
			.init(name: "service_entity", value: "urn:service-entity:psn"),
			.init(name: "response_type", value: "code"),
			.init(name: "client_id", value: clientID),
			.init(name: "redirect_uri", value: redirectURI),
			.init(name: "scope", value: scope),
			.init(name: "request_locale", value: Locale.current.identifier.replacingOccurrences(of: "-", with: "_")),
			.init(name: "ui", value: "pr"),
			.init(name: "service_logo", value: "ps"),
			.init(name: "layout_type", value: "popup"),
			.init(name: "smcid", value: "remoteplay"),
			.init(name: "prompt", value: "always"),
			.init(name: "PlatformPrivacyWs1", value: "minimal"),
			// A fresh client device id per sign-in; tokens for internet play must come from a sign-in
			// that carried one (chiaki-ng's holepunch.h).
			.init(name: "duid", value: clientDUID()),
		]
		return c.url!
	}

	static func isRedirect(_ url: URL) -> Bool {
		url.absoluteString.hasPrefix(redirectURI)
	}

	/// The result of signing in: the account ID for pairing and the tokens for internet play.
	struct SignIn {
		let accountID: String
		let credentials: PSNCredentials
	}

	/// Extracts the `code` from the redirect, exchanges it for tokens, and looks up the user ID.
	static func signIn(fromRedirect url: URL) async throws -> SignIn {
		guard let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
			.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
			throw Failure.badRedirect
		}

		// 1. Authorization code → tokens
		let credentials = try await tokens([
			"grant_type": "authorization_code",
			"code": code,
			"scope": scope,
			"redirect_uri": redirectURI,
		])

		// 2. Token info → numeric user_id
		var infoRequest = URLRequest(url: tokenURL.appendingPathComponent(credentials.accessToken))
		infoRequest.setValue(basicAuth, forHTTPHeaderField: "Authorization")
		infoRequest.setValue("application/json", forHTTPHeaderField: "Accept")
		let info = try await json(for: infoRequest)
		let userIDString = (info["user_id"] as? String) ?? (info["user_id"] as? NSNumber)?.stringValue
		guard let userIDString, let userID = UInt64(userIDString) else { throw Failure.malformed }

		// 3. Account ID = user_id as 8 little-endian bytes, Base64-encoded.
		var le = userID.littleEndian
		return SignIn(accountID: Data(bytes: &le, count: 8).base64EncodedString(), credentials: credentials)
	}

	/// New tokens from a refresh token. Throws `signInExpired` when PSN no longer accepts it.
	static func refresh(_ refreshToken: String) async throws -> PSNCredentials {
		do {
			return try await tokens([
				"grant_type": "refresh_token",
				"refresh_token": refreshToken,
				"scope": scope,
				"redirect_uri": redirectURI,
			])
		} catch Failure.server(let message) where message.hasPrefix("HTTP 400") || message.contains("invalid") {
			throw Failure.signInExpired
		}
	}

	private static func tokens(_ form: [String: String]) async throws -> PSNCredentials {
		var request = URLRequest(url: tokenURL)
		request.httpMethod = "POST"
		request.setValue(basicAuth, forHTTPHeaderField: "Authorization")
		request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
		request.httpBody = formEncode(form)
		let response = try await json(for: request)
		guard let access = response["access_token"] as? String else { throw Failure.malformed }
		let lifetime = (response["expires_in"] as? NSNumber)?.doubleValue ?? 3600
		return PSNCredentials(accessToken: access,
							  refreshToken: response["refresh_token"] as? String ?? form["refresh_token"] ?? "",
							  expiry: Date().addingTimeInterval(lifetime))
	}

	private static func clientDUID() -> String {
		var buffer = [CChar](repeating: 0, count: Int(CW_PSN_CLIENT_DUID_SIZE))
		cw_psn_generate_client_duid(&buffer)
		return String(cString: buffer)
	}

	// MARK: - Helpers

	private static var basicAuth: String {
		"Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
	}

	private static func formEncode(_ fields: [String: String]) -> Data {
		var allowed = CharacterSet.alphanumerics
		allowed.insert(charactersIn: "-._~")
		let body = fields.map { key, value in
			"\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
		}.joined(separator: "&")
		return Data(body.utf8)
	}

	private static let session: URLSession = {
		let config = URLSessionConfiguration.ephemeral
		config.timeoutIntervalForRequest = 20
		return URLSession(configuration: config)
	}()

	private static func json(for request: URLRequest) async throws -> [String: Any] {
		let (data, response) = try await session.data(for: request)
		let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
		if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
			let detail = (object?["error_description"] as? String) ?? (object?["error"] as? String) ?? ""
			let msg = "HTTP \(http.statusCode)" + (detail.isEmpty ? "" : ": \(detail)")
			throw Failure.server(msg)
		}
		guard let object else { throw Failure.malformed }
		return object
	}
}
