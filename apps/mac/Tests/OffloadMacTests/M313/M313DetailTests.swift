import Foundation
import Testing
@testable import OffloadMac

// The pure parts of one build's detail: steps, attempts, headline, held-out result, budget meter, saving line, where
// every number comes from, and the copy rules (SPEC m3-13 red tests STEPS, ATTEMPTS, HEADLINE, HELDOUT, BUDGET,
// SAVING, FIGURES, COPY).

extension M313 {
  // MARK: STEPS

  @Test("STEPS: a ready build maps onto the five rows, row 1 with the brief's fingerprint, row 3 with 2 of 3 attempts passing")
  func stepsReady() {
    let rows = StepMapping.rows(build: M313F.ready, fix: M313F.fix)
    #expect(rows == [
      StepRow(title: "Plan locked", detail: "what it builds and what it must not touch · fingerprint 7c41e2", status: .done),
      StepRow(title: "Checks frozen first", detail: "checks written before any code", status: .done),
      StepRow(title: "Workers testing", detail: "2 of 3 attempts passing", status: .done),
      StepRow(title: "Matches what you asked for", detail: "held-out check passed", status: .done),
      StepRow(title: "Ready to ship", detail: "install asks you once more", status: .done),
    ])
    #expect(StepMapping.fingerprint(M313F.briefHash) == "7c41e2")
    #expect(StepMapping.fingerprint("7C41E2FF") == "7c41e2")
  }

  @Test("STEPS: while fanning out, row 3 says 1 failed · builder is fixing it and works; a failed stage of a live build waits")
  func stepsFanningOut() {
    let rows = StepMapping.rows(build: M313F.fanningOut, fix: nil)
    #expect(rows.count == 5)
    #expect(rows[0] == StepRow(title: "Plan locked", detail: "what it builds and what it must not touch", status: .done))
    #expect(rows[1].status == .done)
    #expect(rows[2] == StepRow(title: "Workers testing", detail: "1 failed · builder is fixing it", status: .working))
    #expect(rows[3] == StepRow(title: "Matches what you asked for", detail: "compared against your words, not just the tests",
                               status: .waiting))
    #expect(rows[4] == StepRow(title: "Ready to ship", detail: "install asks you once more", status: .waiting))
  }

  @Test("STEPS: each stage name and state maps to its row (teeth_gate row 2, worker and fan_out row 3, verification and winner row 4)")
  func stepsEachStage() {
    func rows(_ state: BuildState, _ stages: [BuildStage]) -> [StepRow] {
      StepMapping.rows(build: M313F.build(state, stages: stages), fix: nil)
    }
    #expect(rows(.queued, []).map(\.status) == [.done, .waiting, .waiting, .waiting, .waiting])
    #expect(rows(.building, [M313F.stage("teeth_gate", .running)]).map(\.status) == [.done, .working, .waiting, .waiting, .waiting])
    let toothless = rows(.failed, [M313F.stage("teeth_gate", .failed, note: "Needs you: the held-out check passes on an empty workspace (no teeth).")])
    #expect(toothless[1] == StepRow(title: "Checks frozen first",
                                    detail: "Needs you: the held-out check passes on an empty workspace (no teeth).", status: .failed))
    #expect(rows(.building, [M313F.stage("teeth_gate", .done), M313F.stage("worker", .running)]).map(\.status)
      == [.done, .done, .working, .waiting, .waiting])
    #expect(rows(.verifying, [M313F.stage("teeth_gate", .done), M313F.stage("worker", .done), M313F.stage("verification", .running)])
      .map(\.status) == [.done, .done, .done, .working, .waiting])
    #expect(rows(.repairing, [M313F.stage("teeth_gate", .done), M313F.stage("worker", .done), M313F.stage("verification", .failed),
                              M313F.stage("fan_out", .running)]).map(\.status) == [.done, .done, .working, .waiting, .waiting])
    #expect(rows(.building, [M313F.stage("teeth_gate", .done), M313F.stage("worker", .done), M313F.stage("verification", .done),
                             M313F.stage("winner", .running)]).map(\.status) == [.done, .done, .done, .working, .waiting])
    let noWinner = rows(.failed, [M313F.stage("teeth_gate", .done), M313F.stage("worker", .done), M313F.stage("verification", .done),
                                  M313F.stage("winner", .failed, note: "No build passed every check.")])
    #expect(noWinner.map(\.status) == [.done, .done, .done, .failed, .waiting])
  }

  @Test("STEPS: \"2 of 3 attempts passing\" counts passes; \"1 failed · builder is fixing it\" needs a later running attempt")
  func stepsAttemptLines() {
    let stages = [M313F.stage("teeth_gate", .done), M313F.stage("worker", .done)]
    let passing = M313F.build(.verifying, stages: stages, attempts: [
      M313F.attempt(1, .pass), M313F.attempt(2, .fail), M313F.attempt(3, .pass),
    ])
    #expect(StepMapping.rows(build: passing, fix: nil)[2].detail == "2 of 3 attempts passing")
    let fixing = M313F.build(.fanningOut, stages: stages, attempts: [
      M313F.attempt(1, .fail), M313F.attempt(2, .running),
    ])
    #expect(StepMapping.rows(build: fixing, fix: nil)[2].detail == "1 failed · builder is fixing it")
    // A failure after the running attempt is not being fixed by it.
    let notFixing = M313F.build(.fanningOut, stages: stages, attempts: [
      M313F.attempt(1, .running), M313F.attempt(2, .fail),
    ])
    #expect(StepMapping.rows(build: notFixing, fix: nil)[2].detail == "0 of 2 attempts passing")
    let none = M313F.build(.building, stages: stages)
    #expect(StepMapping.rows(build: none, fix: nil)[2].detail == "one worker first, more only if a check fails")
  }

  @Test("STEPS: an unknown stage is listed under row 3 with its name and state, never dropped")
  func stepsUnknownStage() {
    let b = M313F.build(.failed, stages: [
      M313F.stage("teeth_gate", .done), M313F.stage("recovered", .failed, note: "Offload's side stopped."),
      M313F.stage("end", .unknown("paused")),
    ])
    let rows = StepMapping.rows(build: b, fix: nil)
    #expect(rows.count == 5)
    #expect(rows[2].extras == ["recovered · failed", "end · paused"])
    #expect(rows[0].extras.isEmpty && rows[1].extras.isEmpty && rows[3].extras.isEmpty && rows[4].extras.isEmpty)
  }

  @Test("STEPS: an installed build's last row says installed")
  func stepsInstalled() {
    let rows = StepMapping.rows(build: M313F.readyAs(.ready, deployed: true), fix: M313F.fix)
    #expect(rows[4] == StepRow(title: "Ready to ship", detail: "installed", status: .done))
  }

  // MARK: ATTEMPTS

  @Test("ATTEMPTS: one row per attempt by ordinal with outcome dot, frozen and held-out marks and spend")
  func attemptsReady() {
    let rows = AttemptRow.rows(M313F.ready.attempts.reversed())
    #expect(rows == [
      AttemptRow(ordinal: 1, name: "worker 1", dot: .failedCheck, frozen: .failed, heldOut: .passed, spend: "$0.31"),
      AttemptRow(ordinal: 2, name: "worker 2", dot: .done, frozen: .passed, heldOut: .passed, spend: "$0.27"),
      AttemptRow(ordinal: 3, name: "worker 3", dot: .done, frozen: .passed, heldOut: .passed, spend: "$0.26"),
    ])
  }

  @Test("ATTEMPTS: outcome dots: running blue, pass green, fail red, cap, tamper, error and unknown amber")
  func attemptsDots() {
    #expect(AttemptRow.dot(.running) == .working)
    #expect(AttemptRow.dot(.pass) == .done)
    #expect(AttemptRow.dot(.fail) == .failedCheck)
    #expect(AttemptRow.dot(.cap) == .needsYou)
    #expect(AttemptRow.dot(.tamper) == .needsYou)
    #expect(AttemptRow.dot(.error) == .needsYou)
    #expect(AttemptRow.dot(.unknown("vanished")) == .needsYou)
  }

  @Test("ATTEMPTS: marks come from frozen_pass and held_out_pass, else from check_groups, else not run")
  func attemptsMarks() {
    let fromGroups = M313F.attempt(1, .fail, groups: [CheckGroup(name: .frozen, passed: 3, failed: 1),
                                                     CheckGroup(name: .heldOut, passed: 2, failed: 0)])
    let fromFlags = M313F.attempt(2, .pass, frozen: true, heldOut: false,
                                  groups: [CheckGroup(name: .frozen, passed: 0, failed: 4)])
    let nothing = M313F.attempt(3, .running)
    let rows = AttemptRow.rows([fromGroups, fromFlags, nothing])
    #expect(rows.map(\.frozen) == [.failed, .passed, .notRun])
    #expect(rows.map(\.heldOut) == [.passed, .failed, .notRun])
    #expect(CheckMark.passed.text == "✓")
    #expect(CheckMark.failed.text == "✗")
    #expect(CheckMark.notRun.text == "not run")
  }

  @Test("ATTEMPTS: spend per attempt in dollars and cents, half up")
  func attemptsSpend() {
    let rows = AttemptRow.rows([M313F.attempt(1, .pass, spent: 0.305), M313F.attempt(2, .pass, spent: 1.2),
                                M313F.attempt(3, .running, spent: 0)])
    #expect(rows.map(\.spend) == ["$0.31", "$1.20", "$0.00"])
  }

  // MARK: HEADLINE

  @Test("HEADLINE: every state's headline, and an unknown state shown raw")
  func headlines() {
    let expected: [(BuildState, String)] = [
      (.queued, "Waiting to start."),
      (.building, "Building. Tests first."),
      (.verifying, "Checking it in a fresh sandbox."),
      (.fanningOut, "One check failed. Fixing it."),
      (.repairing, "One check failed. Fixing it."),
      (.ready, "It's built and every check passed."),
      (.failed, "It didn't pass. Nothing was installed."),
      (.capped, "It reached the $4.00 cap. Nothing was installed."),
      (.tampered, "A worker changed the checks. The build was stopped."),
      (.cancelled, "Cancelled. Nothing was installed."),
      (.infraFailed, "The build service had a problem. This is not billed to your cap."),
      (.unknown("teleporting"), "Status: teleporting"),
    ]
    for (state, line) in expected {
      #expect(HeadlineMap.headline(state) == line, "\(state.raw)")
    }
  }

  @Test("HEADLINE: the server note of the latest stage is shown under it as given")
  func headlineNote() {
    #expect(HeadlineMap.note(M313F.ready) == "Worker 2 passed every check in fresh sandboxes.")
    #expect(HeadlineMap.note(M313F.fanningOut) == nil)
    #expect(HeadlineMap.note(M313F.build(.queued)) == nil)
    let detail = BuildDetail.make(build: M313F.ready, fix: M313F.fix, outcome: .notLoaded, now: M313F.date("2026-11-22T12:00:00Z"),
                                  name: "PR pre-read tool")
    #expect(detail.headline == "It's built and every check passed.")
    #expect(detail.headlineNote == "Worker 2 passed every check in fresh sandboxes.")
    #expect(detail.title == "Building · PR pre-read tool")
  }

  @Test("HEADLINE: dots: blue working, amber needs you (capped, tampered, infra_failed, a failed stage), green done, red failed")
  func headlineDots() {
    #expect(HeadlineMap.dot(M313F.ready) == .done)
    #expect(HeadlineMap.dot(M313F.readyAs(.failed)) == .failedCheck)
    #expect(HeadlineMap.dot(M313F.readyAs(.capped)) == .needsYou)
    #expect(HeadlineMap.dot(M313F.readyAs(.tampered)) == .needsYou)
    #expect(HeadlineMap.dot(M313F.readyAs(.infraFailed)) == .needsYou)
    #expect(HeadlineMap.dot(M313F.readyAs(.unknown("x"))) == .needsYou)
    #expect(HeadlineMap.dot(M313F.fanningOut) == .needsYou)
    #expect(HeadlineMap.dot(M313F.build(.building, stages: [M313F.stage("teeth_gate", .running)])) == .working)
    #expect(HeadlineMap.dot(M313F.build(.queued)) == .working)
  }

  // MARK: HELDOUT

  @Test("HELDOUT: passed, failed and not run from the winner attempt")
  func heldOutWinner() {
    #expect(HeldOutResult.of(M313F.ready) == .passed)
    var b = M313F.build(.failed, attempts: [M313F.attempt(1, .fail, heldOut: false), M313F.attempt(2, .pass, heldOut: true)],
                        winner: "att_1")
    #expect(HeldOutResult.of(b) == .failed)
    b.winnerAttemptID = "att_2"
    #expect(HeldOutResult.of(b) == .passed)
    let notRun = M313F.build(.ready, attempts: [M313F.attempt(1, .pass), M313F.attempt(2, .pass, heldOut: true)], winner: "att_1")
    #expect(HeldOutResult.of(notRun) == .notRun)
  }

  @Test("HELDOUT: without a winner, the latest attempt (highest ordinal), from its flag or its check group")
  func heldOutLatest() {
    let latestFailed = M313F.build(.fanningOut, attempts: [
      M313F.attempt(3, .fail, groups: [CheckGroup(name: .heldOut, passed: 0, failed: 1)]), M313F.attempt(1, .pass, heldOut: true),
    ])
    #expect(HeldOutResult.of(latestFailed) == .failed)
    #expect(HeldOutResult.of(M313F.fanningOut) == .notRun)
    #expect(HeldOutResult.of(M313F.build(.queued)) == .notRun)
    let unknownWinner = M313F.build(.ready, attempts: [M313F.attempt(1, .pass, heldOut: true)], winner: "att_9")
    #expect(HeldOutResult.of(unknownWinner) == .passed)
  }

  // MARK: BUDGET

  @Test("BUDGET: \"6m 12s · $0.84 of $4.00\" from the ready fixture, as separate items")
  func budgetFixture() {
    let meter = BudgetMeter(build: M313F.ready, now: M313F.date("2026-11-22T13:00:00Z"))
    #expect(meter.elapsedSeconds == 372)
    #expect(meter.text == "6m 12s · $0.84 of $4.00")
    #expect(meter.items == ["6m 12s", "$0.84 of $4.00"])
    #expect(!meter.atCap)
  }

  @Test("BUDGET: elapsed runs to now while the build has no end; no start shows 0m 00s")
  func budgetRunning() {
    #expect(BudgetMeter(build: M313F.fanningOut, now: M313F.date("2026-11-22T11:53:05Z")).text == "3m 05s · $0.31 of $4.00")
    #expect(BudgetMeter(build: M313F.fanningOut, now: M313F.date("2026-11-22T12:51:00Z")).text == "61m 00s · $0.31 of $4.00")
    #expect(BudgetMeter(build: M313F.build(.queued, started: nil), now: M313F.date("2026-11-22T12:00:00Z")).text
      == "0m 00s · $0.00 of $4.00")
    // A clock behind the start never shows a negative time.
    #expect(BudgetMeter(build: M313F.fanningOut, now: M313F.date("2026-11-22T11:00:00Z")).elapsedSeconds == 0)
  }

  @Test("BUDGET: cents are rounded half up in code")
  func budgetHalfUp() {
    #expect(Money.usd(0.845) == "$0.85")
    #expect(Money.usd(0.835) == "$0.84")
    #expect(Money.usd(1.005) == "$1.01")
    #expect(Money.usd(2.675) == "$2.68")
    #expect(Money.usd(0.004) == "$0.00")
    #expect(Money.usd(0.005) == "$0.01")
    #expect(Money.usd(4) == "$4.00")
    #expect(Money.usd(12.5) == "$12.50")
    #expect(Money.usd(-1) == "$0.00")
    #expect(Money.usd(.nan) == "$0.00")
  }

  @Test("BUDGET: at or over the cap the meter is amber")
  func budgetAtCap() {
    var b = M313F.ready
    b.spentUSD = 3.99
    #expect(!BudgetMeter(build: b, now: M313F.date("2026-11-22T12:00:00Z")).atCap)
    b.spentUSD = 4
    #expect(BudgetMeter(build: b, now: M313F.date("2026-11-22T12:00:00Z")).atCap)
    b.spentUSD = 4.12
    let over = BudgetMeter(build: b, now: M313F.date("2026-11-22T12:00:00Z"))
    #expect(over.atCap)
    #expect(over.text == "6m 12s · $4.12 of $4.00")
  }

  // MARK: SAVING

  @Test("SAVING: before install, the fix's estimate labelled estimated, and the 4 measured weeks")
  func savingEstimate() {
    #expect(SavingLine.make(fix: M313F.fix, installed: false, outcome: .notLoaded)?.text
      == "saves 1.4 h/wk, estimated · measured for 4 weeks after you install")
    var minutes = M313F.fix
    minutes.estimate = Figure(id: "fig_0000000000000003", value: 84, unit: "minutes_per_week", arithmetic: "21 min x 4 = 84 min",
                              evidence: [], sourcePurgedAt: nil)
    #expect(SavingLine.make(fix: minutes, installed: false, outcome: .notLoaded)?.text
      == "saves 1.4 h/wk, estimated · measured for 4 weeks after you install")
    var none = M313F.fix
    none.estimate = nil
    #expect(SavingLine.make(fix: none, installed: false, outcome: .notLoaded)?.text == "measured for 4 weeks after you install")
    #expect(SavingLine.make(fix: nil, installed: false, outcome: .notLoaded)?.text == "measured for 4 weeks after you install")
    var odd = M313F.fix
    odd.estimate = Figure(id: "fig_0000000000000004", value: 3, unit: "count", arithmetic: "3", evidence: [], sourcePurgedAt: nil)
    #expect(SavingLine.make(fix: odd, installed: false, outcome: .notLoaded)?.text == "measured for 4 weeks after you install")
  }

  @Test("SAVING: after install, pending is measuring · week N of 4 from the weeks measured so far")
  func savingPending() {
    #expect(SavingLine.make(fix: M313F.fix, installed: true, outcome: .found(M313F.outcome("pending", weeks: "[]")))?.text
      == "measuring · week 1 of 4")
    #expect(SavingLine.make(fix: M313F.fix, installed: true, outcome: .found(M313F.outcome("pending", weeks: "[30,null,null,null]")))?.text
      == "measuring · week 2 of 4")
    #expect(SavingLine.make(fix: M313F.fix, installed: true, outcome: .found(M313F.outcome("pending", weeks: "[30,28,\"source_purged\",31]")))?.text
      == "measuring · week 4 of 4")
  }

  @Test("SAVING: on track, partial and under say saved … measured next to the estimate, from the outcome's Figures")
  func savingMeasured() {
    for flag in ["on_track", "partial", "under"] {
      #expect(SavingLine.make(fix: M313F.fix, installed: true, outcome: .found(M313F.outcome(flag)))?.text
        == "saved 1.2 h/wk measured · 1.4 h estimated", "\(flag)")
    }
    #expect(SavingLine.make(fix: nil, installed: true, outcome: .found(M313F.outcome("partial", ratio: "0.6")))?.text
      == "saved 0.8 h/wk measured · 1.4 h estimated")
    #expect(SavingLine.make(fix: nil, installed: true, outcome: .found(M313F.outcome("under", ratio: "null")))?.text == "not measured")
  }

  @Test("SAVING: unmeasured says not measured; a 404 outcome route says measured after install, from M4; not loaded shows nothing")
  func savingOtherLines() {
    #expect(SavingLine.make(fix: M313F.fix, installed: true, outcome: .found(M313F.outcome("unmeasured")))?.text == "not measured")
    #expect(SavingLine.make(fix: M313F.fix, installed: true, outcome: .found(M313F.outcome("sideways")))?.text == "not measured")
    #expect(SavingLine.make(fix: M313F.fix, installed: true, outcome: .missing)?.text == "not measured")
    #expect(SavingLine.make(fix: M313F.fix, installed: true, outcome: .routeMissing)?.text == "measured after install, from M4")
    #expect(SavingLine.make(fix: M313F.fix, installed: true, outcome: .notLoaded) == nil)
  }

  // MARK: FIGURES

  /// Every run of digits (with a decimal part) in `texts`.
  static func numbers(_ texts: [String]) -> Set<String> {
    let re = try! Regex("[0-9]+(\\.[0-9]+)?")
    var out = Set<String>()
    for t in texts {
      for m in t.matches(of: re) { out.insert(String(t[m.range])) }
    }
    return out
  }

  @Test("FIGURES: every number in a real build's detail comes from the build, the fix or the outcome")
  func figuresFromFields() {
    let detail = BuildDetail.make(build: M313F.ready, fix: M313F.fix, outcome: .notLoaded, now: M313F.date("2026-11-22T13:00:00Z"),
                                  name: "PR pre-read tool")
    // ordinals and counts (1, 2, 3), the meter (6m 12s, $0.84 of $4.00), the spends, the fingerprint 7c41e2, the fix's
    // estimate 1.4 and the glossary's 4 measured weeks.
    let allowed: Set<String> = ["1", "2", "3", "6", "12", "0.84", "4.00", "0.31", "0.27", "0.26", "7", "41", "1.4", "4"]
    let found = Self.numbers(detail.allText)
    #expect(found.isSubset(of: allowed), "unexpected numbers: \(found.subtracting(allowed))")
    #expect(found.contains("0.84") && found.contains("1.4") && found.contains("12"))
    #expect(detail.provenance == .cloud)
  }

  @Test("FIGURES: change the build's and the fix's fields and every shown number follows them")
  func figuresFollowFields() {
    var b = M313F.ready
    b.spentUSD = 1.23
    b.capUSD = 5
    b.endedAt = "2026-11-22T11:59:30.000Z"
    var f = M313F.fix
    f.estimate = Figure(id: "fig_0000000000000005", value: 2.6, unit: "hours_per_week", arithmetic: "2.6 h", evidence: [],
                        sourcePurgedAt: nil)
    let detail = BuildDetail.make(build: b, fix: f, outcome: .notLoaded, now: M313F.date("2026-11-22T13:00:00Z"), name: "Weekly report")
    #expect(detail.meter.text == "9m 30s · $1.23 of $5.00")
    #expect(detail.saving?.text == "saves 2.6 h/wk, estimated · measured for 4 weeks after you install")
    #expect(detail.title == "Building · Weekly report")
    #expect(!Self.numbers(detail.allText).contains("0.84"))
    #expect(!Self.numbers(detail.allText).contains("1.4"))
    let installed = BuildDetail.make(build: M313F.readyAs(.ready, deployed: true), fix: f, outcome: .found(M313F.outcome("on_track")),
                                     now: M313F.date("2026-11-22T13:00:00Z"), name: "Weekly report")
    #expect(installed.saving?.text == "saved 1.2 h/wk measured · 1.4 h estimated")
  }

  @Test("FIGURES: the sample's numbers come from the labelled sample fixture only, and it is always labelled")
  func figuresSample() {
    let detail = BuildDetail.sample(tick: SampleTimeline.endTick)
    #expect(detail.provenance == .sample)
    #expect(detail.meter.text == "6m 12s · \(Money.usd(SampleBuild.finalCostUSD)) of \(Money.usd(SampleBuild.capUSD))")
    #expect(SampleBuild.finalSeconds == 372)
    #expect(SampleBuild.finalCostUSD == 0.84)
    #expect(SampleBuild.testsWritten == SampleTimeline.workers.reduce(0) { $0 + $1.total })
    #expect(SampleBuild.testsWritten == 47)
    let allowed = Set<String>(["6", "12", "0.84", "4.00", "47", "7", "41", "2", "1.4", "4", "8"])
      .union(SampleTimeline.workers.map { "\($0.total)" })
    let found = Self.numbers(detail.allText)
    #expect(found.isSubset(of: allowed), "unexpected numbers: \(found.subtracting(allowed))")
  }

  // MARK: COPY

  @Test("COPY: every string has no em dash, banned word, ADR 0016 term, exclamation mark or internal term")
  func copyRules() {
    let banned = try! Regex("(?i)\\b(generous|unlock|seamless|powerful|at scale|robust|everything you need|built for teams that)\\b")
    let adr0016 = try! Regex("(?i)" + "dry" + "[ _-]?" + "run|" + "preview" + " run")
    let internalTerms = try! Regex("\\b(MCP|token|tokens|LLM|gate|OCR|TCC|ingest|tenant|pseudonym|JCS|hash|sha256)\\b")
    let detail = BuildDetail.make(build: M313F.ready, fix: M313F.fix, outcome: .notLoaded, now: M313F.date("2026-11-22T13:00:00Z"),
                                  name: "PR pre-read tool")
    let all = BuildCopy.all + detail.allText.filter { $0 != HeadlineMap.note(M313F.ready) } + BuildDetail.sample(tick: 40).allText
    #expect(BuildCopy.all.count > 40)
    for s in all {
      #expect(!s.contains("\u{2014}"), "em dash: \(s)")
      #expect(s.firstMatch(of: banned) == nil, "banned word: \(s)")
      #expect(s.firstMatch(of: adr0016) == nil, "ADR 0016 term: \(s)")
      #expect(s.firstMatch(of: internalTerms) == nil, "internal term: \(s)")
      #expect(!s.contains("!"), "exclamation mark: \(s)")
    }
  }

  @Test("COPY: captions are lowercase (Mac and M4 aside) and their · facts split into separate items")
  func copyCaptions() {
    #expect(!BuildCopy.captions.isEmpty)
    for c in BuildCopy.captions {
      let plain = c.replacingOccurrences(of: "Mac", with: "mac").replacingOccurrences(of: "M4", with: "m4")
      #expect(plain == plain.lowercased(), "not lowercase: \(c)")
      for item in MetaItems.split(c) {
        #expect(!item.contains("·"), "dotted item: \(item)")
      }
    }
    #expect(MetaItems.split(BuildCopy.measuring(week: 2)) == ["measuring", "week 2 of 4"])
    #expect(MetaItems.split(BuildCopy.failedFixing(1)) == ["1 failed", "builder is fixing it"])
    #expect(BuildCopy.installed(version: 1) == "Installed · version 1")
  }

  @Test("COPY: needs-cloud lines and the plan's lines read as the SPEC says")
  func copyLines() {
    #expect(BuildCopy.repeatNeedsCloud("Weekly report")
      == "Building “Weekly report” needs the cloud. This sample shows what a build looks like.")
    #expect(BuildCopy.installNeedsCloud == "Installing needs the cloud.")
    #expect(BuildCopy.installNeedsEnrollment == "Installing needs this Mac to be enrolled.")
    #expect(BuildCopy.connectFirst(["google_sheets"]) == "Connect Google Sheets first.")
    #expect(BuildCopy.connectFirst(["github", "slack"]) == "Connect GitHub and Slack first.")
    #expect(BuildCopy.connectFirst(["a", "b", "c"]) == "Connect A, B and C first.")
    #expect(BuildCopy.designing == "Designing the fix…")
    #expect(BuildCopy.stillDesigning == "Still designing. Check back later.")
    #expect(BuildCopy.noBuilds == "No builds yet. Press OK, build on a suggested fix in Today.")
    #expect(BuildCopy.offline == "Can't reach Offload. Retrying.")
    #expect(BuildCopy.gone == "This build is no longer available.")
  }
}
