import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import SwitchCore

private struct PreviewCacheEntry {
    let image: CGImage
    let cost: Int
    var used: UInt64
}

@MainActor final class PreviewService {
    private var cache: [WindowKey: PreviewCacheEntry] = [:] // main thread only
    private var clock: UInt64 = 0
    private(set) var cacheBytes = 0
    private var epoch = CaptureEpoch()
    private var captureTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var stream: SCStream?
    private var sink: PreviewSink?
    private var shareable: [CGWindowID: SCWindow] = [:]
    private var selected: WindowRecord?
    private var preferences = Preferences()
    private var dimensions = CGSize(width: 500, height: 300)
    private var onImage: ((WindowKey, CGImage?, String?) -> Void)?

    func cached(_ key: WindowKey) -> CGImage? {
        guard var entry = cache[key] else { return nil }
        clock += 1; entry.used = clock; cache[key] = entry
        return entry.image
    }

    func configure(_ preferences: Preferences) {
        self.preferences = preferences
        evict()
    }

    func prune(keeping keys: Set<WindowKey>) {
        for key in Array(cache.keys) where !keys.contains(key) {
            if let entry = cache.removeValue(forKey: key) { cacheBytes -= entry.cost }
        }
    }

    func clearCache() { cache.removeAll(); cacheBytes = 0 }

    private func store(_ image: CGImage, for key: WindowKey) {
        if let old = cache.removeValue(forKey: key) { cacheBytes -= old.cost }
        clock += 1
        let entry = PreviewCacheEntry(image: image, cost: image.bytesPerRow * image.height, used: clock)
        cache[key] = entry; cacheBytes += entry.cost
        evict()
    }

    private func evict() {
        let maximum = preferences.cacheMegabytes * 1_024 * 1_024
        while cacheBytes > maximum, let oldest = cache.min(by: { $0.value.used < $1.value.used }) {
            cacheBytes -= oldest.value.cost; cache.removeValue(forKey: oldest.key)
        }
    }

    func begin(records: [WindowRecord], selected: WindowRecord?, preferences: Preferences,
               pixelSize: CGSize, onImage: @escaping (WindowKey, CGImage?, String?) -> Void) {
        stop()
        self.preferences = preferences; self.dimensions = pixelSize
        self.selected = selected; self.onImage = onImage
        epoch.begin()
        refresh(records)
    }

    /// Called for a new visible page as well as the first invocation. At most
    /// two one-shot captures run concurrently, regardless of total window count.
    func refresh(_ records: [WindowRecord]) {
        captureTask?.cancel()
        guard epoch.active else { return }
        let session = epoch.session
        guard CGPreflightScreenCaptureAccess() else {
            records.forEach { onImage?($0.key, nil, "需要屏幕录制权限") }; return
        }
        for record in records where record.minimized { onImage?(record.key, cached(record.key), "最小化 · 上次快照") }
        let candidates = records.filter { !$0.minimized && $0.windowID != nil }.sorted { $0.key == selected?.key && $1.key != selected?.key }
        let size = dimensions
        captureTask = Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard !Task.isCancelled, let self, self.epoch.accepts(session: session) else { return }
                self.shareable = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
                self.startLive()
                let windowsByID = self.shareable
                await withTaskGroup(of: (WindowKey, CGImage?).self) { group in
                    var index = 0
                    func addNext() {
                        guard index < candidates.count, !Task.isCancelled else { return }
                        let record = candidates[index]; index += 1
                        let window = record.windowID.flatMap { windowsByID[$0] }
                        group.addTask {
                            guard let window, !Task.isCancelled else { return (record.key, nil) }
                            let image = try? await PreviewService.capture(window: window, size: size)
                            return (record.key, image)
                        }
                    }
                    addNext(); addNext()
                    for await (key, image) in group {
                        guard !Task.isCancelled, self.epoch.accepts(session: session) else { group.cancelAll(); continue }
                        if let image { self.store(image, for: key) }
                        self.onImage?(key, image, image == nil ? "预览暂不可用" : nil)
                        addNext()
                    }
                }
                guard !Task.isCancelled, self.epoch.accepts(session: session) else { return }
                for record in records where !record.minimized && record.windowID == nil {
                    self.onImage?(record.key, nil, "预览暂不可用")
                }
            } catch {
                guard !Task.isCancelled, let self, self.epoch.accepts(session: session) else { return }
                records.forEach { self.onImage?($0.key, nil, "预览刷新失败") }
            }
        }
    }

    func select(_ record: WindowRecord?) {
        guard selected?.key != record?.key else { return }
        selected = record; epoch.select()
        startLive()
    }

    nonisolated private static func configuration(window: SCWindow, size: CGSize, fps: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let fitted = PreviewGeometry.outputSize(window: window.frame.size, limit: size)
        config.width = Int(fitted.width)
        config.height = Int(fitted.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false; config.capturesAudio = false
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.ignoreShadowsSingleWindow = true
        return config
    }

    nonisolated private static func capture(window: SCWindow, size: CGSize) async throws -> CGImage {
        let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration(window: window, size: size, fps: 1))
        guard let image = PreviewBitmap.image(from: sample) else { throw CocoaError(.coderInvalidValue) }
        return image
    }

    private func startLive() {
        liveTask?.cancel()
        let old = stream; stream = nil; sink = nil
        if let old { Task { try? await old.stopCapture() } }
        guard epoch.active, preferences.livePreview, let record = selected, !record.minimized,
              let id = record.windowID, let window = shareable[id] else { return }
        let session = epoch.session, selection = epoch.selection
        let config = Self.configuration(window: window, size: dimensions, fps: preferences.previewFPS)
        liveTask = Task { [weak self] in
            let sink = PreviewSink { [weak self] image in
                DispatchQueue.main.async {
                    guard let self, self.epoch.accepts(session: session, selection: selection) else { return }
                    self.store(image, for: record.key); self.onImage?(record.key, image, nil)
                }
            }
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: sink)
            do {
                try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
                guard !Task.isCancelled else { return }
                try await stream.startCapture()
                guard !Task.isCancelled, let self, self.epoch.accepts(session: session, selection: selection) else {
                    try? await stream.stopCapture(); return
                }
                self.sink = sink; self.stream = stream
            } catch {
                // A valid fresh one-shot preview remains usable if live
                // capture is unsupported by this particular window.
            }
        }
    }

    func stop() {
        epoch.end(); captureTask?.cancel(); captureTask = nil
        liveTask?.cancel(); liveTask = nil; selected = nil; shareable.removeAll(); onImage = nil
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil; sink = nil
    }
}

private final class PreviewSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "com.que.NativeSwitch.frames", qos: .userInitiated)
    let onFrame: (CGImage) -> Void
    init(onFrame: @escaping (CGImage) -> Void) { self.onFrame = onFrame }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let metadata = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let status = metadata[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let image = PreviewBitmap.image(from: sampleBuffer) else { return }
        onFrame(image)
    }
}

/// One-shot and live captures share the exact same crop. A tall snapped
/// window must not carry ScreenCaptureKit's top-left-aligned output padding
/// into NSImageView, which would make it look like a left-hand window.
enum PreviewBitmap {
    static func image(from sampleBuffer: CMSampleBuffer) -> CGImage? {
        guard sampleBuffer.isValid, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        // Copy a thumbnail out of the three-frame IOSurface pool immediately;
        // retaining capture buffers in the cache would otherwise stall it.
        let bytes = Data(bytes: address, count: stride * height)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let metadata = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        if let dictionary = metadata?[.contentRect] as? [String: Any],
           let content = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
           let crop = PreviewGeometry.cropRect(content: content,
               scaleFactor: CGFloat((metadata?[.scaleFactor] as? NSNumber)?.doubleValue ?? 1),
               surface: CGSize(width: width, height: height)) {
            return image.cropping(to: crop) ?? image
        }
        return image
    }
}
