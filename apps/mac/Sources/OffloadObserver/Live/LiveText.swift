// Live text sources: the bounded Accessibility walk of the focused window, and the OCR fallback (ScreenCaptureKit
// single window + Vision). Neither opens a connection to anything.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit
@preconcurrency import Vision

/// One Accessibility element as an `AXNodeReading`. Children are read lazily and only as far as the walker goes.
final class LiveAXNode: AXNodeReading, @unchecked Sendable {
    private static let textRoles: Set<String> = ["AXStaticText", "AXTextField", "AXTextArea", "AXHeading", "AXLink", "AXCell", "AXMenuItem"]
    private let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    private func string(_ name: String) -> String? { axAttribute(element, name) as? String }

    var isSecure: Bool { string(kAXSubroleAttribute) == "AXSecureTextField" }

    var text: String? {
        guard let role = string(kAXRoleAttribute), Self.textRoles.contains(role) else { return nil }
        return string(kAXValueAttribute) ?? string(kAXTitleAttribute) ?? string(kAXDescriptionAttribute)
    }

    var children: [any AXNodeReading] {
        guard let kids = axAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return kids.map { LiveAXNode($0) }
    }
}

@MainActor public final class LiveAXText: AXTextSource {
    public init() {}

    public func axText(of snapshot: FocusSnapshot) -> AXWalkResult? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == snapshot.bundleID else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = axAttribute(appElement, kAXFocusedWindowAttribute) else { return nil }
        let root = LiveAXNode(window as! AXUIElement)  // swiftlint:disable:this force_cast
        return AXWalker.walk(root: root, limits: .standard, now: { ProcessInfo.processInfo.systemUptime })
    }
}

public enum LiveOCRError: Error, Equatable, Sendable {
    case noWindow
}

@MainActor public final class LiveOCR: OCRSource {
    public init() {}

    public func ocrText(of snapshot: FocusSnapshot) async throws -> String? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let app = NSWorkspace.shared.frontmostApplication,
              let window = content.windows.first(where: { $0.owningApplication?.processID == app.processIdentifier && $0.isOnScreen && $0.frame.width > 80 })
        else { throw LiveOCRError.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(min(window.frame.width * 2, 2560))
        config.height = Int(min(window.frame.height * 2, 1600))
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return try await Self.recognise(image)
    }

    private static func recognise(_ image: CGImage) async throws -> String? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, any Error>) in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let lines = (request.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
                continuation.resume(returning: lines.isEmpty ? nil : lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            nonisolated(unsafe) let work = request
            DispatchQueue.global(qos: .utility).async {
                do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([work]) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
