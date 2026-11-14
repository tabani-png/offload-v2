import SwiftUI

// SwiftUI side of the tokens: light paper canvas, dark floating chrome (pricing v3). Views only; no logic here.

extension Color {
  public init(hex: UInt32, opacity: Double = 1) {
    let c = ColorMath.components(hex)
    self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: opacity)
  }
}

public enum Theme {
  public static let paper = Color(hex: Tokens.Palette.paper)
  public static let paper2 = Color(hex: Tokens.Palette.paper2)
  public static let ink = Color(hex: Tokens.Palette.ink)
  public static let ink2 = Color(hex: Tokens.Palette.ink2)
  public static let muted = Color(hex: Tokens.Palette.muted)
  public static let rule = Color(hex: Tokens.Palette.rule)
  public static let chrome = Color(hex: Tokens.Palette.chrome)
  public static let chrome2 = Color(hex: Tokens.Palette.chrome2)
  public static let chrome3 = Color(hex: Tokens.Palette.chrome3)
  public static let chromeInk = Color(hex: Tokens.Palette.chromeInk)
  public static let chromeMute = Color(hex: Tokens.Palette.chromeMute)
  public static let chromeLine = Color.white.opacity(0.08)
  public static let cyan = Color(hex: Tokens.Palette.cyan)
  public static let working = Color(hex: Tokens.Palette.working)
  public static let needsYou = Color(hex: Tokens.Palette.needsYou)
  public static let done = Color(hex: Tokens.Palette.done)

  public static func font(_ style: Tokens.TypeStyle) -> Font {
    let weight: Font.Weight
    switch style.weight {
    case 600: weight = .semibold
    case 500: weight = .medium
    default: weight = .regular
    }
    return .system(size: style.size, weight: weight)
  }
}

extension View {
  /// Text in a type style, with its tracking.
  public func textStyle(_ style: Tokens.TypeStyle) -> some View {
    font(Theme.font(style)).tracking(style.tracking)
  }

  /// A dark floating card on the paper canvas.
  public func chromeCard(padding: Double = Tokens.Space.s24) -> some View {
    self
      .padding(padding)
      .background(
        RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous).fill(Theme.chrome)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous).strokeBorder(Theme.chromeLine)
      )
      .shadow(color: Theme.ink.opacity(0.25), radius: 24, x: 0, y: 14)
  }

  /// A light card on the paper canvas.
  public func paperCard(padding: Double = Tokens.Space.s20) -> some View {
    self
      .padding(padding)
      .background(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous).fill(Color.white))
      .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous).strokeBorder(Theme.rule))
  }
}

/// The primary button: dark pill on paper. Return activates it (`.keyboardShortcut(.defaultAction)`).
public struct PrimaryButtonStyle: ButtonStyle {
  public init() {}
  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .textStyle(Tokens.TypeScale.label)
      .foregroundStyle(Theme.chromeInk)
      .padding(.horizontal, Tokens.Space.s20)
      .padding(.vertical, Tokens.Space.s8 + 2)
      .background(Capsule().fill(Theme.chrome))
      .opacity(configuration.isPressed ? 0.85 : 1)
  }
}

/// Secondary and Skip: the same size as each other, quieter than the primary.
public struct SecondaryButtonStyle: ButtonStyle {
  public init() {}
  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .textStyle(Tokens.TypeScale.label)
      .foregroundStyle(Theme.ink2)
      .padding(.horizontal, Tokens.Space.s16)
      .padding(.vertical, Tokens.Space.s8 + 2)
      .background(Capsule().strokeBorder(Theme.rule))
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

/// A lowercase caption: items separated by "·" drawn as separate items (MetaItems).
public struct CaptionLine: View {
  let text: String
  let onChrome: Bool
  public init(_ text: String, onChrome: Bool = false) {
    self.text = text
    self.onChrome = onChrome
  }
  public var body: some View {
    let items = MetaItems.split(text)
    HStack(spacing: Tokens.Space.s8) {
      ForEach(Array(items.enumerated()), id: \.offset) { pair in
        if pair.offset > 0 {
          Text("·").foregroundStyle(onChrome ? Theme.chromeMute : Theme.muted).accessibilityHidden(true)
        }
        Text(pair.element)
      }
    }
    .textStyle(Tokens.TypeScale.caption)
    .foregroundStyle(onChrome ? Theme.chromeMute : Theme.muted)
    .accessibilityElement(children: .combine)
  }
}
