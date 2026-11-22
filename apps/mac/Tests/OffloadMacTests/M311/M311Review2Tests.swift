import Combine
import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// Review 2 (logs/m3-11-mac-today-live.review2.md): the menu line never shows another day's total as "today" and is
// kept true by the model, not a view modifier (finding 1); the cloud card's count opens to how it was counted
// (finding 2); `.cloud` without a brain client says why instead of waiting (finding 3).

/// Counts objectWillChange, on the main actor.
@MainActor final class M311Changes {
  private(set) var count = 0
  private var cancellable: AnyCancellable?

  init(_ model: TodayLiveModel) {
    cancellable = model.objectWillChange.sink { [weak self] _ in
      MainActor.assumeIsolated { self?.count += 1 }
    }
  }
}

extension M311 {
  // MARK: Finding 1

  @MainActor @Test("MENU: after midnight the cloud line never shows yesterday's record as today")
  func menuCloudNotYesterday() async {
    let brain = M311Brain()
    let now = M311Now()
    let (model, _) = M311Kit.cloudModel(brain: brain, now: now)
    await model.refresh(force: true)
    #expect(model.menuLine == "today · 7 h 40 m")
    now.advance(7 * 3600)  // Fri 13 Nov, 01:00
    #expect(model.menuLine == nil)
  }

  @MainActor @Test("MENU: the model's own minute tick reads the new day after midnight and publishes the line")
  func menuTickRollsOverCloud() async {
    let brain = M311Brain()
    let now = M311Now()
    let (model, _) = M311Kit.cloudModel(brain: brain, now: now)
    await model.menuTick()
    #expect(brain.dayCalls == ["2026-11-12"])
    now.advance(7 * 3600)
    let changes = M311Changes(model)
    await model.menuTick()
    #expect(brain.dayCalls == ["2026-11-12", "2026-11-13"])
    #expect(model.menuLine == "today · 7 h 40 m")
    #expect(changes.count > 0)
  }

  @MainActor @Test("MENU: a failed read at launch is retried by the minute tick, with no line in between")
  func menuTickRetriesAfterFailure() async {
    let brain = M311Brain(day: { _ in throw APIError.transport(code: URLError.Code.notConnectedToInternet.rawValue) })
    let now = M311Now()
    let (model, _) = M311Kit.cloudModel(brain: brain, now: now)
    await model.menuTick()
    #expect(model.menuLine == nil)
    brain.setDay { M311Cloud.day($0) }
    now.advance(61)
    await model.menuTick()
    #expect(model.menuLine == "today · 7 h 40 m")
  }

  @MainActor @Test("MENU: in .local the minute tick publishes the day change, so a line for yesterday goes away")
  func menuTickRollsOverLocal() async {
    let now = M311Now()
    let (model, _) = M311Kit.localModel(M311Fixture.snapshot([M311Fixture.workday]), now: now)
    #expect(model.menuLine == "today · 7 h 40 m · mostly Xcode")
    await model.menuTick()
    let changes = M311Changes(model)
    now.advance(7 * 3600)
    await model.menuTick()
    #expect(changes.count > 0)
    #expect(model.menuLine == nil)
  }

  @MainActor @Test("CLOUD: Today left open on today moves to the new day after midnight; a day picked stays")
  func cloudTodayRollsOver() async {
    let brain = M311Brain()
    let now = M311Now()
    let (model, _) = M311Kit.cloudModel(brain: brain, now: now)
    await model.refresh(force: true)
    now.advance(7 * 3600)
    await model.tick()
    #expect(model.day == "2026-11-13")
    #expect(model.ready?.title == "Today · Fri, Nov 13")
    await model.previousDay()
    #expect(model.day == "2026-11-12")
    now.advance(61)
    await model.tick()
    #expect(model.day == "2026-11-12")
    #expect(model.ready?.title == "Thu, Nov 12")
  }

  // MARK: Finding 2

  @Test("HOW: the cloud card's count opens to the week task's instances when the opportunity names that task")
  func howCloudCardCount() throws {
    let c = try #require(M311Cloud.content(day: M311Cloud.day(), week: M311Cloud.week(),
                                            opportunities: [M311Cloud.opportunity("opp_1", rank: 1)], today: M311Clock.today,
                                            timeZone: M311Clock.utc))
    let card = try #require(c.fix)
    #expect(card.figure?.value == 6)
    #expect(card.how == "how: sum of the task's instances = 6.0")
    #expect(c.figures.contains { $0 == card.figure })
    // Without the week record there is nothing to open: no how line.
    let bare = try #require(M311Cloud.content(day: M311Cloud.day(), week: nil,
                                               opportunities: [M311Cloud.opportunity("opp_1", rank: 1)], today: M311Clock.today,
                                               timeZone: M311Clock.utc))
    #expect(bare.fix?.how == nil)
  }

  // MARK: Finding 3

  @MainActor @Test("STATES: .cloud without a brain client says Sign in again instead of reading forever")
  func cloudWithoutBrain() async {
    let app = M311Kit().app(backends: Backends(mode: .cloud(M311Backends.config), brain: nil, builds: nil, provenance: .cloud))
    let model = TodayLiveModel(app: app, now: M311Now().clock, reloadRanking: {}, todayAPI: true)
    await model.refresh(force: true)
    #expect(model.state == .failed(.signIn))
    #expect(!model.isLoading)
  }
}
