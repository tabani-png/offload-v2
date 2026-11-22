import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

// Frames from real files. Ported from PR #44 (AVRecordingFrameSource.swift) and wip/s34-mac (VideoFrames.swift):
// long edge at most 1280 px, the track's transform applied, pixels in memory only (nothing is written to disk).

/// The frames of a .mov, .mp4 or .m4v, read with AVAssetImageGenerator. Synchronous: the importer runs off the main
/// actor, one file at a time.
public final class AVRecordingFrameSource: RecordingFrameSource {
  public static let maxLongEdge = 1280
  public let duration: TimeInterval
  private let generator: AVAssetImageGenerator

  public init(url: URL, maxLongEdge: Int = AVRecordingFrameSource.maxLongEdge) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { throw RecordingSourceError.notFound }
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    guard !asset.tracks(withMediaType: .video).isEmpty else { throw RecordingSourceError.noVideoTrack }
    let seconds = CMTimeGetSeconds(asset.duration)
    guard seconds.isFinite, seconds > 0 else { throw RecordingSourceError.unreadable("no duration") }
    duration = seconds
    generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxLongEdge, height: maxLongEdge)
    // A frame within half a second is fine for sampling every 5 s, and much faster than exact seeks.
    let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance
  }

  public func frame(at time: TimeInterval) throws -> ImportFrame? {
    guard let image = try? generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil) else {
      return nil
    }
    return ImportFrame(image: image, tag: String(format: "%.1f", time))
  }

  /// The length of a recording for the folder summary, or nil when it cannot be read.
  public static func duration(of url: URL) -> TimeInterval? {
    let seconds = CMTimeGetSeconds(AVURLAsset(url: url).duration)
    return seconds.isFinite && seconds > 0 ? seconds : nil
  }
}

/// One screenshot, read with ImageIO as a thumbnail at most 1280 px on its long edge, orientation applied.
public enum ImageFileFrameSource {
  public static func frame(url: URL, maxLongEdge: Int = AVRecordingFrameSource.maxLongEdge) throws -> ImportFrame {
    guard FileManager.default.fileExists(atPath: url.path) else { throw RecordingSourceError.notFound }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
      throw RecordingSourceError.unreadable("not an image")
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw RecordingSourceError.unreadable("not an image")
    }
    return ImportFrame(image: image, tag: url.lastPathComponent)
  }
}
