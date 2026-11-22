import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// The pure half of Today: TodayContent's builders, the day grid, the menu line and the copy. Every number checked here
// comes from m3-10's engine or a fixture Figure.

extension M311 {
  // MARK: HEADER

  @Test("HEADER: 7 h 40 m of work. from a fixture day, with Most of it in Xcode. at 41% of the active time")
  func headerFromFixture() throws {
    let c = try #require(M311Fixture.local(M311Fixture.snapshot([M311Fixture.workday])))
    #expect(c.headline == "7 h 40 m of work.")
    #expect(c.headlineMost == "Most of it in Xcode.")
    #expect(c.headlineFigure == M311Fixture.workday.activeSeconds)
  }

  @Test("HEADER: no app at 40% or more gives no Most of it line")
  func headerNoMostly() throws {
    let c = try #require(M311Fixture.local(M311Fixture.snapshot([M311Fixture.spreadDay])))
    #expect(c.headline == "4 h of work.")
    #expect(c.headlineMost == nil)
  }

  @Test("HEADER: the subtitle items are longest focus and switches an hour, each from its Figure")
  func headerSubtitle() throws {
    let day = M311Fixture.workday
    let c = try #require(M311Fixture.local(M311Fixture.snapshot([day])))
    #expect(c.subtitleItems.map(\.text) == ["longest focus 1 h 30 m", TodayCopy.switchesAnHour(day.switchesPerActiveHour.value)])
    #expect(c.subtitleItems.map(\.figure) == [day.longestFocus, day.switchesPerActiveHour])
    #expect(TodayCopy.switchesAnHour(38) == "38 switches an hour")
    #expect(TodayCopy.switchesAnHour(10.9) == "10.9 switches an hour")
    #expect(TodayCopy.longestFocus(minutes: 90) == "longest focus 1 h 30 m")
  }

  @Test("HEADER: zero active time builds no content (the empty state), never 0 h")
  func headerZero() {
    let empty = LocalInsights.day([], day: M311Clock.today, timeZone: M311Clock.utc, exclusions: [])
    #expect(M311Fixture.local(M311Fixture.snapshot([empty])) == nil)
    #expect(M311Fixture.local(.empty) == nil)
    #expect(TodayCopy.duration(minutes: 460) == "7 h 40 m")
    #expect(TodayCopy.duration(minutes: 45) == "45 m")
    #expect(TodayCopy.duration(minutes: 120) == "2 h")
  }

  // MARK: DAY

  @Test("DAY: the title says Today · Thu, Nov 12 for today and Thu, Nov 5 for an earlier day")
  func dayTitle() throws {
    #expect(TodayCopy.title(day: "2026-11-12", today: "2026-11-12", timeZone: M311Clock.utc) == "Today · Thu, Nov 12")
    #expect(TodayCopy.title(day: "2026-11-05", today: "2026-11-12", timeZone: M311Clock.utc) == "Thu, Nov 5")
    let snap = M311Fixture.snapshot([M311Fixture.nov5, M311Fixture.workday])
    #expect(M311Fixture.local(snap)?.title == "Today · Thu, Nov 12")
    #expect(M311Fixture.local(snap, day: "2026-11-05")?.title == "Thu, Nov 5")
  }

  // MARK: GRID

  @Test("GRID: 9:00 to 18:00 is 36 cells of 15 minutes; the default rhythm is used without one")
  func gridDefault() throws {
    let g = DayGrid.build(day: M311Fixture.workday, rhythm: nil)
    #expect(g.startMinute == 9 * 60)
    #expect(g.endMinute == 18 * 60)
    #expect(g.cellCount == 36)
    #expect(g.rows.allSatisfy { $0.cells.count == 36 })
    #expect(g.bursts.count == 36)
    let custom = DayGrid.build(day: M311Fixture.workday, rhythm: Rhythm(start: "08:00", end: "18:00"))
    #expect(custom.cellCount == 40)
  }

  @Test("GRID: activity at 7:40 widens the grid to whole hours (7:00); activity to 19:10 widens it to 20:00")
  func gridWidened() throws {
    let day = M311Fixture.day(M311Clock.today, [(7, 40, [(M311App.xcode, nil, 30)]), (18, 30, [(M311App.slack, nil, 40)])])
    let g = DayGrid.build(day: day, rhythm: nil)
    #expect(g.startMinute == 7 * 60)
    #expect(g.endMinute == 20 * 60)
    #expect(g.cellCount == 52)
    #expect(g.hourLabels.first == "7a")
    #expect(g.hourLabels.last == "7p")
    // 7:40 is cell 2 (7:30 to 7:45): 5 minutes of Xcode in it.
    let xcode = try #require(g.rows.first { $0.name == "Xcode" })
    #expect(xcode.cells[2])
    #expect(!xcode.cells[1])
  }

  @Test("GRID: a cell goes to the row with the most seconds in it, and only at 60 s or more")
  func gridCellRule() throws {
    // 9:00 Xcode 10 min, Slack 5 min (cell 0: Xcode wins); 9:30 Mail 50 s, then idle (cell 2: under 60 s, empty).
    var e = M311Events()
    e.session(M311Clock.date(2026, 11, 12, 9, 0), [(M311App.xcode, nil, 10), (M311App.slack, nil, 5)])
    let base = M311Clock.date(2026, 11, 12, 9, 30)
    var events = e.events
    // A 50 s Mail span at 9:30: idle_start is written 120 s after the last activity.
    events.append(InsightEvent(id: "m-1", ts: base, kind: .idleEnd, origin: .imported("imp-2")))
    events.append(InsightEvent(id: "m-2", ts: base, kind: .focus, appBundleID: M311App.mail.0, appName: M311App.mail.1, origin: .imported("imp-2")))
    events.append(InsightEvent(id: "m-3", ts: base.addingTimeInterval(170), kind: .idleStart, origin: .imported("imp-2")))
    let day = LocalInsights.day(events, day: M311Clock.today, timeZone: M311Clock.utc, exclusions: [])
    let g = DayGrid.build(day: day, rhythm: nil)
    let xcode = try #require(g.rows.first { $0.name == "Xcode" })
    let slack = try #require(g.rows.first { $0.name == "Slack" })
    let mail = try #require(g.rows.first { $0.name == "Mail" })
    #expect(xcode.cells[0])
    #expect(!slack.cells[0])
    #expect(!xcode.cells[1] && !slack.cells[1])
    // Cell 2 (9:30 to 9:45) holds 50 s of Mail: under 60 s, so no row has it.
    #expect(!mail.cells[2])
    #expect(g.rows.allSatisfy { !$0.cells[2] })
  }

  @Test("GRID: the rows are the day's top 5 apps, then Other for the rest")
  func gridRows() throws {
    let apps = [M311App.xcode, M311App.slack, M311App.mail, M311App.safari, M311App.notes, M311App.figma, M311App.terminal]
    let steps: [M311Step] = apps.enumerated().map { i, a in (app: a, host: nil, minutes: 40 - i * 4) }
    let day = M311Fixture.day(M311Clock.today, [(9, 0, steps)])
    let g = DayGrid.build(day: day, rhythm: nil)
    #expect(g.rows.map(\.name) == ["Xcode", "Slack", "Mail", "Safari", "Notes", "Other"])
    let other = try #require(g.rows.last)
    // Figma (20 min) and Terminal (16 min) are Other: their cells are drawn in Other's row.
    #expect(other.cells.contains(true))
    #expect(other.colorHex == DayGrid.otherColor)
  }

  @Test("GRID: the Switch bursts row marks cells with 4 or more app switches")
  func gridBursts() throws {
    // 9:00 to 9:15: five 3-minute steps across apps (4 switches); 10:00 to 10:15: three steps (2 switches).
    let burst: [M311Step] = [(M311App.xcode, nil, 3), (M311App.slack, nil, 3), (M311App.mail, nil, 3),
                             (M311App.safari, nil, 3), (M311App.notes, nil, 3)]
    let calm: [M311Step] = [(M311App.xcode, nil, 5), (M311App.slack, nil, 5), (M311App.mail, nil, 5)]
    let day = M311Fixture.day(M311Clock.today, [(9, 0, burst), (10, 0, calm)])
    let g = DayGrid.build(day: day, rhythm: nil)
    #expect(g.bursts[0])
    #expect(!g.bursts[4])
    #expect(g.bursts.filter { $0 }.count == 1)
    #expect(DayGrid.burstSwitches == 4)
  }

  @Test("GRID: the hour axis reads 9a, 10a, 11a, 12p, 1p … 5p")
  func gridAxis() {
    let g = DayGrid.build(day: M311Fixture.workday, rhythm: nil)
    #expect(g.hourLabels == ["9a", "10a", "11a", "12p", "1p", "2p", "3p", "4p", "5p"])
    #expect(DayGrid.hourLabel(0) == "12a")
    #expect(DayGrid.hourLabel(12) == "12p")
    #expect(DayGrid.hourLabel(23) == "11p")
  }

  @Test("GRID: row colours follow the mockup's order: blue, cyan, amber, purple b48cff, green")
  func gridColours() {
    #expect(DayGrid.palette == [Tokens.Palette.working, Tokens.Palette.cyan, Tokens.Palette.needsYou, 0xB48CFF, Tokens.Palette.done])
    let g = DayGrid.build(day: M311Fixture.workday, rhythm: nil)
    for (i, row) in g.rows.enumerated() where row.name != TodayCopy.other {
      #expect(row.colorHex == DayGrid.palette[i])
    }
  }

  @Test("GRID: cells pop in on a stagger; Reduce Motion shows the final state at once")
  func gridMotion() {
    #expect(DayGrid.appearDelay(cell: 0, row: 0, reduceMotion: false) == 0)
    #expect(DayGrid.appearDelay(cell: 10, row: 2, reduceMotion: false) > DayGrid.appearDelay(cell: 1, row: 0, reduceMotion: false))
    #expect(DayGrid.appearDelay(cell: 10, row: 2, reduceMotion: true) == 0)
  }

  // MARK: DID

  @Test("DID: sessions of 10 minutes or more, with start time and duration")
  func didRows() throws {
    let day = M311Fixture.day(M311Clock.today, [
      (9, 0, [(M311App.xcode, nil, 65)]),
      (10, 30, [(M311App.slack, nil, 8)]),
      (13, 0, [(M311App.mail, nil, 60)]),
    ])
    let c = try #require(M311Fixture.local(M311Fixture.snapshot([day])))
    #expect(c.did.map(\.start) == ["9:00a", "1:00p"])
    #expect(c.did.map(\.duration) == ["1 h 05 m", "1 h 00 m"])
    #expect(c.did.map(\.name) == ["Xcode", "Mail"])
  }

  @Test("DID: a name is the session's top app and top host, never text")
  func didNames() throws {
    var e = M311Events()
    e.session(M311Clock.date(2026, 11, 12, 9), [(M311App.xcode, nil, 30), (M311App.safari, "github.com", 20)])
    // A title is present in the events but never used for a name.
    let withTitles = e.events.map { ev -> InsightEvent in
      var x = ev
      if x.kind == .focus { x.title = "Invoice 2041 for <email:h_0123456789abcdef>" }
      return x
    }
    let day = LocalInsights.day(withTitles, day: M311Clock.today, timeZone: M311Clock.utc, exclusions: [])
    let c = try #require(M311Fixture.local(M311Fixture.snapshot([day])))
    #expect(c.did.map(\.name) == ["Xcode and github.com"])
    #expect(!c.did.contains { $0.name.contains("Invoice") })
    #expect(TodayCopy.sessionName(app: "Xcode", host: "github.com") == "Xcode and github.com")
    #expect(TodayCopy.sessionName(app: "Xcode", host: nil) == "Xcode")
  }

  @Test("DID: a session in an excluded app shows Never watch app")
  func didExcluded() throws {
    let rules = [ImportExclusionRule(kind: .bundleID, value: M311App.slack.0, appName: M311App.slack.1)]
    let day = M311Fixture.day(M311Clock.today, [(9, 0, [(M311App.slack, nil, 30)])], rules: rules)
    let c = try #require(M311Fixture.local(M311Fixture.snapshot([day])))
    #expect(c.did.map(\.name) == ["Never watch app"])
    #expect(c.headlineMost == nil)
  }

  // MARK: REPEATS

  @Test("REPEATS: the top 5 of the shown week, in rank order")
  func repeatsTop5() throws {
    let snap = M311Fixture.snapshot([M311Fixture.workday], repeats: [M311Fixture.reviewRepeat] + M311Fixture.moreRepeats)
    let c = try #require(M311Fixture.local(snap))
    #expect(c.repeats.map(\.key) == ["k_aaaaaaaaaaaa", "k_bbbbbbbbbbbb", "k_cccccccccccc", "k_dddddddddddd", "k_eeeeeeeeeeee"])
    #expect(!c.repeats.contains { $0.key == "k_gggggggggggg" })
  }

  @Test("REPEATS: the Mon to Sun strip counts occurrences per day of the shown week")
  func repeatsStrip() throws {
    let c = try #require(M311Fixture.local(M311Fixture.snapshot([M311Fixture.workday], repeats: [M311Fixture.reviewRepeat])))
    #expect(c.repeats.first?.strip == [1, 1, 2, 2, 0, 0, 0])
  }

  @Test("REPEATS: 6× · 3.1 h from the week's Figures")
  func repeatsCount() throws {
    let c = try #require(M311Fixture.local(M311Fixture.snapshot([M311Fixture.workday], repeats: [M311Fixture.reviewRepeat])))
    let r = try #require(c.repeats.first)
    #expect(r.count == "6× · 3.1 h")
    #expect(r.times.value == 6)
    #expect(r.minutes.value == 186)
    #expect(r.times.arithmetic == "Mon 1 + Tue 1 + Wed 2 + Thu 2 = 6 times")
    #expect(TodayCopy.repeatCount(times: 6, minutes: 186) == "6× · 3.1 h")
  }

  @Test("REPEATS: a repeat declined on this Mac is not listed (ranked declined, or answered now)")
  func repeatsDeclined() throws {
    let declined = M311Fixture.pattern(key: "k_declined0000", name: "Declined", occurrences: [("2026-11-10", 30)], score: 0, penalty: 0)
    let answer = LocalReviewAnswer(isoWeek: M311Clock.week, subjectKey: "k_aaaaaaaaaaaa", answer: .leaveAlone,
                                   answeredAt: M311Clock.now, minutesPerWeek: 186)
    let snap = M311Fixture.snapshot([M311Fixture.workday], repeats: [M311Fixture.reviewRepeat, declined] + M311Fixture.moreRepeats)
    let c = try #require(M311Fixture.local(snap, answers: [answer]))
    #expect(!c.repeats.contains { $0.key == "k_declined0000" })
    #expect(!c.repeats.contains { $0.key == "k_aaaaaaaaaaaa" })
    #expect(c.repeats.first?.key == "k_bbbbbbbbbbbb")
  }

  // MARK: HOW

  @Test("HOW: every repeat row has a how line from its Figure's arithmetic with the weekdays")
  func howLines() throws {
    let snap = M311Fixture.snapshot([M311Fixture.workday], repeats: [M311Fixture.reviewRepeat] + M311Fixture.moreRepeats)
    let c = try #require(M311Fixture.local(snap))
    #expect(c.repeats.first?.how == "how: 6 times · 31 min median · 186 min = 3.1 h · Mon–Thu")
    for r in c.repeats {
      #expect(r.how.hasPrefix("how: "))
      #expect(r.how.contains(r.minutes.arithmetic))
    }
    #expect(TodayCopy.weekdays([1, 1, 2, 2, 0, 0, 0]) == "Mon–Thu")
    #expect(TodayCopy.weekdays([1, 0, 1, 0, 1, 0, 0]) == "Mon, Wed, Fri")
    #expect(TodayCopy.weekdays([0, 3, 0, 0, 0, 0, 0]) == "Tue")
    #expect(TodayCopy.weekdays([0, 0, 0, 0, 0, 0, 0]) == nil)
  }

  // MARK: FIX

  @Test("FIX: the local card is the top undeclined repeat of the week, with no options")
  func fixLocal() throws {
    let snap = M311Fixture.snapshot([M311Fixture.workday], repeats: [M311Fixture.reviewRepeat] + M311Fixture.moreRepeats)
    let c = try #require(M311Fixture.local(snap))
    let card = try #require(c.fix)
    #expect(card.title == "You've done Xcode, then github.com in Safari, then Slack 6 times this week.")
    #expect(card.status == "Top repeat · counted on this Mac")
    #expect(card.options.isEmpty)
    #expect(card.source == .localRepeat(key: "k_aaaaaaaaaaaa", name: "Xcode, then github.com in Safari, then Slack",
                                        minutesPerWeek: 186, isoWeek: M311Clock.week))
    #expect(card.primaryLabel(selected: nil) == "OK, build")
  }

  @Test("FIX: the cloud card shows up to 3 options by number, with savings and recommended, then Leave it alone")
  func fixCloud() throws {
    let options = (1...4).map { n in
      FixOption(id: "fix_\(n)", optionNo: n, title: "Option \(n)", detail: "detail \(n)", recommended: n == 2,
                estimate: M311Cloud.fig(Double(n) / 2, "hours_per_week", "estimate \(n)"))
    }
    let opp = M311Cloud.opportunity("opp_1", rank: 1, options: options)
    let c = try #require(TodayContent.cloud(day: M311Cloud.day(), week: M311Cloud.week(), opportunities: [opp],
                                            today: M311Clock.today, timeZone: M311Clock.utc))
    let card = try #require(c.fix)
    #expect(card.options.map(\.title) == ["Option 1", "Option 2", "Option 3", "Leave it alone"])
    #expect(card.options.map(\.number) == [1, 2, 3, 4])
    #expect(card.options.map(\.saves) == ["saves 0.5 h/wk", "saves 1 h/wk", "saves 1.5 h/wk", nil])
    #expect(card.options.map(\.recommended) == [false, true, false, false])
    #expect(card.options.last?.leavesAlone == true)
    #expect(card.options.last?.detail == "it's the job · stop suggesting this")
    #expect(card.defaultSelection == 1)
    #expect(card.status == "Suggested fix · ranked first for ship a product")
    #expect(card.title == "You've reviewed agent PRs 6 times this week.")
  }

  @Test("FIX: picking Leave it alone turns the primary button into Leave it alone")
  func fixLeaveAloneLabel() throws {
    let c = try #require(TodayContent.cloud(day: M311Cloud.day(), week: nil, opportunities: [M311Cloud.opportunity("opp_1", rank: 1)],
                                            today: M311Clock.today, timeZone: M311Clock.utc))
    let card = try #require(c.fix)
    #expect(card.options.map(\.title) == ["A checklist tool that pre-reads each agent PR", "Batch reviews into one 45-min block", "Leave it alone"])
    #expect(card.primaryLabel(selected: 0) == "OK, build")
    #expect(card.primaryLabel(selected: 2) == "Leave it alone")
    // A leave_alone option sent by the server is that choice (not a second one).
    let server = M311Cloud.opportunity("opp_2", rank: 1, options: [
      FixOption(id: "fix_a", optionNo: 1, title: "A routine", recommended: true),
      FixOption(id: "fix_la", optionNo: 2, title: "Leave it alone", detail: "it's the job", kind: "leave_alone"),
    ])
    let c2 = try #require(TodayContent.cloud(day: M311Cloud.day(), week: nil, opportunities: [server], today: M311Clock.today,
                                             timeZone: M311Clock.utc))
    #expect(c2.fix?.options.map(\.id) == ["fix_a", "fix_la"])
    #expect(c2.fix?.primaryLabel(selected: 1) == "Leave it alone")
  }

  @Test("FIX: no card when nothing qualifies (no repeat this week, every one declined, no open opportunity)")
  func fixNone() throws {
    let c = try #require(M311Fixture.local(M311Fixture.snapshot([M311Fixture.workday])))
    #expect(c.fix == nil)
    let declined = M311Fixture.pattern(key: "k_x00000000000", name: "X", occurrences: [("2026-11-10", 30)], score: 0, penalty: 0)
    #expect(M311Fixture.local(M311Fixture.snapshot([M311Fixture.workday], repeats: [declined]))?.fix == nil)
    let cloud = try #require(TodayContent.cloud(day: M311Cloud.day(), week: nil, opportunities: [], today: M311Clock.today,
                                                timeZone: M311Clock.utc))
    #expect(cloud.fix == nil)
    var shipped = M311Cloud.opportunity("opp_s", rank: 1)
    shipped.state = .shipped
    #expect(TodayContent.cloud(day: M311Cloud.day(), week: nil, opportunities: [shipped], today: M311Clock.today,
                               timeZone: M311Clock.utc)?.fix == nil)
  }

  @Test("FIX: the cloud card is the open opportunity ranked first, without a goal the status says Suggested fix")
  func fixCloudRank() throws {
    let opps = [M311Cloud.opportunity("opp_3", rank: 3), M311Cloud.opportunity("opp_none", rank: nil),
                M311Cloud.opportunity("opp_1", rank: 1, goal: nil)]
    let c = try #require(TodayContent.cloud(day: M311Cloud.day(), week: nil, opportunities: opps, today: M311Clock.today,
                                            timeZone: M311Clock.utc))
    #expect(c.fix?.source == .opportunity(id: "opp_1"))
    #expect(c.fix?.status == "Suggested fix")
  }

  // MARK: CLOUD (pure mapping)

  @Test("CLOUD: the day record maps to the header, Time by kind and What you did")
  func cloudDay() throws {
    let c = try #require(TodayContent.cloud(day: M311Cloud.day(), week: M311Cloud.week(), opportunities: [],
                                            today: M311Clock.today, timeZone: M311Clock.utc))
    #expect(c.title == "Today · Thu, Nov 12")
    #expect(c.headline == "7 h 40 m of work.")
    #expect(c.subtitleItems.map(\.text) == ["2 focus blocks", "38 switches an hour"])
    #expect(c.grid == nil)
    #expect(c.kinds.map(\.kind) == ["Code", "Docs", "Email"])
    #expect(c.kinds.map(\.duration) == ["3 h 20 m", "2 h", "1 h"])
    #expect(c.kinds.map(\.colorHex) == Array(DayGrid.palette.prefix(3)))
    #expect(c.did.map(\.name) == ["Reconcile invoices", "Review agent PRs"])
    #expect(c.did.map(\.duration) == ["1 h 05 m", "1 h 30 m"])
    #expect(c.did.allSatisfy { $0.start == nil })
    #expect(c.provenance == .cloud)
  }

  @Test("CLOUD: the week record's tasks with 2 or more instances are the repeats, by minutes, with their how lines")
  func cloudWeek() throws {
    let c = try #require(TodayContent.cloud(day: M311Cloud.day(), week: M311Cloud.week(), opportunities: [],
                                            today: M311Clock.today, timeZone: M311Clock.utc))
    #expect(c.repeats.map(\.name) == ["Review agent PRs", "Reconcile invoices", "Customer follow-up"])
    #expect(c.repeats.map(\.count) == ["6× · 3.1 h", "3× · 1 h", "5× · 0.8 h"])
    #expect(c.repeats.allSatisfy { $0.strip == nil })
    #expect(c.repeats.first?.how == "how: sum of the task's instances = 6.0 · sum of the task's minutes = 186.0 min")
  }

  @Test("CLOUD: zero active minutes builds no content")
  func cloudZero() {
    #expect(TodayContent.cloud(day: M311Cloud.day(activeMinutes: 0), week: nil, opportunities: [], today: M311Clock.today,
                               timeZone: M311Clock.utc) == nil)
  }

  // MARK: MENU

  @Test("MENU: today · 3 h 10 m · mostly Xcode from a fixture day")
  func menuLine() {
    let day = M311Fixture.day(M311Clock.today, [(9, 0, [(M311App.xcode, nil, 120)]), (13, 0, [(M311App.slack, nil, 70)])])
    let line = TodayMenuSummary.line(snapshot: M311Fixture.snapshot([day]), day: M311Clock.today)
    #expect(line == "today · 3 h 10 m · mostly Xcode")
    #expect(MetaItems.split(line ?? "") == ["today", "3 h 10 m", "mostly Xcode"])
  }

  @Test("MENU: nil when nothing was counted today")
  func menuNil() {
    #expect(TodayMenuSummary.line(snapshot: M311Fixture.snapshot([M311Fixture.nov5]), day: M311Clock.today) == nil)
    #expect(TodayMenuSummary.line(snapshot: .empty, day: M311Clock.today) == nil)
  }

  @Test("MENU: the cloud line from the day record; nil for zero minutes")
  func menuCloud() {
    #expect(TodayMenuSummary.line(record: M311Cloud.day()) == "today · 7 h 40 m")
    #expect(TodayMenuSummary.line(record: M311Cloud.day(activeMinutes: 0)) == nil)
  }

  // MARK: FIGURES

  @Test("FIGURES: every number in the local content traces to a Figure with arithmetic and evidence")
  func figuresLocal() throws {
    let snap = M311Fixture.snapshot([M311Fixture.workday], repeats: [M311Fixture.reviewRepeat] + M311Fixture.moreRepeats)
    let c = try #require(M311Fixture.local(snap))
    #expect(!c.figures.isEmpty)
    for f in c.figures {
      #expect(!f.arithmetic.isEmpty, "no arithmetic: \(f.id)")
      #expect(!f.evidence.isEmpty, "no evidence: \(f.arithmetic)")
      #expect(f.id.hasPrefix("fig_"))
    }
    #expect(c.headline == TodayCopy.headline(minutes: TodayCopy.minutes(seconds: c.headlineFigure.value)))
    for row in c.did { #expect(row.duration == TodayCopy.paddedDuration(minutes: TodayCopy.minutes(seconds: row.figure.value))) }
    for r in c.repeats { #expect(r.count == TodayCopy.repeatCount(times: Int(r.times.value), minutes: r.minutes.value)) }
    for item in c.subtitleItems { #expect(c.figures.contains(item.figure)) }
    #expect(c.grid?.rows.allSatisfy { row in row.figure.map { c.figures.contains($0) } ?? false } == true)
  }

  @Test("FIGURES: every number in the cloud content traces to a Figure")
  func figuresCloud() throws {
    let c = try #require(TodayContent.cloud(day: M311Cloud.day(), week: M311Cloud.week(),
                                            opportunities: [M311Cloud.opportunity("opp_1", rank: 1)], today: M311Clock.today,
                                            timeZone: M311Clock.utc))
    for f in c.figures {
      #expect(!f.arithmetic.isEmpty)
      #expect(!f.evidence.isEmpty)
    }
    for k in c.kinds { #expect(c.figures.contains(k.figure)) }
    for o in c.fix?.options ?? [] where o.saves != nil { #expect(o.saving.map { c.figures.contains($0) } == true) }
  }

  // MARK: COPY

  @Test("COPY: Today's strings have no em dash, no banned word, no exclamation mark and none of the ADR 0016 terms")
  func copyRules() {
    let banned = try! Regex("(?i)\\b(generous|unlock|seamless|powerful|at scale|robust|everything you need|built for teams that)\\b")
    let removed = try! Regex("(?i)" + "dry" + "[ _-]?" + "run|" + "preview" + " run")
    let all = TodayCopy.all
    #expect(all.count > 30)
    for s in all {
      #expect(!s.contains("\u{2014}"), "em dash: \(s)")
      #expect(s.firstMatch(of: banned) == nil, "banned word: \(s)")
      #expect(s.firstMatch(of: removed) == nil, "ADR 0016 term: \(s)")
      #expect(!s.contains("!"), "exclamation mark: \(s)")
    }
  }

  @Test("COPY: captions are lowercase (Today and Mac aside), with · items that split into separate items")
  func copyCaptions() {
    #expect(!TodayCopy.captions.isEmpty)
    for c in TodayCopy.captions {
      let bare = c.replacingOccurrences(of: "Today", with: "").replacingOccurrences(of: "Mac", with: "")
      #expect(bare == bare.lowercased(), "not lowercase: \(c)")
      if c.contains("·") { #expect(MetaItems.split(c).count >= 2, "items: \(c)") }
    }
    #expect(TodayCopy.importing(file: 3, of: 12) == "reading file 3 of 12 · Today updates when it's done")
    #expect(TodayCopy.keysHint(count: 3) == "1 / 2 / 3 to pick · ↵ to build")
    #expect(TodayCopy.saves(hoursPerWeek: 1.4) == "saves 1.4 h/wk")
  }

  @Test("COPY: the empty, not recorded and failed lines are the SPEC's sentences and hold no number")
  func copySentences() {
    #expect(TodayCopy.emptyTitle == "Nothing counted yet.")
    #expect(TodayCopy.emptyBody == "Import a recordings folder, or keep working with capture on.")
    #expect(TodayCopy.chooseRecordings == "Choose recordings")
    #expect(TodayCopy.notRecorded == "Nothing recorded for this day yet.")
    #expect(TodayCopy.signInAgain == "Sign in again to see Today.")
    #expect(TodayCopy.offline == "Can't reach Offload. Showing nothing rather than old numbers.")
    #expect(TodayCopy.couldNotLoad("server_error") == "Today could not load (server_error).")
    for s in [TodayCopy.emptyTitle, TodayCopy.emptyBody, TodayCopy.notRecorded, TodayCopy.signInAgain, TodayCopy.offline] {
      #expect(s.rangeOfCharacter(from: .decimalDigits) == nil, "a number in: \(s)")
    }
  }
}
