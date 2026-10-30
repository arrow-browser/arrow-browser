import CEF
import Foundation

/// Converts Swift JSON-like values into CEF values.
public enum CEFValue {
    public static func dictionary(from object: [String: Any]) -> CefRef<cef_dictionary_value_t>? {
        guard let dictionary = CefRef(adopting: cef_dictionary_value_create()) else { return nil }
        let d = dictionary.pointer
        for (key, value) in object {
            withCefString(key) { key in
                switch value {
                case let value as Bool:
                    _ = d.pointee.set_bool?(d, key, value ? 1 : 0)
                case let value as Int:
                    _ = d.pointee.set_int?(d, key, Int32(clamping: value))
                case let value as Double:
                    _ = d.pointee.set_double?(d, key, value)
                case let value as CGFloat:
                    _ = d.pointee.set_double?(d, key, Double(value))
                case let value as String:
                    withCefString(value) { _ = d.pointee.set_string?(d, key, $0) }
                case let value as [String: Any]:
                    if let child = Self.dictionary(from: value) {
                        _ = d.pointee.set_dictionary?(d, key, child.retained())
                    }
                case let value as [Any]:
                    if let child = Self.list(from: value) {
                        _ = d.pointee.set_list?(d, key, child.retained())
                    }
                default:
                    _ = d.pointee.set_null?(d, key)
                }
            }
        }
        return dictionary
    }

    public static func list(from array: [Any]) -> CefRef<cef_list_value_t>? {
        guard let list = CefRef(adopting: cef_list_value_create()) else { return nil }
        let l = list.pointer
        _ = l.pointee.set_size?(l, array.count)
        for (index, value) in array.enumerated() {
            switch value {
            case let value as Bool:
                _ = l.pointee.set_bool?(l, index, value ? 1 : 0)
            case let value as Int:
                _ = l.pointee.set_int?(l, index, Int32(clamping: value))
            case let value as Double:
                _ = l.pointee.set_double?(l, index, value)
            case let value as String:
                withCefString(value) { _ = l.pointee.set_string?(l, index, $0) }
            case let value as [String: Any]:
                if let child = dictionary(from: value) {
                    _ = l.pointee.set_dictionary?(l, index, child.retained())
                }
            case let value as [Any]:
                if let child = Self.list(from: value) {
                    _ = l.pointee.set_list?(l, index, child.retained())
                }
            default:
                _ = l.pointee.set_null?(l, index)
            }
        }
        return list
    }
}
