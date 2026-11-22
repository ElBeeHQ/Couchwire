import AVFoundation
import CoreMedia
import os

/// Turns libchiaki's Annex-B access units into `CMSampleBuffer`s and feeds them to an
/// `AVSampleBufferDisplayLayer`, which hardware-decodes (VideoToolbox) and presents them
/// with no extra buffering. This is the lowest-latency native path on macOS.
final class VideoDecoder: @unchecked Sendable {
	enum Codec { case h264, hevc }

	private let codec: Codec
	private let renderer: AVSampleBufferVideoRenderer
	private var formatDescription: CMVideoFormatDescription?
	private var parameterSets: [UInt8: Data] = [:] // keyed by NAL type
	private let log = Logger(subsystem: "PSStream", category: "Video")
	/// Called when the decoder needs a fresh keyframe (e.g. after a decode failure).
	var requestKeyframe: (() -> Void)?

	init(codec: Codec, renderer: AVSampleBufferVideoRenderer) {
		self.codec = codec
		self.renderer = renderer
	}

	/// Called on libchiaki's receive thread. Returns false to signal a corrupt frame.
	func decode(_ data: UnsafeBufferPointer<UInt8>) -> Bool {
		if renderer.status == .failed {
			log.error("Renderer failed: \(String(describing: self.renderer.error)); flushing")
			renderer.flush()
			requestKeyframe?()
			return false
		}

		let nalus = Self.splitAnnexB(data)
		var payload = Data()
		var sawParameterSet = false
		var isKeyframe = false

		for nalu in nalus where !nalu.isEmpty {
			let type = nalType(nalu.first!)
			switch (codec, type) {
			case (.h264, 7), (.h264, 8), (.hevc, 32), (.hevc, 33), (.hevc, 34):
				if parameterSets[type] != nalu {
					parameterSets[type] = nalu
					sawParameterSet = true
				}
			default:
				if (codec == .h264 && type == 5) || (codec == .hevc && (16...21).contains(type)) {
					isKeyframe = true
				}
				// AVCC/HVCC framing: 4-byte big-endian length prefix.
				var len = UInt32(nalu.count).bigEndian
				payload.append(Data(bytes: &len, count: 4))
				payload.append(nalu)
			}
		}

		if sawParameterSet || formatDescription == nil {
			formatDescription = makeFormatDescription()
		}
		guard let formatDescription, !payload.isEmpty else { return true }

		guard let sample = makeSampleBuffer(payload, format: formatDescription, keyframe: isKeyframe) else {
			return false
		}
		renderer.enqueue(sample)
		return true
	}

	func reset() {
		renderer.flush()
		formatDescription = nil
		parameterSets.removeAll()
	}

	// MARK: - Private

	private func nalType(_ header: UInt8) -> UInt8 {
		codec == .h264 ? header & 0x1F : (header >> 1) & 0x3F
	}

	private func makeFormatDescription() -> CMVideoFormatDescription? {
		let required: [UInt8] = codec == .h264 ? [7, 8] : [32, 33, 34]
		let sets = required.compactMap { parameterSets[$0] }
		guard sets.count == required.count else { return nil }

		var desc: CMVideoFormatDescription?
		let status: OSStatus = withPointers(sets) { pointers, sizes in
			if codec == .h264 {
				return CMVideoFormatDescriptionCreateFromH264ParameterSets(
					allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
					parameterSetPointers: pointers, parameterSetSizes: sizes,
					nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
			} else {
				return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
					allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
					parameterSetPointers: pointers, parameterSetSizes: sizes,
					nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
			}
		}
		if status != noErr {
			log.error("Failed to create format description: \(status)")
			return nil
		}
		if let desc {
			let dims = CMVideoFormatDescriptionGetDimensions(desc)
			log.info("Video format: \(dims.width)x\(dims.height)")
		}
		return desc
	}

	private func makeSampleBuffer(_ payload: Data, format: CMVideoFormatDescription, keyframe: Bool) -> CMSampleBuffer? {
		var block: CMBlockBuffer?
		let length = payload.count
		guard CMBlockBufferCreateWithMemoryBlock(
			allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
			blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
			dataLength: length, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
		let copied = payload.withUnsafeBytes { raw in
			CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
		}
		guard copied == noErr else { return nil }

		var sample: CMSampleBuffer?
		var sampleSize = length
		var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
		guard CMSampleBufferCreateReady(
			allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
			sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
			sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr,
			let sample else { return nil }

		if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
		   CFArrayGetCount(attachments) > 0 {
			let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
			// Present as soon as decoded: we are a live stream, never buffer.
			CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
								 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
			if !keyframe {
				CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
									 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
			}
		}
		return sample
	}

	/// Splits an Annex-B byte stream on 3- or 4-byte start codes.
	static func splitAnnexB(_ buf: UnsafeBufferPointer<UInt8>) -> [Data] {
		var result: [Data] = []
		let n = buf.count
		var i = 0
		var start = -1
		while i + 2 < n {
			if buf[i] == 0, buf[i + 1] == 0, buf[i + 2] == 1 {
				if start >= 0 {
					var end = i
					if end > start, buf[end - 1] == 0 { end -= 1 } // 4-byte start code
					result.append(Data(buf[start..<end]))
				}
				i += 3
				start = i
			} else {
				i += 1
			}
		}
		if start >= 0, start < n {
			result.append(Data(buf[start..<n]))
		}
		return result
	}
}

private func withPointers<R>(_ sets: [Data], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
	let sizes = sets.map(\.count)
	let buffers = sets.map { data -> UnsafeMutablePointer<UInt8> in
		let p = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
		data.copyBytes(to: p, count: data.count)
		return p
	}
	defer { buffers.forEach { $0.deallocate() } }
	let pointers = buffers.map { UnsafePointer($0) }
	return pointers.withUnsafeBufferPointer { pp in
		sizes.withUnsafeBufferPointer { sp in body(pp.baseAddress!, sp.baseAddress!) }
	}
}
