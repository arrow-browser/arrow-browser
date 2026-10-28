import Foundation

/// A saved payment card (Preferences ▸ Profiles ▸ Credit Cards). The
/// security code is never stored, as in Chrome.
public struct PaymentCard: Codable, Hashable, Identifiable, Sendable {
    public enum Brand: String, Codable, Sendable {
        case visa, mastercard, amex, discover, other

        public var name: String {
            switch self {
            case .visa: "Visa"
            case .mastercard: "Mastercard"
            case .amex: "American Express"
            case .discover: "Discover"
            case .other: "Card"
            }
        }
    }

    public var id: UUID
    public var holder: String
    /// Digits only.
    public var number: String
    public var expiryMonth: Int
    public var expiryYear: Int

    public init(id: UUID = UUID(), holder: String, number: String, expiryMonth: Int, expiryYear: Int) {
        self.id = id
        self.holder = holder
        self.number = number.filter(\.isNumber)
        self.expiryMonth = expiryMonth
        // Two-digit years are in this century.
        self.expiryYear = expiryYear < 100 ? 2000 + expiryYear : expiryYear
    }

    public var brand: Brand {
        if number.hasPrefix("4") { return .visa }
        if number.hasPrefix("34") || number.hasPrefix("37") { return .amex }
        if number.hasPrefix("6011") || number.hasPrefix("65") { return .discover }
        if let prefix = Int(number.prefix(2)), (51...55).contains(prefix) { return .mastercard }
        if let prefix = Int(number.prefix(4)), (2221...2720).contains(prefix) { return .mastercard }
        return .other
    }

    /// "Visa •••• 4242".
    public var label: String { "\(brand.name) •••• \(number.suffix(4))" }

    /// "07/29".
    public var expiry: String { String(format: "%02d/%02d", expiryMonth, expiryYear % 100) }

    /// Luhn checksum, to ignore fields that only look like card numbers.
    public static func isValidNumber(_ number: String) -> Bool {
        let digits = number.filter(\.isNumber).compactMap(\.wholeNumberValue)
        guard (12...19).contains(digits.count) else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { total, item in
            guard item.offset.isMultiple(of: 2) else {
                let doubled = item.element * 2
                return total + (doubled > 9 ? doubled - 9 : doubled)
            }
            return total + item.element
        }
        return sum.isMultiple(of: 10)
    }

    /// Month and year from "07/29", "7/2029" or "07 / 29".
    public static func parseExpiry(_ text: String) -> (month: Int, year: Int)? {
        let parts = text.split { !$0.isNumber }.compactMap { Int($0) }
        guard parts.count == 2, (1...12).contains(parts[0]) else { return nil }
        return (parts[0], parts[1] < 100 ? 2000 + parts[1] : parts[1])
    }
}
