import AppKit

/// "Report a Bug…" (status menu): opens the Slyy Shot issue form on the public
/// tracker github.com/mySlyy/releases (shared with Slyy desktop; Shot has its own
/// form shot_bug_report.yml there). The release feed stays on mySlyy/shot.
/// Field ids app-version / environment must match the form; GitHub prefills
/// issue-form fields from query parameters of the same id.
enum BugReport {
    static let repo = "mySlyy/releases"
    static let template = "shot_bug_report.yml"

    /// Form URL with version, macOS and chip filled in. Nothing else is sent:
    /// the user reviews and submits the form in the browser.
    static func url(version: Version = .current,
                    os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "github.com"
        c.path = "/\(repo)/issues/new"
        c.queryItems = [
            URLQueryItem(name: "template", value: template),
            URLQueryItem(name: "app-version", value: version.description),
            URLQueryItem(name: "environment", value: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(arch)"),
        ]
        return c.url!
    }

    /// Architecture of the running slice (universal binary: arm64 or x86_64).
    private static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static func open() {
        NSWorkspace.shared.open(url())
    }
}
