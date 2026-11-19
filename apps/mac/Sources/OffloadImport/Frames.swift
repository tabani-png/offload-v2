import CoreGraphics
import Foundation

// The frames and text the import reads. Frames stay in memory on the Mac; only masked text leaves as observations.

/// One frame of a recording or one screenshot, at most 1280 px on its long edge.
public struct ImportFrame: @unchecked Sendable {
  public let width: Int
  public let height: Int
  /// Names the frame for an injected recognizer or hasher (the recording's offset or the file name). Never written
  /// anywhere.
  public let tag: String
  /// The pixels; nil for frames made up in tests. `CGImage` is immutable, which is why the frame may be shared.
  public let image: CGImage?

  public init(width: Int, height: Int, tag: String, image: CGImage? = nil) {
    self.width = width
    self.height = height
    self.tag = tag
    self.image = image
  }

  public init(image: CGImage, tag: String) {
    self.init(width: image.width, height: image.height, tag: tag, image: image)
  }
}

/// A box in frame pixels, origin at the top left (y grows down).
public struct OCRBox: Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public struct OCRWord: Equatable, Sendable {
  public var text: String
  public var box: OCRBox

  public init(text: String, box: OCRBox) {
    self.text = text
    self.box = box
  }
}

public struct OCRLine: Equatable, Sendable {
  public var text: String
  public var box: OCRBox
  public var words: [OCRWord]

  public init(text: String, box: OCRBox, words: [OCRWord]) {
    self.text = text
    self.box = box
    self.words = words
  }

  /// A line from a recognizer that gives lines only: the words share the line's box by their position in the text.
  public init(text: String, box: OCRBox) {
    let total = Double(max(1, text.count))
    let words = text.split(separator: " ").map { piece -> OCRWord in
      let start = Double(text.distance(from: text.startIndex, to: piece.startIndex))
      let wordBox = OCRBox(x: box.x + box.width * start / total, y: box.y,
                           width: box.width * Double(piece.count) / total, height: box.height)
      return OCRWord(text: String(piece), box: wordBox)
    }
    self.init(text: text, box: box, words: words)
  }
}

/// On-device OCR (m3-02's Vision recognizer). Pixels in, lines out, nothing kept.
public protocol TextRecognizer: Sendable {
  func recognize(_ frame: ImportFrame) throws -> [OCRLine]
}

/// The m3-02 masker: structured secrets and names become tokens before any text is written.
public protocol ImportTextMasker: Sendable {
  func mask(_ text: String) -> String
}

/// A 64-bit perceptual hash of a frame (m3-02's keyframe hash).
public protocol FrameHasher: Sendable {
  func hash(_ frame: ImportFrame) -> UInt64
}

/// What the import knows about a kept keyframe. m3-02 renders, masks and seals it; it is never uploaded raw.
public struct ImportKeyframe: Equatable, Sendable {
  public var importID: String
  public var ts: Date
  public var appBundleID: String
  public var appName: String
  public var lines: [OCRLine]
}

/// Where kept keyframes go (m3-02's masked keyframe store). Nil turns keyframes off.
public protocol ImportKeyframeSink: Sendable {
  func keep(_ frame: ImportFrame, keyframe: ImportKeyframe) throws
}

/// The frames of one recording. The AVFoundation one is `AVRecordingFrameSource`.
public protocol RecordingFrameSource {
  /// Seconds.
  var duration: TimeInterval { get }
  /// The frame at `time` seconds, or nil when that moment cannot be decoded (the sample is skipped).
  func frame(at time: TimeInterval) throws -> ImportFrame?
}

public enum RecordingSourceError: Error, Equatable, CustomStringConvertible {
  case notFound
  case noVideoTrack
  case unreadable(String)

  public var description: String {
    switch self {
    case .notFound: return "file not found"
    case .noVideoTrack: return "no video track"
    case .unreadable(let why): return "unreadable (\(why))"
    }
  }
}
