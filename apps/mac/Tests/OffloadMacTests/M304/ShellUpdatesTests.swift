import Foundation
import Testing
@testable import OffloadMac

// The menu bar item carries m3-03's updater entries. Until the rebase onto main (2026-11-22) they lived in the
// placeholder AppKit menu in OffloadMac.swift; the SwiftUI shell now shows the same lines (UpdateMenu), before Quit.

extension M304 {
  @Test("SHELL: without a signed feed the menu bar item shows the updater's status line, not Check for Updates")
  @MainActor func updateMenuWithoutFeed() {
    let off = UpdateFeedConfig(info: [:])
    #expect(!off.isEnabled)
    #expect(UpdateMenu.entries(feed: off, missingAfterUpdate: []) == [
      UpdateMenuEntry(title: off.statusLine, action: .disabled)
    ])
  }

  @Test("SHELL: with a signed feed the menu bar item offers Check for Updates, after a line per permission lost in the update")
  @MainActor func updateMenuWithFeed() {
    let on = UpdateFeedConfig(info: [
      "SUFeedURL": "https://downloads.example.com/appcast.xml",
      "SUPublicEDKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
      "SURequireSignedFeed": true,
      "SUVerifyUpdateBeforeExtraction": true,
    ])
    #expect(on.isEnabled)
    #expect(UpdateMenu.entries(feed: on, missingAfterUpdate: []) == [
      UpdateMenuEntry(title: UpdaterController.checkForUpdatesTitle, action: .checkForUpdates)
    ])
    #expect(UpdateMenu.entries(feed: on, missingAfterUpdate: [.accessibility, .screenRecording]) == [
      UpdateMenuEntry(title: "Accessibility is off", action: .disabled),
      UpdateMenuEntry(title: "Screen Recording is off", action: .disabled),
      UpdateMenuEntry(title: UpdaterController.checkForUpdatesTitle, action: .checkForUpdates),
    ])
  }
}
