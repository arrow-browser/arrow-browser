import Foundation
import WinSDK

/// Arrow as a browser of Windows: registered for the current user, so
/// Settings ▸ Default apps lists it, where Windows has the user choose it
/// (apps cannot make themselves the default).
enum DefaultBrowser {
    private static let client = "Software\\Clients\\StartMenuInternet\\Arrow"

    /// Registers Arrow under HKEY_CURRENT_USER: a Start menu internet client
    /// with its capabilities, and the classes opening web addresses and
    /// pages with Arrow.exe.
    static func register() {
        let executable = executablePath
        let open = "\"\(executable)\" \"%1\""
        let icon = "\(executable),0"
        set(client, nil, "Arrow")
        set(client + "\\DefaultIcon", nil, icon)
        set(client + "\\shell\\open\\command", nil, "\"\(executable)\"")
        set(client + "\\Capabilities", "ApplicationName", "Arrow")
        set(client + "\\Capabilities", "ApplicationDescription", "A browser in the spirit of Arc.")
        set(client + "\\Capabilities", "ApplicationIcon", icon)
        for scheme in ["http", "https"] {
            set(client + "\\Capabilities\\URLAssociations", scheme, "ArrowURL")
        }
        for type in [".htm", ".html", ".svg", ".webp", ".pdf"] {
            set(client + "\\Capabilities\\FileAssociations", type, "ArrowHTML")
        }
        set("Software\\RegisteredApplications", "Arrow", client + "\\Capabilities")
        for (progID, title) in [("ArrowURL", "Arrow URL"), ("ArrowHTML", "Arrow HTML Document")] {
            set("Software\\Classes\\\(progID)", nil, title)
            set("Software\\Classes\\\(progID)\\DefaultIcon", nil, icon)
            set("Software\\Classes\\\(progID)\\shell\\open\\command", nil, open)
            // The name Windows shows for it (its "Select an app" picker), not
            // the description of CEF's bootstrap executable.
            set("Software\\Classes\\\(progID)\\Application", "ApplicationName", "Arrow")
            set("Software\\Classes\\\(progID)\\Application", "ApplicationIcon", icon)
        }
        set("Software\\Classes\\Applications\\\(executableName)", "FriendlyAppName", "Arrow")
        set("Software\\Classes\\ArrowURL", "URL Protocol", "")
        // SHCNE_ASSOCCHANGED, SHCNF_IDLIST: Explorer reads the associations again.
        SHChangeNotify(0x0800_0000, 0, nil, nil)
    }

    /// Windows' Default apps page for Arrow.
    static let settingsPage = "ms-settings:defaultapps?registeredAppUser=Arrow"

    /// Arrow.exe (CEF's bootstrap, which loads Arrow.dll).
    private static var executablePath: String {
        var buffer = [WCHAR](repeating: 0, count: Int(MAX_PATH) * 2)
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    private static var executableName: String {
        URL(fileURLWithPath: executablePath).lastPathComponent
    }

    /// HKEY_CURRENT_USER, a macro Swift does not import.
    private static var currentUser: HKEY? { HKEY(bitPattern: Int(Int32(bitPattern: 0x8000_0001))) }

    private static func set(_ key: String, _ name: String?, _ value: String) {
        var handle: HKEY?
        let created = key.withWideString { key in
            RegCreateKeyExW(currentUser, key, 0, nil, 0, REGSAM(KEY_SET_VALUE), nil, &handle, nil)
        }
        guard created == ERROR_SUCCESS, let handle else { return }
        defer { RegCloseKey(handle) }
        let data = Array(value.utf16) + [0]
        data.withUnsafeBytes { bytes in
            _ = (name ?? "").withWideString { name in
                RegSetValueExW(handle, name, 0, DWORD(REG_SZ), bytes.baseAddress?.assumingMemoryBound(to: BYTE.self),
                               DWORD(bytes.count))
            }
        }
    }
}
