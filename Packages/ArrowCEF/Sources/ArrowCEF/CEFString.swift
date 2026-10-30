import CEF

// Conversions between Swift strings and CEF UTF-16 strings.

extension String {
    /// Copies a CEF string (callback argument, struct field…).
    public init(cef string: UnsafePointer<cef_string_t>?) {
        guard let string, let characters = string.pointee.str, string.pointee.length > 0 else {
            self = ""
            return
        }
        self = String(decoding: UnsafeBufferPointer(start: characters, count: string.pointee.length), as: UTF16.self)
    }

    /// Copies and frees a `cef_string_userfree_t` returned by CEF.
    public init(cefUserFree string: cef_string_userfree_t?) {
        guard let string else {
            self = ""
            return
        }
        self.init(cef: UnsafePointer(string))
        cef_string_userfree_utf16_free(string)
    }
}

/// Calls `body` with a temporary CEF string pointing at `string`'s UTF-16 storage.
public func withCefString<R>(_ string: String, _ body: (UnsafePointer<cef_string_t>) throws -> R) rethrows -> R {
    var utf16 = Array(string.utf16)
    return try utf16.withUnsafeMutableBufferPointer { buffer in
        var cefString = cef_string_t(str: buffer.baseAddress, length: buffer.count, dtor: nil)
        return try body(&cefString)
    }
}

/// Calls `body` with an optional temporary CEF string.
public func withOptionalCefString<R>(_ string: String?, _ body: (UnsafePointer<cef_string_t>?) throws -> R) rethrows -> R {
    guard let string else { return try body(nil) }
    return try withCefString(string) { try body($0) }
}

extension cef_string_t {
    /// Replaces the contents with an owned copy of `value` (freed by `clear()`
    /// or by CEF when the owning struct is released).
    public mutating func set(_ value: String) {
        let utf16 = Array(value.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            _ = cef_string_utf16_set(buffer.baseAddress, buffer.count, &self, 1)
        }
    }

    public mutating func clear() {
        cef_string_utf16_clear(&self)
    }
}

/// Reads all values of a `cef_string_list_t`.
public func cefStringList(_ list: cef_string_list_t?) -> [String] {
    guard let list else { return [] }
    let count = cef_string_list_size(list)
    var values: [String] = []
    values.reserveCapacity(count)
    for index in 0..<count {
        var value = cef_string_t()
        if cef_string_list_value(list, index, &value) != 0 {
            values.append(String(cef: &value))
            cef_string_utf16_clear(&value)
        }
    }
    return values
}
