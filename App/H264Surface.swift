import UIKit
import AVFoundation

/// Receives complete Annex-B access units; transport decryption/demux precedes this layer.
final class H264Surface: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var display: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var pending: [(CMSampleBuffer, Int)] = []
    private var pendingBytes = 0
    private var requesting = false
    private var awaitingKeyframe = false
    var onLog: ((String) -> Void)?
    var onTouch: ((CGPoint, Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .black; display.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func reset() {
        display.stopRequestingMediaData(); requesting = false
        pending.removeAll(); pendingBytes = 0; awaitingKeyframe = false
        display.flushAndRemoveImage(); format = nil; sps = nil; pps = nil
    }
    func enqueue(accessUnit: Data) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        let units = try AnnexB.units(in: accessUnit)
        var picture: [Data] = []
        var changed = false
        for unit in units {
            switch unit.first! & 0x1f {
            case 7: if sps != unit { sps = unit; changed = true }
            case 8: if pps != unit { pps = unit; changed = true }
            default: picture.append(unit)
            }
        }
        if changed || format == nil, let sps, let pps {
            var newFormat: CMVideoFormatDescription?
            let status = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
            } }
            guard status == noErr else { throw ProtocolError.malformed("H.264 parameters (\(status))") }
            display.stopRequestingMediaData(); requesting = false
            pending.removeAll(); pendingBytes = 0
            display.flush(); format = newFormat
        }
        guard !picture.isEmpty else { return }
        guard let format else { throw ProtocolError.malformed("H.264 frame arrived before SPS/PPS") }
        let keyframe = picture.contains { ($0.first! & 0x1f) == 5 }
        if display.status == .failed || pending.count >= 60 || pendingBytes > 16 * 1024 * 1024 {
            display.stopRequestingMediaData(); requesting = false
            pending.removeAll(); pendingBytes = 0; display.flush(); awaitingKeyframe = true
            onLog?("Video renderer recovering at next keyframe")
        }
        if awaitingKeyframe {
            guard keyframe else { return }
            awaitingKeyframe = false
        }
        let bytes = try AnnexB.lengthPrefixed(picture)
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw ProtocolError.malformed("video buffer allocation") }
        status = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
        guard status == noErr else { throw ProtocolError.malformed("video buffer copy") }
        var sample: CMSampleBuffer?
        var size = bytes.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw ProtocolError.malformed("video sample construction") }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        pending.append((sample, bytes.count)); pendingBytes += bytes.count
        // Retain dependent compressed frames until the decoder is ready. Dropping
        // an arbitrary P-frame corrupts every dependent frame up to the next IDR.
        if !requesting {
            requesting = true
            display.requestMediaDataWhenReady(on: .main) { [weak self] in self?.drain() }
        }
    }
    private func drain() {
        while display.isReadyForMoreMediaData, !pending.isEmpty {
            let (sample, bytes) = pending.removeFirst(); pendingBytes -= bytes
            display.enqueue(sample)
        }
        if pending.isEmpty {
            display.stopRequestingMediaData(); requesting = false
        }
    }
    private func send(_ touches: Set<UITouch>, down: Bool) {
        guard let touch = touches.first, let format else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
        let rect = AVMakeRect(aspectRatio: size, insideRect: bounds)
        guard rect.width > 0, rect.height > 0 else { return }
        let point = touch.location(in: self)
        let x = min(max((point.x - rect.minX) / rect.width, 0), 1) * max(size.width - 1, 0)
        let y = min(max((point.y - rect.minY) / rect.height, 0), 1) * max(size.height - 1, 0)
        onTouch?(CGPoint(x: x, y: y), down)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, down: true) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, down: true) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, down: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, down: false) }
}
