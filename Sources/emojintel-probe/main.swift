import Foundation
import ApplicationServices

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "keys":
    KeysProbe.run()

case "rank":
    RankProbe.run(words: Array(args.dropFirst()))

case "focus":
    FocusProbe.run()

case "ax":
    AXProbe.run(attemptWrite: args.contains("--write"))

case "env":
    KeysProbe.reportFnSetting()
    print("Accessibility trusted: \(AXIsProcessTrusted() ? "yes" : "NO")")

default:
    print("""
    emojintel-probe — Phase 0 diagnostics

      keys           log keyDown / flagsChanged; verify the fn and Right-⌘ triggers
      ax [--write]   dump the focused text element: role, value, range, word, bounds
      rank [words]   check the emoji index and ranking without launching the app
      focus          diagnose WHY focused-element lookup fails (prints exact AXErrors)
      env            report AppleFnUsageType, Secure Input, and Accessibility trust

    Run `keys` and `ax` from a terminal that has Accessibility permission.
    """)
}
