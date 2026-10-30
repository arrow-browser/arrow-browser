import CEF

/// Versions of the embedded Chromium.
public enum CEFVersion {
    public static var chromium: String {
        "\(cef_version_info(4)).\(cef_version_info(5)).\(cef_version_info(6)).\(cef_version_info(7))"
    }

    public static var cef: String {
        "\(cef_version_info(0)).\(cef_version_info(1)).\(cef_version_info(2))"
    }
}
