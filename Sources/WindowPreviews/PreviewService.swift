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

public struct SnapshotWindow {
    public let key: WindowKey
    public let windowID: CGWindowID?
    public let minimized: Bool
    public init(key: WindowKey, windowID: CGWindowID?, minimized: Bool = false) {
        self.key = key; self.windowID = windowID; self.minimized = minimized
    }
}

public protocol SnapshotCapturing {
    func image(for record: SnapshotWindow, session: UInt64, size: CGSize) async throws -> CGImage
}

/// No SCStream is created. The system's single-frame API performs one
/// screenshot per request; window enumeration is shared by the invocation.
private actor ScreenshotSource: SnapshotCapturing {
    private var session: UInt64?
    private var windows: [CGWindowID: SCWindow] = [:]

    func image(for record: SnapshotWindow, session: UInt64, size: CGSize) async throws -> CGImage {
        if self.session != session {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
            self.session = session
        }
        guard let id = record.windowID, let window = windows[id] else { throw CocoaError(.fileNoSuchFile) }
        return try await Self.capture(window: window, size: size)
    }

    nonisolated private static func capture(window: SCWindow, size: CGSize) async throws -> CGImage {
        let config = SCStreamConfiguration()
        let fitted = PreviewGeometry.outputSize(window: window.frame.size, limit: size)
        config.width = Int(fitted.width); config.height = Int(fitted.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false; config.capturesAudio = false
        config.scalesToFit = true; config.preservesAspectRatio = true
        config.ignoreShadowsSingleWindow = true
        let sample = try await SCScreenshotManager.captureSampleBuffer(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        guard let image = PreviewBitmap.image(from: sample) else { throw CocoaError(.coderInvalidValue) }
        return image
    }
}

@MainActor public final class PreviewService {
    private var cache: [WindowKey: PreviewCacheEntry] = [:]
    private var clock: UInt64 = 0
    public private(set) var cacheBytes = 0
    private var epoch = CaptureEpoch()
    private var plan = SnapshotPlan()
    private var worker: Task<Void, Never>?
    private let source: SnapshotCapturing
    private let hasPermission: () -> Bool
    private var records: [WindowKey: SnapshotWindow] = [:]
    private var preferences = Preferences()
    private var dimensions = CGSize(width: 500, height: 300)
    private var onImage: ((WindowKey, CGImage?, String?) -> Void)?

    public init(source: SnapshotCapturing? = nil, hasPermission: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.source = source ?? ScreenshotSource()
        self.hasPermission = hasPermission
    }

    public func cached(_ key: WindowKey) -> CGImage? {
        guard var entry = cache[key] else { return nil }
        clock += 1; entry.used = clock; cache[key] = entry
        return entry.image
    }

    public func configure(_ preferences: Preferences) { self.preferences = preferences; evict() }

    public func prune(keeping keys: Set<WindowKey>) {
        for key in Array(cache.keys) where !keys.contains(key) {
            if let entry = cache.removeValue(forKey: key) { cacheBytes -= entry.cost }
        }
    }

    public func clearCache() { cache.removeAll(); cacheBytes = 0 }

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

    public func begin(records: [SnapshotWindow], selected: SnapshotWindow?, preferences: Preferences,
               pixelSize: CGSize, onImage: @escaping (WindowKey, CGImage?, String?) -> Void) {
        stop()
        self.preferences = preferences; self.dimensions = pixelSize; self.onImage = onImage
        epoch.begin(); plan.begin()
        updateVisible(records, selected: selected)
    }

    public func updateVisible(_ visible: [SnapshotWindow], selected: SnapshotWindow?) {
        guard epoch.active else { return }
        records = Dictionary(visible.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        guard hasPermission() else {
            plan.update(visible: [], selected: nil)
            visible.forEach { onImage?($0.key, nil, "需要屏幕录制权限") }; return
        }
        for record in visible where record.minimized { onImage?(record.key, cached(record.key), "最小化 · 上次快照") }
        for record in visible where !record.minimized && record.windowID == nil { onImage?(record.key, nil, "预览暂不可用") }
        plan.update(visible: visible.filter { !$0.minimized && $0.windowID != nil }.map(\.key), selected: selected?.key)
        startWorker()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            // A single worker survives session changes until an outstanding
            // system call returns. Cancelling an async screenshot doesn't
            // guarantee the OS stops it; starting another task could overlap it.
            while self.epoch.active, let key = self.plan.next() {
                guard let record = self.records[key] else { continue }
                let session = self.epoch.session, size = self.dimensions
                let image = try? await self.source.image(for: record, session: session, size: size)
                guard self.epoch.accepts(session: session) else { continue }
                if let image { self.store(image, for: key) }
                self.onImage?(key, image, image == nil ? "预览暂不可用" : nil)
            }
            self.worker = nil
        }
    }

    public func stop() {
        epoch.end(); plan.end(); records.removeAll(); onImage = nil
        // Already submitted screenshots may finish, but their results are
        // rejected and no new requests are made after release/Escape.
    }
}

/// Crop a one-shot capture to its actual content, preserving centered
/// previews for snapped and portrait windows.
public enum PreviewBitmap {
    public static func image(from sampleBuffer: CMSampleBuffer) -> CGImage? {
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
