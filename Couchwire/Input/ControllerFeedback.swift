import AVFoundation
import CoreAudio
import CoreHaptics
import GameController
import os

/// Everything the console sends back to the controller: rumble, DualSense haptics and
/// adaptive-trigger effects. All methods except `pushHaptics` run on the input queue.
final class ControllerFeedback: @unchecked Sendable {
	private let log = Logger(subsystem: "Couchwire", category: "Feedback")
	private var controller: GCController?
	private var motors: HapticMotors?
	private var usbHaptics: DualSenseUSBHaptics?
	private var lastTriggers: (left: TriggerEffect, right: TriggerEffect) = (.off, .off)
	private static let rawOff: [UInt8] = [0x05] + [UInt8](repeating: 0, count: 10)
	private var rawTriggers: (left: [UInt8], right: [UInt8]) = (rawOff, rawOff)
	private var hid: DualSenseHID?
	/// Called on the HID queue for every input report from the DualSense.
	var onInputReport: ((UInt64, UInt8?) -> Void)?
	/// True while input reports are counted straight from the DualSense over HID.
	var countsReports: Bool { hid != nil }
	private var keepaliveTicks = 0
	private var reconnectAfter: CFTimeInterval = 0
	/// USB: keep looking for the controller's audio device until this time. macOS sets it
	/// up a moment after the HID device, so it's often missing right after a plug-in.
	private var usbHapticsRetryUntil: CFTimeInterval = 0
	private static let usbHapticsRetryWindow: CFTimeInterval = 15
	/// PS5 defaults until the console says otherwise: player 1 blue.
	private var lightbar: (UInt8, UInt8, UInt8) = (0, 0, 64)
	/// Mute-button light, as the PS5 uses it: on while the mic is muted.
	private var muteLight: UInt8 = 0
	private var playerLEDs: UInt8 = 0x04
	private var hapticFrames = 0
	private var hapticPeak: Float = 0
	private var rumble: (Float, Float) = (0, 0)
	private var envelope: (Float, Float) = (0, 0)
	private var lastHapticFrame: CFTimeInterval = 0
	private var decayTimer: DispatchSourceTimer?
	private let queue: DispatchQueue

	init(queue: DispatchQueue) {
		self.queue = queue
	}

	// MARK: Controller lifecycle

	func attach(_ c: GCController) {
		detach()
		controller = c
		motors = HapticMotors(controller: c)
		if c.extendedGamepad is GCDualSenseGamepad {
			connectDevices()
		}
		startDecayTimer()
	}

	/// (Re)opens the DualSense on whatever transport it's on now and picks the haptics path:
	/// USB → voice coils via its audio device; Bluetooth → HID rumble emulation.
	private func connectDevices() {
		hid = DualSenseHID.open(onInputReport: onInputReport)
		hid?.onFailure = { [weak self] in
			guard let self else { return }
			queue.async { self.devicesChanged() }
		}
		usbHapticsRetryUntil = 0
		if hid?.isBluetooth == false {
			if usbHaptics == nil { usbHaptics = DualSenseUSBHaptics.makeIfConnected() }
			if usbHaptics == nil { usbHapticsRetryUntil = CACurrentMediaTime() + Self.usbHapticsRetryWindow }
		} else {
			usbHaptics?.stop()
			usbHaptics = nil
		}
		lastSentRumble = (0, 0)
		applyLights()
		hid?.setMuteLight(muteLight)
		logRoute()
		applyTriggers()
	}

	private func logRoute() {
		log.info("DualSense feedback: triggers via \(self.hid == nil ? "GameController (fallback)" : (self.hid!.isBluetooth ? "HID over Bluetooth" : "HID over USB"), privacy: .public), haptics via \(self.usbHaptics != nil ? "USB voice coils" : (self.hid != nil ? "HID rumble" : "Core Haptics"), privacy: .public)")
	}

	/// Over USB with no voice-coil haptics yet: try the controller's audio device again.
	/// Until it appears, haptics play as HID rumble as on Bluetooth.
	private func retryUSBHaptics() {
		guard usbHapticsRetryUntil > 0, usbHaptics == nil, let hid, !hid.isBluetooth else {
			usbHapticsRetryUntil = 0
			return
		}
		guard let usb = DualSenseUSBHaptics.makeIfConnected() else {
			if CACurrentMediaTime() >= usbHapticsRetryUntil {
				usbHapticsRetryUntil = 0
				log.info("DualSense audio device not found over USB; haptics stay on HID rumble")
			}
			return
		}
		usbHapticsRetryUntil = 0
		// Hand over from HID rumble: stop the motors now, since the envelope no longer
		// updates or decays once frames go to the voice coils.
		envelope = (0, 0)
		resetEnvelopeWindow()
		if lastSentRumble != (0, 0) {
			lastSentRumble = (0, 0)
			hid.setRumble(left: 0, right: 0)
		}
		usbHaptics = usb
		logRoute()
	}

	/// The old HID handle is dead (unplugged, or moved between Bluetooth and USB). Drop it;
	/// the timer reconnects once the controller has re-enumerated.
	private func devicesChanged() {
		hid = nil
		usbHaptics?.stop()
		usbHaptics = nil
		usbHapticsRetryUntil = 0
		reconnectAfter = CACurrentMediaTime() + 0.5
	}

	func detach() {
		resetTriggers()
		hid?.setMuteLight(0)
		hid?.setRumble(left: 0, right: 0)
		lastSentRumble = (0, 0)
		hid = nil
		motors?.stop()
		motors = nil
		usbHaptics?.stop()
		usbHaptics = nil
		usbHapticsRetryUntil = 0
		decayTimer?.cancel()
		decayTimer = nil
		controller = nil
		rumble = (0, 0)
		envelope = (0, 0)
		resetEnvelopeWindow()
	}

	// MARK: Rumble (non-DualSense games, or DualSense games that don't use haptics)

	func setRumble(left: UInt8, right: UInt8) {
		rumble = (Float(left) / 255, Float(right) / 255)
		applyMotors()
	}

	// MARK: Haptics

	/// Called on libchiaki's receive thread with stereo 3 kHz PCM (10 ms per frame).
	func pushHaptics(_ pcm: UnsafeBufferPointer<Int16>, frames: Int) {
		let samples = Array(pcm.prefix(frames * 2))
		queue.async { [self] in
			hapticFrames += 1
			lastHapticFrame = CACurrentMediaTime()
			if let usb = usbHaptics {
				samples.withUnsafeBufferPointer { usb.push($0, frames: frames) }
			} else {
				pushEnvelope(samples, frames: frames)
			}
		}
	}

	/// Haptic packets averaged into one rumble level (3 × 10 ms, as chiaki-ng does), which
	/// smooths network jitter and keeps Bluetooth to about 33 rumble reports a second.
	private static let packetsPerLevel = 3
	/// Below this the haptic signal is a faint voice-coil texture, not something to rumble
	/// for (chiaki-ng's HAPTIC_RUMBLE_MIN_STRENGTH, on a 0...1 scale).
	private static let envelopeFloor: Float = 100 / 65536
	private var envelopeSum: (Float, Float) = (0, 0)
	private var envelopeSamples = 0
	private var envelopePackets = 0

	/// Bluetooth: no raw haptic channel, so drive rumble emulation from the signal envelope.
	/// Scaled like chiaki-ng's "Normal" haptics-to-rumble: twice the mean absolute level.
	private func pushEnvelope(_ pcm: [Int16], frames: Int) {
		for i in 0..<frames {
			envelopeSum.0 += abs(Float(pcm[2 * i]))
			envelopeSum.1 += abs(Float(pcm[2 * i + 1]))
		}
		envelopeSamples += frames
		envelopePackets += 1
		guard envelopePackets >= Self.packetsPerLevel else { return }
		let n = Float(max(envelopeSamples, 1)) * 32768
		var left = min(1, envelopeSum.0 / n * 2), right = min(1, envelopeSum.1 / n * 2)
		resetEnvelopeWindow()
		if left <= Self.envelopeFloor { left = 0 }
		if right <= Self.envelopeFloor { right = 0 }
		// The weakest level the motors actually turn at, as chiaki-ng does.
		let minimum: Float = 2 / 255
		if left > 0 { left = max(left, minimum) }
		if right > 0 { right = max(right, minimum) }
		hapticPeak = max(hapticPeak, max(left, right))
		envelope = (left, right)
		applyMotors()
	}

	private func resetEnvelopeWindow() {
		envelopeSum = (0, 0)
		envelopeSamples = 0
		envelopePackets = 0
	}

	private var lastSentRumble: (UInt8, UInt8) = (0, 0)

	private func applyMotors() {
		let left = max(rumble.0, envelope.0), right = max(rumble.1, envelope.1)
		// While USB voice-coil haptics are playing, don't send rumble reports: they switch
		// the controller from audio haptics to rumble emulation.
		if usbHaptics != nil, CACurrentMediaTime() - lastHapticFrame < 1 { return }
		guard let hid else {
			motors?.set(left: left, right: right)
			return
		}
		// Direct HID rumble: only send when the level actually changes, to keep the
		// Bluetooth link quiet. Haptic levels arrive every 30 ms at most.
		let l = UInt8(min(255, left * 255)), r = UInt8(min(255, right * 255))
		if (l, r) != lastSentRumble {
			lastSentRumble = (l, r)
			hid.setRumble(left: l, right: r)
		}
	}

	/// The console stops sending haptic frames when there's nothing to play; make sure the
	/// motors don't stay latched on the last envelope.
	private func startDecayTimer() {
		let t = DispatchSource.makeTimerSource(queue: queue)
		t.schedule(deadline: .now() + 0.05, repeating: 0.05)
		t.setEventHandler { [weak self] in
			guard let self else { return }
			keepaliveTicks += 1
			if keepaliveTicks % 100 == 0 { // every 5 s
				log.info("Haptics: \(self.hapticFrames) frames in 5 s, peak \(self.hapticPeak, format: .fixed(precision: 2)), via \(self.usbHaptics != nil ? "USB voice coils" : (self.hid != nil ? "HID rumble" : "Core Haptics"), privacy: .public)")
				hapticFrames = 0
				hapticPeak = 0
			}
			if hid == nil, reconnectAfter > 0, CACurrentMediaTime() >= reconnectAfter,
			   controller?.extendedGamepad is GCDualSenseGamepad {
				reconnectAfter = CACurrentMediaTime() + 1 // retry every second until it's back
				connectDevices()
				if hid != nil { reconnectAfter = 0 }
			}
			if usbHapticsRetryUntil > 0, keepaliveTicks % 20 == 0 { // about once a second
				retryUSBHaptics()
			}
			// Trigger effects are not re-sent on a timer: re-sending restarts vibrating effects
			// and re-arms weapon clicks mid-pull. They're re-applied on reconnect instead.
			guard usbHaptics == nil, CACurrentMediaTime() - lastHapticFrame > 0.06 else { return }
			if envelopePackets > 0 { resetEnvelopeWindow() }
			guard envelope != (0, 0) else { return }
			envelope = (0, 0)
			applyMotors()
		}
		t.resume()
		decayTimer = t
	}

	// MARK: Lightbar and player LEDs

	func setLightbar(r: UInt8, g: UInt8, b: UInt8) {
		lightbar = (r, g, b)
		applyLights()
	}

	func setMuteLight(_ on: Bool) {
		muteLight = on ? 1 : 0
		hid?.setMuteLight(muteLight)
	}

	func setPlayerIndex(_ index: UInt8) {
		// Same patterns as a PS5: centre dot for player 1, then outward pairs.
		let masks: [UInt8] = [0x04, 0x0A, 0x15, 0x1B, 0x1F]
		playerLEDs = index >= 1 ? masks[min(Int(index) - 1, masks.count - 1)] : 0x04
		applyLights()
	}

	private func applyLights() {
		if let hid {
			hid.setLights(r: lightbar.0, g: lightbar.1, b: lightbar.2, playerLEDs: playerLEDs)
		} else if let light = controller?.light {
			let (r, g, b) = lightbar
			DispatchQueue.main.async { light.color = GCColor(red: Float(r) / 255, green: Float(g) / 255, blue: Float(b) / 255) }
		}
	}

	// MARK: Adaptive triggers

	/// `rawLeft`/`rawRight` are the console's 11-byte effect blocks (type + 10 params), sent
	/// verbatim over HID; the decoded forms are only used for the GameController fallback.
	func setTriggerEffects(rawLeft: [UInt8], rawRight: [UInt8], left: TriggerEffect?, right: TriggerEffect?) {
		rawTriggers = (rawLeft, rawRight)
		if let left { lastTriggers.left = left }
		if let right { lastTriggers.right = right }
		applyTriggers()
	}

	private func applyTriggers() {
		if let hid {
			hid.setTriggers(left: rawTriggers.left, right: rawTriggers.right)
			return
		}
		guard let pad = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
		let (left, right) = lastTriggers
		// GameController's output (light, triggers) is driven from the main thread.
		DispatchQueue.main.async {
			left.apply(to: pad.leftTrigger)
			right.apply(to: pad.rightTrigger)
		}
	}

	/// Always release the triggers when leaving a session, or they stay stiff on the desktop.
	private func resetTriggers() {
		if let hid {
			hid.setTriggers(left: Self.rawOff, right: Self.rawOff)
		}
		guard let pad = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
		DispatchQueue.main.async {
			pad.leftTrigger.setModeOff()
			pad.rightTrigger.setModeOff()
		}
	}
}

// MARK: - Trigger effects

/// A decoded DualSense adaptive-trigger effect, as sent by the console.
///
/// Byte layouts follow the DualSense output report's trigger effect blocks: 0x21/0x25/0x26
/// etc. use a 10-bit zone mask and 3-bit per-zone values; 0x01/0x02/0x06 are the older
/// "simple" forms with byte positions. Effects GameController can't express exactly
/// (bow, galloping, machine) are approximated with the closest mode.
enum TriggerEffect: Equatable {
	case off
	case feedback(strengths: [Float])               // 10 zones, 0...1
	case weapon(start: Float, end: Float, strength: Float)
	case vibration(amplitudes: [Float], frequency: Float)

	init?(type: UInt8, params p: [UInt8]) {
		guard p.count >= 10 else { return nil }
		let mask = UInt16(p[0]) | UInt16(p[1]) << 8
		let packed = UInt32(p[2]) | UInt32(p[3]) << 8 | UInt32(p[4]) << 16 | UInt32(p[5]) << 24
		func zone3(_ i: Int) -> Float { (Float((packed >> (3 * UInt32(i))) & 7) + 1) / 8 }
		func active(_ i: Int) -> Bool { mask & (1 << i) != 0 }
		var bounds: (Float, Float)? {
			let bits = (0..<10).filter(active)
			guard let lo = bits.first, let hi = bits.last else { return nil }
			return (Float(lo) / 9, Float(hi) / 9)
		}
		func zonesFrom(_ start: Float, value: Float) -> [Float] {
			(0..<10).map { Float($0) / 9 >= start ? value : 0 }
		}

		switch type {
		case 0x00, 0x05:
			self = .off
		case 0x01: // simple feedback: start, strength
			self = .feedback(strengths: zonesFrom(Float(p[0]) / 255, value: Float(p[1]) / 255))
		case 0x02: // simple weapon: start, end, strength
			self = .weapon(start: Float(p[0]) / 255, end: Float(p[1]) / 255, strength: Float(p[2]) / 255)
		case 0x06: // simple vibration: frequency, amplitude, start
			self = .vibration(amplitudes: zonesFrom(Float(p[2]) / 255, value: Float(p[1]) / 255), frequency: Float(p[0]) / 255)
		case 0x21: // feedback: per-zone strength
			self = .feedback(strengths: (0..<10).map { active($0) ? zone3($0) : 0 })
		case 0x25: // weapon: start/end zones, strength
			guard let (start, end) = bounds else { self = .off; return }
			self = .weapon(start: start, end: end, strength: (Float(p[2] & 7) + 1) / 8)
		case 0x22: // bow: start/end zones, strength + snap force → weapon
			guard let (start, end) = bounds else { self = .off; return }
			self = .weapon(start: start, end: end, strength: (Float(p[2] & 7) + 1) / 8)
		case 0x26: // vibration: per-zone amplitude, frequency in Hz
			self = .vibration(amplitudes: (0..<10).map { active($0) ? zone3($0) : 0 }, frequency: Float(p[8]) / 255)
		case 0x23: // galloping: start/end zones, feet timing, frequency → vibration
			guard let (start, end) = bounds else { self = .off; return }
			self = .vibration(amplitudes: (0..<10).map { (start...end).contains(Float($0) / 9) ? 0.6 : 0 },
							  frequency: Float(p[3]) / 255)
		case 0x27: // machine: start/end zones, two amplitudes, frequency → vibration
			guard let (start, end) = bounds else { self = .off; return }
			let amp = (Float(max(p[2] & 7, (p[2] >> 3) & 7)) + 1) / 8
			self = .vibration(amplitudes: (0..<10).map { (start...end).contains(Float($0) / 9) ? amp : 0 },
							  frequency: Float(p[3]) / 255)
		default:
			return nil
		}
	}

	func apply(to trigger: GCDualSenseAdaptiveTrigger) {
		switch self {
		case .off:
			trigger.setModeOff()
		case .feedback(let s):
			var v = GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths()
			withUnsafeMutableBytes(of: &v.values) { raw in
				let f = raw.bindMemory(to: Float.self)
				for i in 0..<min(10, f.count) { f[i] = s[i] }
			}
			trigger.setModeFeedback(resistiveStrengths: v)
		case .weapon(let start, let end, let strength):
			trigger.setModeWeaponWithStartPosition(start, endPosition: max(end, start), resistiveStrength: strength)
		case .vibration(let a, let frequency):
			var v = GCDualSenseAdaptiveTrigger.PositionalAmplitudes()
			withUnsafeMutableBytes(of: &v.values) { raw in
				let f = raw.bindMemory(to: Float.self)
				for i in 0..<min(10, f.count) { f[i] = a[i] }
			}
			trigger.setModeVibration(amplitudes: v, frequency: frequency)
		}
	}
}

// MARK: - Core Haptics motors (rumble, and haptics over Bluetooth)

final class HapticMotors {
	private var engines: [HapticChannel] = []

	init?(controller: GCController) {
		guard let haptics = controller.haptics else { return nil }
		for locality in [GCHapticsLocality.leftHandle, .rightHandle] {
			if let e = HapticChannel(haptics: haptics, locality: locality) { engines.append(e) }
		}
		if engines.isEmpty { return nil }
	}

	func set(left: Float, right: Float) {
		if engines.count >= 2 {
			engines[0].set(intensity: left)
			engines[1].set(intensity: right)
		} else {
			engines.first?.set(intensity: max(left, right))
		}
	}

	func stop() { engines.forEach { $0.stop() } }
}

final class HapticChannel {
	private let engine: CHHapticEngine
	private var player: CHHapticAdvancedPatternPlayer?
	private var current: Float = 0

	init?(haptics: GCDeviceHaptics, locality: GCHapticsLocality) {
		guard let engine = haptics.createEngine(withLocality: locality) else { return nil }
		self.engine = engine
		engine.isAutoShutdownEnabled = false
		try? engine.start()
	}

	func set(intensity: Float) {
		guard abs(intensity - current) > 0.01 else { return }
		current = intensity
		do {
			if intensity <= 0.01 {
				try player?.stop(atTime: CHHapticTimeImmediate)
				player = nil
				return
			}
			if player == nil {
				let event = CHHapticEvent(eventType: .hapticContinuous,
										  parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1)],
										  relativeTime: 0, duration: 30)
				let pattern = try CHHapticPattern(events: [event], parameters: [])
				player = try engine.makeAdvancedPlayer(with: pattern)
				player?.loopEnabled = true
				try player?.start(atTime: CHHapticTimeImmediate)
			}
			let p = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0)
			try player?.sendParameters([p], atTime: CHHapticTimeImmediate)
		} catch {
			player = nil
		}
	}

	func stop() {
		try? player?.stop(atTime: CHHapticTimeImmediate)
		engine.stop()
	}
}

// MARK: - USB voice-coil haptics

/// Over USB the DualSense exposes a 4-channel 48 kHz audio device; channels 3 and 4 drive
/// the left and right voice coils directly. Playing the console's haptic PCM there gives the
/// same feel as on a PS5. Haptics arrive at 3 kHz and are upsampled 16x here.
final class DualSenseUSBHaptics: @unchecked Sendable {
	private let engine = AVAudioEngine()
	private let ring = StereoFloatRing(capacity: 48_000 / 10) // 100 ms
	private var lastSample: (Float, Float) = (0, 0)
	private let log = Logger(subsystem: "Couchwire", category: "Feedback")

	static func makeIfConnected() -> DualSenseUSBHaptics? {
		guard let device = findDualSenseAudioDevice() else { return nil }
		let h = DualSenseUSBHaptics()
		return h.start(device: device) ? h : nil
	}

	private func start(device: AudioDeviceID) -> Bool {
		guard let unit = engine.outputNode.audioUnit else { return false }
		var id = device
		let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
									   &id, UInt32(MemoryLayout<AudioDeviceID>.size))
		guard err == noErr else {
			log.error("Couldn't select DualSense audio device: \(err)")
			return false
		}
		let hw = engine.outputNode.outputFormat(forBus: 0)
		guard hw.channelCount >= 4 else {
			log.error("DualSense audio device has \(hw.channelCount) channels; expected 4")
			return false
		}
		// More than two channels needs an explicit layout; use discrete channels in order so
		// channel 3/4 map straight to the left/right voice coils.
		guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(hw.channelCount)) else {
			log.error("Couldn't build a \(hw.channelCount)-channel layout")
			return false
		}
		let format = AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate, channelLayout: layout)
		let ring = ring
		let source = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
			let buffers = UnsafeMutableAudioBufferListPointer(abl)
			for b in buffers { memset(b.mData, 0, Int(b.mDataByteSize)) }
			guard buffers.count >= 4 else { return noErr }
			ring.read(left: buffers[2].mData!.assumingMemoryBound(to: Float.self),
					  right: buffers[3].mData!.assumingMemoryBound(to: Float.self),
					  frames: Int(frameCount))
			return noErr
		}
		engine.attach(source)
		engine.connect(source, to: engine.outputNode, format: format)
		do {
			try engine.start()
			return true
		} catch {
			log.error("DualSense haptics engine failed: \(error.localizedDescription)")
			return false
		}
	}

	/// 3 kHz stereo Int16 → 48 kHz stereo Float, linear interpolation.
	func push(_ pcm: UnsafeBufferPointer<Int16>, frames: Int) {
		let factor = 16
		var out = [Float](repeating: 0, count: frames * factor * 2)
		var prev = lastSample
		for i in 0..<frames {
			let l = Float(pcm[2 * i]) / 32768, r = Float(pcm[2 * i + 1]) / 32768
			for k in 0..<factor {
				let t = Float(k + 1) / Float(factor)
				out[(i * factor + k) * 2] = prev.0 + (l - prev.0) * t
				out[(i * factor + k) * 2 + 1] = prev.1 + (r - prev.1) * t
			}
			prev = (l, r)
		}
		lastSample = prev
		out.withUnsafeBufferPointer { ring.write($0) }
	}

	func stop() {
		engine.stop()
	}

	private static func findDualSenseAudioDevice() -> AudioDeviceID? {
		var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
											  mScope: kAudioObjectPropertyScopeGlobal,
											  mElement: kAudioObjectPropertyElementMain)
		var size: UInt32 = 0
		guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
		var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
		guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }

		for id in ids {
			var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
													  mScope: kAudioObjectPropertyScopeGlobal,
													  mElement: kAudioObjectPropertyElementMain)
			var name: Unmanaged<CFString>?
			var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
			guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name) == noErr,
				  let cf = name?.takeRetainedValue() else { continue }
			let deviceName = cf as String
			guard deviceName.contains("DualSense") || deviceName.contains("Wireless Controller") else { continue }
			if outputChannels(id) >= 4 { return id }
		}
		return nil
	}

	private static func outputChannels(_ id: AudioDeviceID) -> Int {
		var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
											  mScope: kAudioDevicePropertyScopeOutput,
											  mElement: kAudioObjectPropertyElementMain)
		var size: UInt32 = 0
		guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
		let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
		defer { raw.deallocate() }
		guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
		let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
		return list.reduce(0) { $0 + Int($1.mNumberChannels) }
	}
}

/// SPSC stereo float ring with a small fixed latency target (~10 ms) for the voice coils.
/// Lock-free, like `PCMRingBuffer`: the real-time reader never waits on the writer.
final class StereoFloatRing: @unchecked Sendable {
	private let storage: UnsafeMutablePointer<Float>
	private let capacity: Int // in floats (2 per frame)
	/// Floats ever written (stored by the writer only) and ever read (by the reader only).
	private let shared: UnsafeMutablePointer<Int64>
	private var primed = false // reader only
	private let target = 480 * 2 // 10 ms at 48 kHz

	init(capacity frames: Int) {
		capacity = frames * 2
		storage = .allocate(capacity: capacity)
		storage.initialize(repeating: 0, count: capacity)
		shared = .allocate(capacity: 2)
		shared.initialize(repeating: 0, count: 2)
	}

	deinit {
		storage.deallocate()
		shared.deallocate()
	}

	/// If the ring is full the newest frames are dropped; the reader catches up by skipping.
	func write(_ samples: UnsafeBufferPointer<Float>) {
		let written = Int(shared[0])
		let count = written - Int(cw_atomic_load(shared + 1))
		let n = min(samples.count, capacity - count) & ~1 // whole frames
		guard n > 0 else { return }
		for i in 0..<n { storage[(written + i) % capacity] = samples[i] }
		cw_atomic_store(shared, Int64(written + n))
	}

	func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
		var readIndex = Int(shared[1])
		var count = Int(cw_atomic_load(shared)) - readIndex
		if count > target * 4 { // stay live: drop to target if we fell behind
			let drop = (count - target) & ~1
			readIndex += drop
			count -= drop
		}
		if !primed && count >= target { primed = true }
		let cap = capacity
		for i in 0..<frames {
			if primed && count >= 2 {
				left[i] = storage[readIndex % cap]
				right[i] = storage[(readIndex + 1) % cap]
				readIndex += 2
				count -= 2
			} else {
				primed = false
				left[i] = 0
				right[i] = 0
			}
		}
		cw_atomic_store(shared + 1, Int64(readIndex))
	}
}
