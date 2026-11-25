import Foundation
import os

private let coreLog = Logger(subsystem: "Couchwire", category: "Core")

func logFromCore(_ level: Int32, _ msg: UnsafePointer<CChar>?) {
	guard let msg else { return }
	let raw = String(cString: msg)
	switch level {
	case Int32(CW_LOG_ERROR.rawValue), Int32(CW_LOG_WARNING.rawValue): break
	default:
		// Info level isn't stored, so it stays as it was (readable with `log stream --level info`).
		if !keepCoreLog { coreLog.info("\(raw, privacy: .public)"); return }
	}
	// These lines are kept, so network addresses in them are hidden. The rest stays readable,
	// so a slow or failed connect can still be looked into.
	let s = maskAddresses(raw)
	switch level {
	case Int32(CW_LOG_ERROR.rawValue): coreLog.error("\(s, privacy: .public)")
	case Int32(CW_LOG_WARNING.rawValue): coreLog.warning("\(s, privacy: .public)")
	default:
		// Kept (notice) while an internet connection is being set up, so slow ones can be looked into.
		coreLog.notice("\(s, privacy: .public)")
	}
}

private let ipv4 = try! NSRegularExpression(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#)
/// Three or more colon-separated hex groups: IPv6 addresses (and MAC addresses).
private let ipv6 = try! NSRegularExpression(pattern: #"(?<![0-9A-Za-z:])(?:[0-9A-Fa-f]{0,4}:){3,7}[0-9A-Fa-f]{0,4}(?![0-9A-Za-z:])"#)

/// Replaces IPv4, IPv6 and MAC addresses with "<address>".
func maskAddresses(_ s: String) -> String {
	guard s.contains(".") || s.contains(":") else { return s }
	var out = s
	for re in [ipv4, ipv6] {
		out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "<address>")
	}
	return out
}

/// On while an internet connection is being set up. A plain flag: an off-by-one log line doesn't matter.
nonisolated(unsafe) var keepCoreLog = false

let cLog: CWLogCallback = { level, msg, _ in logFromCore(level, msg) }

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
	/// Guards `handle` and `finished`: the result can arrive on chiaki's thread before
	/// `cw_regist_start` has returned the handle.
	private let lock = NSLock()
	private var handle: OpaquePointer?
	private var finished = false
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
				lock.lock()
				if finished {
					// Already done: `finish` had no handle to free.
					lock.unlock()
					// Passed as a plain number: a C pointer isn't Sendable.
					let bits = UInt(bitPattern: started)
					DispatchQueue.global().async { cw_regist_free(OpaquePointer(bitPattern: bits)) }
				} else {
					handle = started
					lock.unlock()
				}
			} else {
				Unmanaged<RegistrationService>.fromOpaque(ctx).release()
				continuation = nil
				cont.resume(throwing: RegistrationError.failedToStart)
			}
		}
	}

	func cancel() {
		lock.lock()
		defer { lock.unlock() }
		cw_regist_cancel(handle) // only signals the thread; doesn't block
	}

	private func finish(_ r: CWRegistResult) {
		var r = r
		let cont = continuation
		continuation = nil
		// Free off the callback thread (free joins it).
		lock.lock()
		let h = handle
		handle = nil
		finished = true
		lock.unlock()
		if let h { DispatchQueue.global().async { cw_regist_free(h) } }

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
