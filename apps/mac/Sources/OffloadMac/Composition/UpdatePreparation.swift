// What the updater (m3-03) drives before Sparkle installs (slice m3-14-mac-app-integration, review 1 finding 6):
// capture stops and the uploader pauses, so neither runs while the app is replaced. Both queues are on disk (the day
// store and the upload queue), so nothing is lost; the next launch starts them again per LaunchPlan.
@MainActor public final class UpdatePreparation: CaptureLifecycle {
  public let capture: CaptureRuntime
  /// Nil in Local mode.
  public let uploads: UploadRuntime?

  public init(capture: CaptureRuntime, uploads: UploadRuntime?) {
    self.capture = capture
    self.uploads = uploads
  }

  func start() { capture.start() }

  func prepareForUpdate() {
    capture.prepareForUpdate()
    uploads?.pause()
  }
}
