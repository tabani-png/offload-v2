import Foundation

// Small decoding helpers for the API shapes: clients ignore unknown fields (API.md section 1, "Versioning"), and a
// list keeps the items it can read rather than failing whole.

/// A coding key for any member name.
struct AnyCodingKey: CodingKey {
  var stringValue: String
  var intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}

/// A list that keeps every item it can decode and skips the rest.
public struct LossyList<Element: Decodable & Sendable>: Decodable, Sendable {
  public let items: [Element]

  public init(items: [Element]) { self.items = items }

  public init(from decoder: any Decoder) throws {
    var c = try decoder.unkeyedContainer()
    var out: [Element] = []
    while !c.isAtEnd {
      if let item = try? c.decode(Element.self) {
        out.append(item)
      } else {
        _ = try c.decode(JSONValue.self)  // step over the item that did not decode
      }
    }
    items = out
  }
}

extension KeyedDecodingContainer {
  /// The items of the list at `key` that decode; `[]` when the key is missing, null or not a list.
  func lossyList<T: Decodable & Sendable>(_ type: T.Type, forKey key: Key) -> [T] {
    guard let list = try? decodeIfPresent(LossyList<T>.self, forKey: key) else { return [] }
    return list.items
  }

  /// The value at `key`, or nil when it is missing, null or of another shape.
  func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
    guard let value = try? decodeIfPresent(T.self, forKey: key) else { return nil }
    return value
  }
}

/// A number the server may send plain or as a `Figure` (API.md: every number in a response is a Figure; some build
/// loop and outcome fields are still plain numbers).
public enum NumberOrFigure: Codable, Equatable, Sendable {
  case number(Double)
  case figure(Figure)

  public var value: Double {
    switch self {
    case .number(let d): return d
    case .figure(let f): return f.value
    }
  }

  /// The figure when the server sent one.
  public var figure: Figure? {
    if case .figure(let f) = self { return f }
    return nil
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let d = try? c.decode(Double.self) {
      self = .number(d)
    } else {
      self = .figure(try c.decode(Figure.self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .number(let d): try c.encode(d)
    case .figure(let f): try c.encode(f)
    }
  }
}
