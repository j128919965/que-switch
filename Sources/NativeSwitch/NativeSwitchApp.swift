import AppKit
import SwiftUI
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import SwitchCore
import WindowPreviews

@main struct NativeSwitchApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--display-status") {
            for display in DisplayContext.current() { print("\(display.id): \(display.name), \(display.geometry.frame)") }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-settings"), CommandLine.arguments.count > index + 1 {
            app.setActivationPolicy(.prohibited)
            let tab = CommandLine.arguments.count > index + 2 ? CommandLine.arguments[index + 2] : "general"
            do { try DemoRenderer.renderSettings(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), tab: tab) }
            catch { fputs("Render failed: \(error)\n", stderr); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-demo"), CommandLine.arguments.count > index + 1 {
            app.setActivationPolicy(.prohibited)
            do { try DemoRenderer.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { fputs("Render failed: \(error)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--permissions-status") {
            print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted")")
            print("Screen recording: \(CGPreflightScreenCaptureAccess() ? "granted" : "not granted")")
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor private enum DemoRenderer {
    static func render(to url: URL) throws {
        var preferences = Preferences(); preferences.appearance = CommandLine.arguments.contains("--light") ? .light : .dark; preferences.columns = 3
        preferences.useBlur = false; preferences.cardWidth = 250
        let examples = [
            ("com.microsoft.VSCode", "Visual Studio Code", "WindowSwitcher — main.swift"),
            ("com.apple.Safari", "Safari", "ScreenCaptureKit — Apple Developer"),
            ("com.apple.finder", "Finder", "项目"),
            ("com.apple.Terminal", "Terminal", "WindowSwitcher — zsh"),
            ("com.apple.Notes", "备忘录", "切换器交互草案"),
            ("com.apple.Safari", "Safari", "周末旅行计划")
        ]
        let records = examples.enumerated().map { index, example -> WindowRecord in
            let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: example.0).map { NSWorkspace.shared.icon(forFile: $0.path) }
            return WindowRecord(key: WindowKey(pid: 0, token: String(index)), windowID: nil, pid: 0,
                appName: example.1, bundleID: example.0, title: example.2, frame: .zero,
                minimized: index == 5, hidden: false, onDesktop: true, accessibilityElement: nil, icon: icon)
        }
        var previews: [WindowKey: PreviewPresentation] = [:]
        for (index, record) in records.enumerated() {
            let image = NSImage(size: NSSize(width: 500, height: 305), flipped: false) { rect in
                NSColor(hex: index % 2 == 0 ? "1C2430" : "F3F4F6").setFill(); rect.fill()
                NSColor(hex: index % 2 == 0 ? "303A49" : "DDE1E7").setFill()
                NSRect(x: 0, y: 277, width: 500, height: 28).fill()
                if index == 0 || index == 3 {
                    NSColor(hex: "26303E").setFill(); NSRect(x: 0, y: 0, width: 100, height: 277).fill()
                    for line in 0..<12 {
                        NSColor(hex: line % 3 == 0 ? "6BAAF9" : "88A5B7").setFill()
                        NSRect(x: 120 + (line % 3 == 0 ? 0 : 16), y: 244 - line * 17, width: 120 + (line * 37 % 205), height: 5).fill()
                    }
                } else if index == 2 {
                    for folder in 0..<6 {
                        NSColor(hex: "69B9E9").setFill()
                        NSBezierPath(roundedRect: NSRect(x: 70 + folder % 3 * 125, y: 70 + folder / 3 * 110, width: 72, height: 55), xRadius: 5, yRadius: 5).fill()
                    }
                } else {
                    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 25, weight: .medium), .foregroundColor: NSColor(hex: index % 2 == 0 ? "E4E9F1" : "26384A")]
                    let text = index == 1 ? "ScreenCaptureKit" : (index == 4 ? "切换器交互草案" : "周末，去山里走走")
                    text.draw(at: NSPoint(x: 35, y: 205), withAttributes: attrs)
                    for line in 0..<7 {
                        NSColor(hex: "C7D0DB").setFill()
                        NSRect(x: 35, y: 175 - line * 19, width: 230 + line * 23 % 160, height: 5).fill()
                    }
                }
                return true
            }
            var bounds = NSRect(x: 0, y: 0, width: 500, height: 305)
            let cg = image.cgImage(forProposedRect: &bounds, context: nil, hints: nil)
            previews[record.key] = PreviewPresentation(image: cg, status: index == 5 ? "最小化 · 上次快照" : nil)
        }
        if CommandLine.arguments.contains("--portrait") {
            let image = try portraitFixture()
            guard image.width == 244, image.height == 305 else { throw CocoaError(.coderInvalidValue) }
            previews[records[1].key] = PreviewPresentation(image: image, status: nil)
        }
        guard let screen = NSScreen.main else { throw CocoaError(.featureUnsupported) }
        let panel = SwitcherPanel()
        let grouped = CommandLine.arguments.contains("--grouped")
        let groups = grouped ? [WindowPanelGroup(displayID: 1, title: "屏幕 1 · 内建显示器", records: Array(records.prefix(3))),
                                WindowPanelGroup(displayID: 2, title: "屏幕 2 · 外接显示器", records: Array(records.suffix(3)))] : []
        let caption = CommandLine.arguments.contains("--per-screen") ? "屏幕 1 · 内建显示器" : nil
        panel.update(records: records, selected: records[1].key, preferences: preferences, previews: previews,
                     screen: screen, groups: groups, caption: caption, active: !CommandLine.arguments.contains("--inactive"))
        if CommandLine.arguments.contains("--check-panel-updates") {
            let updated = records.map { record in
                WindowRecord(key: record.key, windowID: record.windowID, pid: record.pid, appName: record.appName,
                    bundleID: record.bundleID, title: record.title + " · 已更新", frame: record.frame,
                    minimized: record.minimized, hidden: record.hidden, onDesktop: record.onDesktop,
                    accessibilityElement: record.accessibilityElement, icon: record.icon)
            }
            let lookup = Dictionary(uniqueKeysWithValues: updated.map { ($0.key, $0) })
            let updatedGroups = groups.map { group in
                WindowPanelGroup(displayID: group.displayID, title: group.title, records: group.records.compactMap { lookup[$0.key] })
            }
            let started = ProcessInfo.processInfo.systemUptime
            for index in 0..<240 {
                let result = panel.update(records: updated, selected: updated[index % 2].key, preferences: preferences,
                    previews: previews, screen: screen, groups: updatedGroups, caption: caption,
                    active: !CommandLine.arguments.contains("--inactive"))
                guard !result.changed else { throw CocoaError(.coderInvalidValue) }
            }
            print("PASS: 240 selection/metadata updates reused existing cards (\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) ms total)")
            panel.update(records: records, selected: records[1].key, preferences: preferences, previews: previews,
                screen: screen, groups: groups, caption: caption, active: !CommandLine.arguments.contains("--inactive"))
        }
        guard let view = panel.contentView else { throw CocoaError(.featureUnsupported) }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.featureUnsupported) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.featureUnsupported) }
        try data.write(to: url)
        print("Rendered \(url.path)")
    }

    /// Exercise the same CMSampleBuffer-to-bitmap path used by screenshot
    /// modes, with a Retina portrait image and deliberately left-hand padding.
    private static func portraitFixture() throws -> CGImage {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 500, 305, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw CocoaError(.featureUnsupported) }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let address = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: address, width: 500, height: 305, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            CVPixelBufferUnlockBaseAddress(buffer, []); throw CocoaError(.featureUnsupported)
        }
        context.setFillColor(NSColor(hex: "1D222C").cgColor); context.fill(CGRect(x: 0, y: 0, width: 500, height: 305))
        context.setFillColor(NSColor(hex: "EEF2F8").cgColor); context.fill(CGRect(x: 0, y: 0, width: 244, height: 305))
        context.setFillColor(NSColor(hex: "D5DDE8").cgColor); context.fill(CGRect(x: 0, y: 280, width: 244, height: 25))
        for line in 0..<12 {
            context.setFillColor(NSColor(hex: line == 0 ? "5A9CF8" : "AAB9CC").cgColor)
            context.fill(CGRect(x: 18, y: 252 - line * 17, width: 160 + line * 11 % 50, height: line == 0 ? 9 : 4))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &description) == noErr,
              let description else { throw CocoaError(.featureUnsupported) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else { throw CocoaError(.featureUnsupported) }
        let metadata = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
        metadata[SCStreamFrameInfo.contentRect.rawValue] = CGRect(x: 0, y: 0, width: 122, height: 152.5).dictionaryRepresentation
        metadata[SCStreamFrameInfo.scaleFactor.rawValue] = 2.0
        guard let image = PreviewBitmap.image(from: sample) else { throw CocoaError(.featureUnsupported) }
        return image
    }

    static func renderSettings(to url: URL, tab: String) throws {
        let view = NSHostingView(rootView: SettingsView(store: SettingsStore(), initialTab: tab, onCheck: {}))
        view.frame = NSRect(x: 0, y: 0, width: 710, height: 590)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view; window.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.featureUnsupported) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.featureUnsupported) }
        try data.write(to: url)
        print("Rendered \(url.path)")
    }
}
