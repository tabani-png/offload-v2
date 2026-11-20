import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import OffloadImport

// Frames from real files (wip/s34-mac S34ExtractFramesTests, in memory now) and the menu bar app name (PR #44
// S34MenuBarTests, S34AppIdentityTests).

struct M305VideoError: Error {}

/// Writes a small Motion-JPEG .mov (software codec, no hardware encoder needed): `seconds` long at `fps`, each second
/// a different gray so frames differ.
func m305TinyVideo(in dir: URL, seconds: Int, fps: Int32 = 5, width: Int = 1600, height: Int = 900) throws -> URL {
  let url = dir.appendingPathComponent("recording.mov")
  let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
  let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.jpeg, AVVideoWidthKey: width, AVVideoHeightKey: height]
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
  input.expectsMediaDataInRealTime = false
  let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                                   kCVPixelBufferWidthKey as String: width,
                                   kCVPixelBufferHeightKey as String: height]
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
  writer.add(input)
  guard writer.startWriting() else { throw writer.error ?? M305VideoError() }
  writer.startSession(atSourceTime: .zero)
  for i in 0..<(seconds * Int(fps)) {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
    var buffer: CVPixelBuffer?
    _ = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    guard let buffer else { throw M305VideoError() }
    _ = CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
      _ = memset(base, Int32(40 + (i / Int(fps)) * 50 % 200), CVPixelBufferGetDataSize(buffer))
    }
    _ = CVPixelBufferUnlockBaseAddress(buffer, [])
    guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps)) else {
      throw writer.error ?? M305VideoError()
    }
  }
  input.markAsFinished()
  writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds) * CMTimeValue(fps), timescale: fps))
  let done = DispatchSemaphore(value: 0)
  writer.finishWriting { done.signal() }
  done.wait()
  guard writer.status == .completed else { throw writer.error ?? M305VideoError() }
  return url
}

/// Writes a gray PNG of the given size.
func m305PNG(in dir: URL, name: String, width: Int, height: Int) throws -> URL {
  let url = dir.appendingPathComponent(name)
  guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { throw M305VideoError() }
  ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
  guard let image = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw M305VideoError() }
  CGImageDestinationAddImage(dest, image, nil)
  guard CGImageDestinationFinalize(dest) else { throw M305VideoError() }
  return url
}

extension M305 {
  // MARK: FRAMES

  @Test("FRAMES: a generated video gives frames in memory with the long edge at most 1280 px at the planned times")
  func framesFromAGeneratedVideo() throws {
    let dir = M305Files.folder("Video")
    defer { M305Files.remove(dir) }
    let video = try m305TinyVideo(in: dir, seconds: 3)
    let before = M305Files.listing(dir)
    let source = try AVRecordingFrameSource(url: video)
    #expect(abs(source.duration - 3) <= 0.25)
    let times = SamplePlan.times(duration: source.duration, interval: 1, maxFrames: SamplePlan.maxFrames)
    #expect(times.count == 3)
    for t in times {
      let frame = try #require(try source.frame(at: t))
      #expect(max(frame.width, frame.height) <= 1280)
      #expect(frame.width > frame.height)
      #expect(frame.image != nil)
    }
    // Frames stay in memory: nothing is written next to the recording.
    #expect(M305Files.listing(dir) == before)
    #expect(AVRecordingFrameSource.maxLongEdge == 1280)
  }

  @Test("FRAMES: a missing file or a file that is not a video fails")
  func aMissingOrNonVideoFileFails() throws {
    let dir = M305Files.folder("Video")
    defer { M305Files.remove(dir) }
    #expect(throws: RecordingSourceError.notFound) {
      _ = try AVRecordingFrameSource(url: dir.appendingPathComponent("none.mov"))
    }
    let text = dir.appendingPathComponent("notes.mov")
    try Data("not a movie".utf8).write(to: text)
    #expect(throws: (any Error).self) {
      _ = try AVRecordingFrameSource(url: text)
    }
  }

  @Test("FRAMES: an image file is read at 1280 px at most; a broken one fails")
  func imageFrames() throws {
    let dir = M305Files.folder("Shots")
    defer { M305Files.remove(dir) }
    let big = try m305PNG(in: dir, name: "big.png", width: 1600, height: 900)
    let frame = try ImageFileFrameSource.frame(url: big)
    #expect(max(frame.width, frame.height) <= 1280)
    #expect(frame.width > frame.height)
    let broken = dir.appendingPathComponent("broken.png")
    try Data("nope".utf8).write(to: broken)
    #expect(throws: (any Error).self) { _ = try ImageFileFrameSource.frame(url: broken) }
  }

  // MARK: MENUBAR

  @Test("MENUBAR: the app name is the words before the first menu")
  func appNameIsTheWordsBeforeTheFirstMenu() {
    #expect(MenuBarApp.name(from: m305Screen(app: "Safari", menus: "File Edit View History Bookmarks", body: "x"), frameHeight: 800) == "Safari")
    #expect(MenuBarApp.name(from: m305Screen(app: "Google Chrome", body: "x"), frameHeight: 800) == "Google Chrome")
  }

  @Test("MENUBAR: with no File menu the first word is the app")
  func noFileMenuTakesTheFirstWord() {
    #expect(MenuBarApp.name(from: m305Screen(app: "Finder", menus: "Go Window", body: "x"), frameHeight: 800) == "Finder")
  }

  @Test("MENUBAR: nothing in the top band is nil; the band is 4 % of the frame and at least 24 px")
  func nothingInTheTopBandIsNil() {
    let lines = [OCRLine(text: "Quarterly report", box: OCRBox(x: 100, y: 300, width: 400, height: 20))]
    #expect(MenuBarApp.name(from: lines, frameHeight: 800) == nil)
    #expect(MenuBarApp.bandHeight(frameHeight: 400) == 24)
    #expect(MenuBarApp.bandHeight(frameHeight: 2000) == 80)
  }

  @Test("MENUBAR: known apps map to their bundle ids")
  func knownAppsMapToTheirBundleIDs() {
    #expect(MenuBarApp.bundleID(for: "Safari") == "com.apple.Safari")
    #expect(MenuBarApp.bundleID(for: "Google Chrome") == "com.google.Chrome")
    #expect(MenuBarApp.bundleID(for: "Numbers") == "com.apple.iWork.Numbers")
    #expect(MenuBarApp.bundleID(for: "Code") == "com.microsoft.VSCode")
    #expect(MenuBarApp.bundleID(for: "1Password") == "com.1password.1password")
  }

  @Test("MENUBAR: unknown apps get a stable recording id")
  func unknownAppsGetAStableRecordingID() {
    #expect(MenuBarApp.bundleID(for: "Acme Ledger") == "recording.acme-ledger")
    #expect(MenuBarApp.bundleID(for: nil) == "recording.unknown")
    #expect(MenuBarApp.bundleID(for: "") == "recording.unknown")
  }

  @Test("MENUBAR: a top band without two menu titles is window content, not an app name (review 1)")
  func bandWithoutMenusIsNotAnApp() {
    let title = [OCRLine(text: "Okafor_contract.pdf", box: OCRBox(x: 400, y: 4, width: 300, height: 16))]
    #expect(MenuBarApp.name(from: title, frameHeight: 800) == nil)
    #expect(MenuBarApp.name(from: m305Screen(app: "Q3 Report", menus: "View", body: "x"), frameHeight: 800) == nil)
    #expect(MenuBarApp.name(from: m305Screen(app: "Notes", menus: "File Edit", body: "x"), frameHeight: 800) == "Notes")
  }
}
