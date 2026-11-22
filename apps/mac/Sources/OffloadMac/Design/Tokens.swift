import Foundation

/// Design token values. Plain numbers so they are testable without a window server; `Theme.swift` maps them to
/// SwiftUI colours and fonts. Palette from the pricing v3 page the owner approved (light paper canvas, dark floating
/// chrome); spacing, radii and type scale ported from the old s06/s33 tokens (release/mac-testable, Core/Tokens.swift).
public enum Tokens {
  /// sRGB hex values (0xRRGGBB).
  public enum Palette {
    /// The canvas: consultance paper.
    public static let paper: UInt32 = 0xF4F5F2
    public static let paper2: UInt32 = 0xECEEE9
    public static let ink: UInt32 = 0x0B1220
    public static let ink2: UInt32 = 0x3A4552
    public static let muted: UInt32 = 0x5D6874
    public static let rule: UInt32 = 0xDDE2DF
    /// Dark floating chrome: cards and the menu bar panel.
    public static let chrome: UInt32 = 0x0C1422
    public static let chrome2: UInt32 = 0x151F2F
    public static let chrome3: UInt32 = 0x1D2A3E
    public static let chromeInk: UInt32 = 0xEEF2F6
    public static let chromeMute: UInt32 = 0x93A0B0
    /// Decoration only on chrome (dots, rules); never body text (3.5:1).
    public static let chromeFaint: UInt32 = 0x5F6D7F
    /// The highlight on chrome.
    public static let cyan: UInt32 = 0x67E8F9
    /// Blue is working, amber needs you, green is done.
    public static let working: UInt32 = 0x4C8DFF
    public static let needsYou: UInt32 = 0xF2B33D
    public static let done: UInt32 = 0x3FCF8E
  }

  /// 4-pt grid.
  public enum Space {
    public static let s4: Double = 4
    public static let s8: Double = 8
    public static let s12: Double = 12
    public static let s16: Double = 16
    public static let s20: Double = 20
    public static let s24: Double = 24
    public static let s32: Double = 32
    public static let s40: Double = 40
    public static let s48: Double = 48
    public static let all: [Double] = [s4, s8, s12, s16, s20, s24, s32, s40, s48]
  }

  /// Concentric radii (pricing v3: 28 for large cards, 18 for cards).
  public enum Radius {
    public static let large: Double = 28
    public static let card: Double = 18
    public static let row: Double = 12
    public static let control: Double = 8
    public static func concentric(outer: Double, inset: Double) -> Double { max(0, outer - inset) }
  }

  public struct TypeStyle: Equatable, Sendable {
    public let name: String
    public let size: Double
    /// 400, 500 or 600 (badges only). No bold.
    public let weight: Int
    /// Tracking in points.
    public let tracking: Double
    public let lineHeight: Double
  }

  /// SF Pro through the system fonts. Hierarchy comes from size and opacity, not weight.
  public enum TypeScale {
    public static let heroDisplay = TypeStyle(name: "heroDisplay", size: 56, weight: 500, tracking: -2.24, lineHeight: 1.0)
    public static let hero = TypeStyle(name: "hero", size: 34, weight: 500, tracking: -0.9, lineHeight: 1.0)
    public static let largeTitle = TypeStyle(name: "largeTitle", size: 26, weight: 500, tracking: -0.6, lineHeight: 1.15)
    public static let display = TypeStyle(name: "display", size: 20, weight: 500, tracking: -0.35, lineHeight: 1.2)
    public static let title = TypeStyle(name: "title", size: 15, weight: 500, tracking: -0.15, lineHeight: 1.3)
    public static let body = TypeStyle(name: "body", size: 13, weight: 400, tracking: -0.05, lineHeight: 1.45)
    public static let label = TypeStyle(name: "label", size: 13, weight: 500, tracking: -0.05, lineHeight: 1.3)
    public static let callout = TypeStyle(name: "callout", size: 12, weight: 400, tracking: 0, lineHeight: 1.4)
    public static let caption = TypeStyle(name: "caption", size: 11, weight: 500, tracking: 0.1, lineHeight: 1.2)
    public static let badge = TypeStyle(name: "badge", size: 10, weight: 600, tracking: 0, lineHeight: 1)
    public static let mono = TypeStyle(name: "mono", size: 11, weight: 500, tracking: 0, lineHeight: 1)
    public static let all: [TypeStyle] = [heroDisplay, hero, largeTitle, display, title, body, label, callout, caption, badge, mono]
  }

  /// Seconds.
  public enum Duration {
    public static let fast: Double = 0.15
    public static let base: Double = 0.20
    public static let slow: Double = 0.30
  }
}

/// WCAG 2 contrast, for the token tests and for checking new pairs.
public enum ColorMath {
  public static func components(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
    (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
  }

  static func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

  public static func luminance(_ hex: UInt32) -> Double {
    let c = components(hex)
    return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
  }

  public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    let la = luminance(a)
    let lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  }
}
