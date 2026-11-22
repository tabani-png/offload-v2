import CoreGraphics
import Foundation
import OffloadImport
import Vision

// On-device OCR for the recordings import: Vision's text recognizer, run synchronously on the caller's (detached)
// task. Pixels in, lines out, nothing kept.

public enum VisionBoxes {
  /// Vision's normalized box (origin bottom left) to frame pixels with the origin at the top left.
  public static func topLeft(_ normalized: CGRect, width: Int, height: Int) -> OCRBox {
    let w = Double(width)
    let h = Double(height)
    return OCRBox(x: Double(normalized.minX) * w, y: (1 - Double(normalized.maxY)) * h,
                  width: Double(normalized.width) * w, height: Double(normalized.height) * h)
  }

  /// Top to bottom, then left to right. Lines whose tops are within half a line height of a row's first line share
  /// that row.
  public static func ordered(_ lines: [OCRLine]) -> [OCRLine] {
    let byTop = lines.sorted { $0.box.y != $1.box.y ? $0.box.y < $1.box.y : $0.box.x < $1.box.x }
    var rows: [[OCRLine]] = []
    for line in byTop {
      if let first = rows.last?.first, line.box.y - first.box.y < max(1, min(first.box.height, line.box.height) / 2) {
        rows[rows.count - 1].append(line)
      } else {
        rows.append([line])
      }
    }
    return rows.flatMap { row in row.sorted { $0.box.x < $1.box.x } }
  }
}

public struct VisionTextRecognizer: TextRecognizer {
  /// The menu bar languages m3-05 reads.
  public static let languages = ["en-US", "de-DE", "fr-FR", "es-ES"]

  public init() {}

  /// Accurate, with language correction, in the four languages; the revision is the SDK's default.
  public func makeRequest() -> VNRecognizeTextRequest {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = Self.languages
    return request
  }

  public func recognize(_ frame: ImportFrame) throws -> [OCRLine] {
    guard let image = frame.image else { return [] }
    let request = makeRequest()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])
    let observations = request.results ?? []
    var lines: [OCRLine] = []
    for o in observations {
      guard let top = o.topCandidates(1).first else { continue }
      let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      lines.append(OCRLine(text: text, box: VisionBoxes.topLeft(o.boundingBox, width: image.width, height: image.height)))
    }
    return VisionBoxes.ordered(lines)
  }
}
