import Foundation
import os

private let coreLog = Logger(subsystem: "Couchwire", category: "Core")

func logFromCore(_ level: Int32, _ msg: UnsafePointer<CChar>?) {
	guard let msg else { return }
	let s = String(cString: msg)
	switch level {
	case Int32(CW_LOG_ERROR.rawValue): coreLog.error("\(s, privacy: .public)")
	case Int32(CW_LOG_WARNING.rawValue): coreLog.warning("\(s, privacy: .public)")
	default: coreLog.info("\(s, privacy: .public)")
	}
}

private let cLog: CWLogCallback = { level, msg, _ in logFromCore(level, msg) }

// MARK: - Discovery

/// Continuously discovers consoles on the LAN. Callback is delivered on the main actor.
final class DiscoveryService: @unchecked Sendable {
	private var handle: OpaquePointer?
	private let onUpdate: @MainActor ([DiscoveredConsole]) -> Void

	init(onUpdate: @escaping @MainActor ([DiscoveredConsole]) -> Void) {
		self.onUpdate = onUpdate
	}

	func start() {
		guard handle == nil else { return }
		let ctx = Unmanaged.passUnretained(self).toOpaque()
		handle = cw_discovery_start({ hosts, count, user in
			let me = Unmanaged<DiscoveryService>.fromOpaque(user!).takeUnretainedValue()
			let list = (0..<count).map { DiscoveredConsole(hosts![$0]) }
			Task { @MainActor in me.onUpdate(list) }
		}, cLog, ctx)
	}

	func stop() {
		cw_discovery_stop(handle)
		handle = nil
	}

	deinit { stop() }

	static func wake(address: String, keys: ConsoleKeys, ps5: Bool) -> Bool {
		var key = [CChar](repeating: 0, count: 16)
		keys.registKey.withUnsafeBytes { raw in
			for i in 0..<min(16, raw.count) { key[i] = CChar(bitPattern: raw[i]) }
		}
		return cw_wakeup(address, key, ps5, cLog, nil) == 0
	}
}

// MARK: - Registration

enum RegistrationError: LocalizedError {
	case invalidAccountID, invalidPIN, failedToStart, rejected
	var errorDescription: String? {
		switch self {
		case .invalidAccountID: "That Account ID doesn’t look right. It’s 12 characters ending in “=”. Signing in fills it in for you."
		case .invalidPIN: "Enter the 8-digit code shown on your PS5."
		case .failedToStart: "Couldn’t reach the PS5. Check it’s switched on and on the same network as your Mac."
		case .rejected: "The PS5 didn’t accept the code. Check you typed the code shown on the TV, or choose Link Device again for a new one. If it still fails, make sure you signed in with the PSN account you use on this PS5."
		}
	}
}

struct RegistrationResult: Sendable {
	let nickname: String
	let hostID: String
	let isPS5: Bool
	let keys: ConsoleKeys
}

/// Pairs this Mac with a console. One-shot; await `register`.
final class RegistrationService: @unchecked Sendable {
	private var handle: OpaquePointer?
	private var continuation: CheckedContinuation<RegistrationResult, Error>?

	func register(address: String, accountID: String, pin: String, ps5: Bool) async throws -> RegistrationResult {
		guard let account = Data(base64Encoded: accountID.trimmingCharacters(in: .whitespaces)), account.count == 8 else {
			throw RegistrationError.invalidAccountID
		}
		let digits = pin.filter(\.isNumber)
		guard digits.count == 8, let pinValue = UInt32(digits) else { throw RegistrationError.invalidPIN }

		return try await withCheckedThrowingContinuation { cont in
			continuation = cont
			let ctx = Unmanaged.passRetained(self).toOpaque()
			let started: OpaquePointer? = account.withUnsafeBytes { raw in
				cw_regist_start(address, raw.bindMemory(to: UInt8.self).baseAddress, pinValue, ps5, { result, user in
					let me = Unmanaged<RegistrationService>.fromOpaque(user!).takeRetainedValue()
					me.finish(result!.pointee)
				}, cLog, ctx)
			}
			if let started {
				handle = started
			} else {
				Unmanaged<RegistrationService>.fromOpaque(ctx).release()
				continuation = nil
				cont.resume(throwing: RegistrationError.failedToStart)
			}
		}
	}

	func cancel() {
		cw_regist_cancel(handle)
	}

	private func finish(_ r: CWRegistResult) {
		var r = r
		let cont = continuation
		continuation = nil
		// Free off the callback thread (free joins it).
		let h = handle
		handle = nil
		DispatchQueue.global().async { cw_regist_free(h) }

		guard r.success else {
			cont?.resume(throwing: RegistrationError.rejected)
			return
		}
		let registKey = withUnsafeBytes(of: &r.regist_key) { Data($0) }
		let rpKey = withUnsafeBytes(of: &r.rp_key) { Data($0) }
		let mac = withUnsafeBytes(of: &r.server_mac) { Data($0) }
		cont?.resume(returning: RegistrationResult(
			nickname: cString(&r.server_nickname),
			hostID: mac.hexString,
			isPS5: r.is_ps5,
			keys: ConsoleKeys(registKey: registKey, rpKey: rpKey)))
	}
}
