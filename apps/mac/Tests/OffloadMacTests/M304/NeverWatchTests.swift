import Foundation
import Testing
@testable import OffloadMac

// "Never watch these apps or sites" (ONBOARDING screen 9, Q5). Ported from PR #44 (Recordings.swift NeverWatch,
// S34AhaAndExclusionsTests.swift). The m3-02 observer reads ExclusionSource every 2 s.

extension M304 {
  @Test("NEVERWATCH: appsAndSitesAreToldApart")
  func appsAndSites() {
    let r = NeverWatch.parse("Slack, mail.google.com, com.apple.MobileSMS, https://bank.example.com/login, ,")
    #expect(r == [.appName("Slack"), .host("mail.google.com"), .bundleID("com.apple.MobileSMS"), .host("bank.example.com")])
    #expect(NeverWatchEntry.bundleID("com.tinyspeck.slackmacgap").exclusion
            == Exclusion(kind: .bundleID, value: "com.tinyspeck.slackmacgap"))
    #expect(NeverWatchEntry.host("mail.google.com").exclusion == Exclusion(kind: .host, value: "mail.google.com"))
    #expect(NeverWatchEntry.appName("Slack").exclusion == nil)  // the app layer resolves names to bundle ids first
    let resolved = NeverWatch.exclusions(from: "Slack, Nope App, example.org") { name in
      name == "Slack" ? "com.tinyspeck.slackmacgap" : nil
    }
    #expect(resolved.exclusions == [Exclusion(kind: .bundleID, value: "com.tinyspeck.slackmacgap"), Exclusion(kind: .host, value: "example.org")])
    #expect(resolved.unresolved == ["Nope App"])
    #expect(Exclusion.Kind.bundleID.rawValue == "bundle_id")
    #expect(Exclusion.Kind.titleContains.rawValue == "title_contains")
  }

  @Test("NEVERWATCH: locked entries are on from the start and cannot be removed")
  func lockedEntries() {
    #expect(NeverWatchChip.locked.map(\.label) == ["1Password", "Banking sites", "Private windows"])
    #expect(NeverWatchChip.locked.allSatisfy { $0.isLocked })
    #expect(NeverWatchChip.optional.map(\.label) == ["Messages", "WhatsApp", "Photos", "Spotify"])
    #expect(!NeverWatchChip.optional.contains { $0.isLocked })
    let store = NeverWatchStore()
    let builtIn = store.currentExclusions()
    #expect(builtIn.contains(Exclusion(kind: .bundleID, value: "com.1password.1password", source: .builtin)))
    #expect(builtIn.allSatisfy { $0.source == .builtin })
    for e in builtIn { #expect(!store.remove(e)) }
    #expect(store.currentExclusions() == builtIn)
    let messages = Exclusion(kind: .bundleID, value: "com.apple.MobileSMS")
    store.add([messages])
    #expect(store.remove(messages))
    #expect(store.currentExclusions() == builtIn)
  }

  @Test("NEVERWATCH: never-watch entries apply locally before the server call returns")
  @MainActor func localFirst() async {
    let fakes = M304Services()
    let model = fakes.model()
    for a in M304Path.toWhatLeaves { await model.perform(a) }
    await model.perform(.startSending(noticeVersion: "1"))
    for _ in 0..<3 { await model.perform(.skip) }
    #expect(model.flow.screen == .rhythm)
    let spotify = Exclusion(kind: .bundleID, value: "com.spotify.client")
    await model.perform(.neverWatch(add: [spotify]))
    #expect(fakes.exclusions.uploads == [[spotify]])
    #expect(fakes.exclusions.localHadThemFirst == [true])
    #expect(fakes.neverWatch.currentExclusions().contains(spotify))
    // In Local mode the entry applies on the Mac and nothing is sent.
    let local = M304Services()
    let lm = local.model()
    for a in Array(M304Path.toWhatLeaves.prefix(5)) + [.notNow] { await lm.perform(a) }
    await lm.perform(.neverWatch(add: [spotify]))
    #expect(local.neverWatch.currentExclusions().contains(spotify))
    #expect(local.exclusions.uploads.isEmpty)
  }

  @Test("NEVERWATCH: the observer's exclusion source sees an added entry and a removed one, and the list survives relaunch")
  @MainActor func observerSource() async {
    let store = NeverWatchStore()
    let source: any ExclusionSource = store
    let host = Exclusion(kind: .host, value: "mail.google.com")
    store.add([host, host])
    #expect(source.currentExclusions().filter { $0 == host }.count == 1)
    #expect(store.remove(host))
    #expect(!source.currentExclusions().contains(host))
    // The user's entries are part of the saved onboarding state, so a relaunch restores them.
    let fakes = M304Services()
    let model = fakes.model()
    await model.perform(.neverWatch(add: [host]))
    #expect(model.flow.state.neverWatch == [host])
    let restored = NeverWatchStore(user: fakes.model().flow.state.neverWatch)
    #expect(restored.currentExclusions().contains(host))
    #expect(OnboardingCopy.neverWatchCaption == "excluded apps stop being seen within one check · no text, no frames")
  }
}
