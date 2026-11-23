import Foundation
import GameController
import QuartzCore
import os

/// Maps the active game controller (DualSense, DualShock 4, Xbox, MFi…) and the keyboard
/// onto the PS5 controller state.
///
/// Latency: there is no polling timer. Every GameController value-change callback runs on
/// a dedicated user-interactive queue and sends the new state straight away. libchiaki
/// de-duplicates identical states, so redundant sends cost nothing.
final class ControllerInput: @unchecked Sendable {
	private let queue = DispatchQueue(label: "Couchwire.input", qos: .userInteractive)
	private var state = cw_controller_idle()
	private var keyboardButtons: UInt32 = 0
	private var observers: [NSObjectProtocol] = []
	private var controller: GCController?
	private let send: (CWControllerState) -> Void
	private let log = Logger(subsystem: "Couchwire", category: "Input")
	private lazy var feedback = ControllerFeedback(queue: queue)
	private let stats: StreamStats?
	private var loggedClock = false
	/// Kernel arrival time (mach) of the latest DualSense input report; written on the HID queue.
	private var lastReportMach: UInt64 = 0
	private var reportLock = os_unfair_lock()
	private static let machToSeconds: Double = {
		var info = mach_timebase_info_data_t()
		mach_timebase_info(&info)
		return Double(info.numer) / Double(info.denom) / 1_000_000_000
	}()

	private func reportArrived(_ timeStamp: UInt64) {
		os_unfair_lock_lock(&reportLock)
		lastReportMach = timeStamp
		os_unfair_lock_unlock(&reportLock)
		stats?.inputReport()
	}

	init(stats: StreamStats? = nil, send: @escaping (CWControllerState) -> Void) {
		self.stats = stats
		self.send = send
		feedback.onInputReport = { [weak self] timeStamp in
			self?.reportArrived(timeStamp)
		}
	}

	func start() {
		GCController.shouldMonitorBackgroundEvents = false
		let nc = NotificationCenter.default
		observers.append(nc.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: nil) { [weak self] n in
			guard let c = n.object as? GCController else { return }
			self?.queue.async { self?.attach(c) }
		})
		observers.append(nc.addObserver(forName: .GCControllerDidStopBeingCurrent, object: nil, queue: nil) { [weak self] n in
			guard let c = n.object as? GCController else { return }
			self?.queue.async { self?.detach(c) }
		})
		observers.append(nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: nil) { [weak self] n in
			guard let kb = n.object as? GCKeyboard else { return }
			self?.queue.async { self?.attachKeyboard(kb) }
		})
		queue.async { [self] in
			if let c = GCController.current ?? GCController.controllers().first { attach(c) }
			if let kb = GCKeyboard.coalesced { attachKeyboard(kb) }
		}
	}

	func stop() {
		observers.forEach(NotificationCenter.default.removeObserver)
		observers.removeAll()
		queue.sync {
			controller?.extendedGamepad?.valueChangedHandler = nil
			controller?.motion?.valueChangedHandler = nil
			GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
			feedback.detach()
			controller = nil
		}
	}

	func rumble(left: UInt8, right: UInt8) {
		queue.async { self.feedback.setRumble(left: left, right: right) }
	}

	/// Raw DualSense trigger effects from the console (type byte + 10 parameter bytes each).
	func triggerEffects(typeLeft: UInt8, left: [UInt8], typeRight: UInt8, right: [UInt8]) {
		let l = TriggerEffect(type: typeLeft, params: left)
		let r = TriggerEffect(type: typeRight, params: right)
		log.debug("Trigger params L=\(left.map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public) R=\(right.map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public)")
		log.info("Trigger effects L=0x\(String(typeLeft, radix: 16), privacy: .public)\(l == nil ? " (unsupported)" : "", privacy: .public) R=0x\(String(typeRight, radix: 16), privacy: .public)\(r == nil ? " (unsupported)" : "", privacy: .public)")
		let rawLeft = [typeLeft] + left.prefix(10), rawRight = [typeRight] + right.prefix(10)
		queue.async { self.feedback.setTriggerEffects(rawLeft: rawLeft, rawRight: rawRight, left: l, right: r) }
	}

	func lightbar(r: UInt8, g: UInt8, b: UInt8) {
		log.info("Lightbar \(r) \(g) \(b)")
		queue.async { self.feedback.setLightbar(r: r, g: g, b: b) }
	}

	func playerIndex(_ index: UInt8) {
		log.info("Player index \(index)")
		queue.async { self.feedback.setPlayerIndex(index) }
	}

	/// Haptic PCM from the console, called on libchiaki's receive thread.
	func haptics(_ pcm: UnsafeBufferPointer<Int16>, frames: Int) {
		feedback.pushHaptics(pcm, frames: frames)
	}

	// MARK: - Controller

	private func attach(_ c: GCController) {
		guard c !== controller, let pad = c.extendedGamepad else { return }
		controller?.extendedGamepad?.valueChangedHandler = nil
		controller = c
		c.handlerQueue = queue
		log.info("Using controller: \(c.vendorName ?? "unknown")")

		pad.valueChangedHandler = { [weak self] pad, _ in self?.update(from: pad) }
		if let motion = c.motion {
			motion.sensorsActive = true
			motion.valueChangedHandler = { [weak self] m in self?.update(motion: m) }
		}
		feedback.attach(c)
		update(from: pad)
	}

	private func detach(_ c: GCController) {
		guard c === controller else { return }
		c.extendedGamepad?.valueChangedHandler = nil
		c.motion?.valueChangedHandler = nil
		feedback.detach()
		controller = nil
		let idle = cw_controller_idle()
		state = idle
		state.buttons = keyboardButtons
		send(state)
	}

	private func update(from pad: GCExtendedGamepad) {
		var b: UInt32 = 0
		func map(_ button: GCControllerButtonInput?, _ flag: Int) {
			if button?.isPressed == true { b |= UInt32(flag) }
		}
		map(pad.buttonA, CW_BUTTON_CROSS)
		map(pad.buttonB, CW_BUTTON_CIRCLE)
		map(pad.buttonX, CW_BUTTON_SQUARE)
		map(pad.buttonY, CW_BUTTON_TRIANGLE)
		map(pad.leftShoulder, CW_BUTTON_L1)
		map(pad.rightShoulder, CW_BUTTON_R1)
		map(pad.leftThumbstickButton, CW_BUTTON_L3)
		map(pad.rightThumbstickButton, CW_BUTTON_R3)
		map(pad.buttonMenu, CW_BUTTON_OPTIONS)
		map(pad.buttonOptions, CW_BUTTON_CREATE)
		map(pad.buttonHome, CW_BUTTON_PS)
		map(pad.dpad.up, CW_BUTTON_DPAD_UP)
		map(pad.dpad.down, CW_BUTTON_DPAD_DOWN)
		map(pad.dpad.left, CW_BUTTON_DPAD_LEFT)
		map(pad.dpad.right, CW_BUTTON_DPAD_RIGHT)

		state.l2 = UInt8(clamping: Int(pad.leftTrigger.value * 255))
		state.r2 = UInt8(clamping: Int(pad.rightTrigger.value * 255))
		state.left_x = axis(pad.leftThumbstick.xAxis.value)
		state.left_y = axis(-pad.leftThumbstick.yAxis.value)
		state.right_x = axis(pad.rightThumbstick.xAxis.value)
		state.right_y = axis(-pad.rightThumbstick.yAxis.value)

		if let ds = pad as? GCDualSenseGamepad {
			map(ds.touchpadButton, CW_BUTTON_TOUCHPAD)
			setTouch(0, ds.touchpadPrimary)
			setTouch(1, ds.touchpadSecondary)
		} else if let ds4 = pad as? GCDualShockGamepad {
			map(ds4.touchpadButton, CW_BUTTON_TOUCHPAD)
			setTouch(0, ds4.touchpadPrimary)
			setTouch(1, ds4.touchpadSecondary)
		}

		state.buttons = b | keyboardButtons
		send(state)
		recordInputTiming(pad)
	}

	/// Time from the controller's report reaching the Mac (the kernel's HID timestamp) to the
	/// new state being handed to libchiaki. GameController's own event timestamp is taken when
	/// it hands the event to us, so it would miss the HID-to-app delivery we want to see.
	private func recordInputTiming(_ pad: GCExtendedGamepad) {
		os_unfair_lock_lock(&reportLock)
		let report = lastReportMach
		os_unfair_lock_unlock(&reportLock)
		if report > 0 {
			let now = mach_absolute_time()
			guard now >= report else { return }
			let seconds = Double(now - report) * Self.machToSeconds
			if !loggedClock {
				loggedClock = true
				log.info("Input timing: HID report to send \(seconds * 1000) ms")
			}
			stats?.inputSent(eventAt: 0, sentAt: seconds)
		} else {
			// Not a DualSense over HID: the best we have is GameController's (Unix) timestamp.
			stats?.inputSent(eventAt: pad.lastEventTimestamp, sentAt: Date().timeIntervalSince1970)
		}
	}

	private var touchIDs: [Int8] = [-1, -1]
	private var nextTouchID: Int8 = 0

	/// GameController reports the touchpad as -1...1 on each axis with 0,0 meaning "no touch".
	private func setTouch(_ i: Int, _ pad: GCControllerDirectionPad) {
		let x = pad.xAxis.value, y = pad.yAxis.value
		let touching = x != 0 || y != 0
		if touching {
			if touchIDs[i] < 0 {
				touchIDs[i] = nextTouchID
				nextTouchID = (nextTouchID + 1) & 0x7F
			}
			let tx = UInt16(clamping: Int((x + 1) / 2 * 1919))
			let ty = UInt16(clamping: Int((1 - (y + 1) / 2) * 941))
			withUnsafeMutablePointer(to: &state.touch_x) { $0.withMemoryRebound(to: UInt16.self, capacity: 2) { $0[i] = tx } }
			withUnsafeMutablePointer(to: &state.touch_y) { $0.withMemoryRebound(to: UInt16.self, capacity: 2) { $0[i] = ty } }
		} else {
			touchIDs[i] = -1
		}
		let id = touchIDs[i]
		withUnsafeMutablePointer(to: &state.touch_id) { $0.withMemoryRebound(to: Int8.self, capacity: 2) { $0[i] = id } }
	}

	private func update(motion m: GCMotion) {
		// GameController: rotation rate in rad/s, gravity + user acceleration in g.
		state.gyro_x = Float(m.rotationRate.x)
		state.gyro_y = Float(m.rotationRate.y)
		state.gyro_z = Float(m.rotationRate.z)
		state.accel_x = Float(m.gravity.x + m.userAcceleration.x)
		state.accel_y = Float(m.gravity.y + m.userAcceleration.y)
		state.accel_z = Float(m.gravity.z + m.userAcceleration.z)
		if m.hasAttitude {
			state.orient_x = Float(m.attitude.x)
			state.orient_y = Float(m.attitude.y)
			state.orient_z = Float(m.attitude.z)
			state.orient_w = Float(m.attitude.w)
		}
		send(state)
		if !feedback.countsReports { stats?.inputReport() }
	}

	private func axis(_ v: Float) -> Int16 {
		Int16(clamping: Int((v * 32767).rounded()))
	}

	// MARK: - Keyboard fallback (for menus when no controller is connected)

	private static let keyMap: [GCKeyCode: Int] = [
		.returnOrEnter: CW_BUTTON_CROSS,
		.deleteOrBackspace: CW_BUTTON_CIRCLE,
		.upArrow: CW_BUTTON_DPAD_UP,
		.downArrow: CW_BUTTON_DPAD_DOWN,
		.leftArrow: CW_BUTTON_DPAD_LEFT,
		.rightArrow: CW_BUTTON_DPAD_RIGHT,
		.keyQ: CW_BUTTON_L1,
		.keyE: CW_BUTTON_R1,
		.keyO: CW_BUTTON_OPTIONS,
		.keyP: CW_BUTTON_PS,
		.keyT: CW_BUTTON_TOUCHPAD,
	]

	private func attachKeyboard(_ kb: GCKeyboard) {
		kb.handlerQueue = queue
		kb.keyboardInput?.keyChangedHandler = { [weak self] _, _, code, pressed in
			guard let self, let flag = Self.keyMap[code] else { return }
			if pressed { keyboardButtons |= UInt32(flag) } else { keyboardButtons &= ~UInt32(flag) }
			state.buttons = (state.buttons & ~UInt32(0xFFFF)) | keyboardButtons
			if let pad = controller?.extendedGamepad { update(from: pad) } else { send(state) }
		}
	}
}
