import Foundation
import Testing
@testable import OffloadMac

// Copy rules (ONBOARDING section 13, PRODUCT copy rules) and the s33 design pieces MIGRATION 5.1 carries as red
// tests (release/mac-testable slices/s33-mac-ui-audit/tests/S33Tests.swift), re-pinned to the pricing v3 palette.

enum M304Color {
  static func rgb(_ hex: UInt32) -> (Double, Double, Double) {
    (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
  }
  static func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
  static func luminance(_ hex: UInt32) -> Double {
    let c = rgb(hex)
    return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
  }
  static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    let la = luminance(a), lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  }
}

extension M304 {
  @Test("COPY: onboarding strings contain no em dash, no banned word and none of the ADR 0016 terms")
  func copyRules() {
    let banned = try! Regex("(?i)\\b(generous|unlock|seamless|powerful|at scale|robust|everything you need|built for teams that)\\b")
    let dry = try! Regex("(?i)" + "dry" + "[ _-]?" + "run|" + "preview" + " run")
    let all = OnboardingCopy.allStrings
    #expect(all.count > 60)
    for s in all {
      #expect(!s.contains("\u{2014}"), "em dash: \(s)")
      #expect(s.firstMatch(of: banned) == nil, "banned word: \(s)")
      #expect(s.firstMatch(of: dry) == nil, "ADR 0016 term: \(s)")
      #expect(!s.contains("!"), "exclamation mark: \(s)")
    }
  }

  @Test("COPY: no internal terms on screen; captions, remarks and the invitation are lowercase")
  func copyTerms() {
    let internalTerms = try! Regex("\\b(MCP|token|tokens|LLM|gate|OCR|TCC|ingest|tenant)\\b")
    for s in OnboardingCopy.allStrings {
      #expect(s.firstMatch(of: internalTerms) == nil, "internal term: \(s)")
    }
    #expect(!OnboardingCopy.captions.isEmpty)
    for c in OnboardingCopy.captions + [OnboardingCopy.invitation] {
      #expect(c == c.lowercased(), "not lowercase: \(c)")
    }
    for c in OnboardingCopy.captions where c.contains(" · ") {
      #expect(MetaItems.split(c).count >= 2)
    }
    #expect(OnboardingCopy.whatItWatchesHeadline == "It watches how you work. It keeps none of what you type.")
    #expect(OnboardingCopy.whatItWatchesCaption == "counted on your mac · nothing is sent until you say so")
    #expect(OnboardingCopy.lastTenCaption == "counted on your mac from the last 10 minutes · no model call · nothing sent")
  }

  @Test("TOKENS: the palette has the pricing v3 values")
  func palette() {
    #expect(Tokens.Palette.paper == 0xF4F5F2)
    #expect(Tokens.Palette.paper2 == 0xECEEE9)
    #expect(Tokens.Palette.ink == 0x0B1220)
    #expect(Tokens.Palette.ink2 == 0x3A4552)
    #expect(Tokens.Palette.muted == 0x5D6874)
    #expect(Tokens.Palette.rule == 0xDDE2DF)
    #expect(Tokens.Palette.chrome == 0x0C1422)
    #expect(Tokens.Palette.chrome2 == 0x151F2F)
    #expect(Tokens.Palette.chromeInk == 0xEEF2F6)
    #expect(Tokens.Palette.chromeMute == 0x93A0B0)
    #expect(Tokens.Palette.cyan == 0x67E8F9)
    // Blue is working, amber needs you, green is done.
    #expect(Tokens.Palette.working == 0x4C8DFF)
    #expect(Tokens.Palette.needsYou == 0xF2B33D)
    #expect(Tokens.Palette.done == 0x3FCF8E)
  }

  @Test("TOKENS: text reaches 4.5:1 on paper and on the dark chrome")
  func contrastPairs() {
    let p = Tokens.Palette.self
    for fg in [p.ink, p.ink2, p.muted] {
      for bg in [p.paper, p.paper2] {
        #expect(M304Color.contrast(fg, bg) >= 4.5, "\(String(fg, radix: 16)) on \(String(bg, radix: 16))")
      }
    }
    for fg in [p.chromeInk, p.chromeMute, p.cyan, p.working, p.needsYou, p.done] {
      for bg in [p.chrome, p.chrome2] {
        #expect(M304Color.contrast(fg, bg) >= 4.5, "\(String(fg, radix: 16)) on \(String(bg, radix: 16))")
      }
    }
    #expect(abs(ColorMath.contrast(p.ink, p.paper) - M304Color.contrast(p.ink, p.paper)) < 1e-9)
  }

  @Test("TOKENS: the hero is display size, weight 500 (no bold), tight tracking, and in the scale")
  func heroType() {
    let h = Tokens.TypeScale.heroDisplay
    #expect(h.size >= 56 && h.size <= 64)
    #expect(h.weight == 500)
    #expect(h.tracking < 0)
    #expect(Tokens.TypeScale.all.contains(h))
    #expect(h.size > Tokens.TypeScale.hero.size)
    #expect(Tokens.TypeScale.all.allSatisfy { $0.weight <= 600 })
    #expect(Tokens.Space.all.allSatisfy { $0.truncatingRemainder(dividingBy: 4) == 0 })
  }

  @Test("TIME: one headline, then what could be faster, then where the time goes; an empty week is the headline only")
  func timeBlocks() {
    let week = TimeHeadline(totalHours: 31.5, findings: [
      TimeHeadline.Finding(id: "a", hoursFreed: 1.5, arithmetic: "6 times · 15 min each"),
      TimeHeadline.Finding(id: "b", hoursFreed: 1.2, arithmetic: "4 times · 18 min each"),
    ])
    #expect(week.blocks == [.headline, .findings, .detail])
    #expect(week.headlineWorked == "You worked 31.5 h this week.")
    #expect(week.freedTotal == "2.7 h")
    #expect(week.headlineFreed == "About 2.7 h a week of it could run without you.")
    let day = TimeHeadline(totalHours: 6, findings: week.findings, isDay: true)
    #expect(day.headlineWorked == "You worked 6.0 h on this day.")
    #expect(day.headlineFreed == "At this pace, about 2.7 h a week could run without you.")
    let empty = TimeHeadline(totalHours: 0, findings: [])
    #expect(empty.blocks == [.headline])
    #expect(empty.freedTotal == nil && empty.headlineFreed == nil)
    #expect(empty.headlineNone == "Nothing tracked yet.")
    #expect(TimeHeadline(totalHours: 12, findings: []).headlineNone == "Nothing repeats enough to hand off yet.")
    #expect(TimeHeadline.detailTitle == "Where the time goes" && TimeHeadline.findingsTitle == "What could be faster")
  }

  @Test("TIME: the maths sits behind a link, as separate items; no percentages, no outreach")
  func timeMaths() {
    #expect(TimeHeadline.mathsTitle == "How these are worked out")
    #expect(TimeHeadline.mathsItems("6 times · 15 min each") == ["6 times", "15 min each"])
    #expect(TimeHeadline.mathsItems("one line") == ["one line"])
    let w = TimeHeadline(totalHours: 20, findings: [TimeHeadline.Finding(id: "a", hoursFreed: 0.5, arithmetic: "2 times · 15 min")])
    for t in [w.headlineWorked, w.headlineFreed ?? "", w.headlineNone, TimeHeadline.findingsFooter, TimeHeadline.mathsTitle] {
      #expect(!t.contains("%"))
      #expect(t.range(of: "outreach|investor|prospect", options: [.regularExpression, .caseInsensitive]) == nil)
    }
  }

  @Test("META: middle-dot strings become separate items")
  func metaSplit() {
    #expect(MetaItems.split("Watching · Day 7 of 7") == ["Watching", "Day 7 of 7"])
    #expect(MetaItems.split("No data yet") == ["No data yet"])
    #expect(MetaItems.split("") == [])
    #expect(MetaItems.split(" a ·  · b ") == ["a", "b"])
  }

  @Test("TYPE: the last two words of a sentence stay together; short lines are left alone")
  func orphans() {
    #expect(OrphanGuard.glue("Nothing to do until then.") == "Nothing to do until\u{00A0}then.")
    #expect(OrphanGuard.glue("All set.") == "All set.")
    #expect(OrphanGuard.glue("One two three") == "One two three")
    #expect(OrphanGuard.glue("") == "")
    #expect(OrphanGuard.glue("a b c d").replacingOccurrences(of: "\u{00A0}", with: " ") == "a b c d")
  }

  @Test("BUDDY: it speaks in lowercase, one short line, never shouting")
  func buddyLines() {
    for m in BuddyMood.allCases {
      #expect(m.line == m.line.lowercased())
      #expect(M304Repo.words(m.line) <= 5 && !m.line.isEmpty)
      #expect(!m.line.contains("!"))
    }
    #expect(BuddyLine.weekly(hours: 16.8) == "about two workdays back, every week.")
    #expect(BuddyLine.weekly(hours: 0.5) == "a little time back, every week.")
    #expect(BuddyLine.weekly(hours: 4) == "about an afternoon back, every week.")
    #expect(BuddyLine.weekly(hours: 8.2) == "about a workday back, every week.")
    #expect(BuddyLine.weekly(hours: 25) == "about three workdays back, every week.")
    #expect(BuddyLine.weekly(hours: 40) == "about a whole workweek back, every week.")
  }

  @Test("BUDDY: three moods follow the observer and what is waiting")
  func buddyMoods() {
    #expect(BuddyMood.allCases == [.watching, .foundSomething, .quiet])
    #expect(BuddyMood.quiet.lift == 0 && BuddyMood.foundSomething.lift == 1)
    #expect(BuddyMood.watching.lift > 0 && BuddyMood.watching.lift < 1)
    #expect(BuddyMood.allCases.filter(\.highlightsBlock) == [.foundSomething])
    #expect(BuddyMood.of(observer: .watching, waiting: 0) == .watching)
    #expect(BuddyMood.of(observer: .noData, waiting: 0) == .watching)
    #expect(BuddyMood.of(observer: .watching, waiting: 2) == .foundSomething)
    #expect(BuddyMood.of(observer: .paused, waiting: 0) == .quiet)
    #expect(BuddyMood.of(observer: .stale, waiting: 0) == .quiet)
    #expect(BuddyMood.of(observer: .paused, waiting: 1) == .foundSomething)
  }
}
