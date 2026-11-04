import AppKit
import Foundation

public protocol BrowserCacheClearing: Sendable {
    func clearHostCache() async -> StepOutcome
    func flushSocketPools() async -> StepOutcome
}

/// Clears Dia's own caches: its host cache and its socket pools, which `dscacheutil` cannot reach.
///
/// Dia has no command for this, so the app opens the Chromium net-internals page in a new tab, clicks the button
/// with JavaScript, and closes the tab. Dia only runs AppleScript JavaScript when it was launched with
/// `--enable-applescript-javascript`; without that the steps are skipped with a hint instead of failing the toggle.
public struct DiaBrowser: BrowserCacheClearing {
    static let bundleIdentifier = "company.thebrowser.dia"
    static let launchFlag = "--enable-applescript-javascript"

    private let isRunning: @Sendable () -> Bool
    private let runScript: @Sendable (String) async throws -> (status: Int32, output: String)

    public init() {
        self.init(
            isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: DiaBrowser.bundleIdentifier).isEmpty },
            runScript: { source in
                let result = try await UserCommand.run("/usr/bin/osascript", ["-e", source])
                return (result.status, result.status == 0 ? result.stdout : result.stderr)
            })
    }

    init(isRunning: @escaping @Sendable () -> Bool, runScript: @escaping @Sendable (String) async throws -> (status: Int32, output: String)) {
        self.isRunning = isRunning
        self.runScript = runScript
    }

    public func clearHostCache() async -> StepOutcome {
        await click(url: "chrome://net-internals/#dns", buttonText: "clear host cache", label: "Clear host cache")
    }

    public func flushSocketPools() async -> StepOutcome {
        await click(url: "dia://net-internals/#sockets", buttonText: "flush socket pools", label: "Flush socket pools")
    }

    private func click(url: String, buttonText: String, label: String) async -> StepOutcome {
        guard isRunning() else { return .skipped("Dia is not running") }
        let result: (status: Int32, output: String)
        do { result = try await runScript(Self.appleScript(url: url, buttonText: buttonText)) } catch {
            return .failed("Could not run AppleScript: \(error.localizedDescription)")
        }
        guard result.status == 0 else {
            if result.output.contains("enable-applescript-javascript") {
                return .skipped("Launch Dia with \(Self.launchFlag) to let the app click this button")
            }
            let detail = WriterSupport.brief(result.output)
            return .failed(detail.isEmpty ? "The AppleScript failed." : detail)
        }
        // Dia hands the script's result back JSON-encoded, so the word arrives as "clicked" with the quote marks.
        if result.output.contains("clicked") { return .done }
        return .failed("Could not find the \u{201C}\(label)\u{201D} button on the page.")
    }

    /// Opens `url` in a new tab of Dia's front window, retries the click while the page loads, and always closes the tab.
    /// `buttonText` is matched case-insensitively against the button's text (or, for `<input type=button>`, its value),
    /// searching through shadow roots.
    static func appleScript(url: String, buttonText: String) -> String {
        let javascript = "(function(){var re=/\(buttonText)/i;var found=null;"
            + "function walk(root){var all=root.querySelectorAll('*');"
            + "for(var i=0;i<all.length&&!found;i++){var el=all[i];if(el.shadowRoot){walk(el.shadowRoot);}"
            + "if(!found&&(el.tagName==='BUTTON'||el.tagName==='CR-BUTTON'||el.tagName==='INPUT'||el.getAttribute('role')==='button')&&re.test(el.textContent||el.value||'')){found=el;}}}"
            + "walk(document);if(found){found.click();return 'clicked';}return 'notfound';})()"
        return """
        tell application "Dia"
          if (count of windows) is 0 then error "Dia has no open window."
          set theTab to make new tab at window 1 with properties {URL:"\(AppleScriptString.escape(url))"}
          set outcome to "notfound"
          try
            repeat 8 times
              delay 1
              set outcome to execute theTab javascript "\(AppleScriptString.escape(javascript))"
              if outcome contains "clicked" then exit repeat
            end repeat
          on error errText number errNum
            try
              close theTab
            end try
            error errText number errNum
          end try
          try
            close theTab
          end try
          return outcome
        end tell
        """
    }
}
