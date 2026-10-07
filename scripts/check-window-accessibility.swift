// Run against an open, disposable space:
// swift scripts/check-window-accessibility.swift <space-bundle-id>
// Requires Accessibility permission for the terminal running this check.
import AppKit
import ApplicationServices

func require(_ condition: Bool, _ message: String) {
    guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
require(CommandLine.arguments.count == 2, "Pass a running space's bundle ID")
require(AXIsProcessTrusted(), "Grant Accessibility permission to the calling terminal")
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1])
require(apps.count == 1, "Expected one running space")
let app = apps[0]
require(app.processIdentifier > 0, "LaunchServices lost the space's process identity")
let element = AXUIElementCreateApplication(app.processIdentifier)
var value: CFTypeRef?
let result = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
require(result == .success, "Cannot read space windows: \(result.rawValue)")
let windows = value as? [AXUIElement] ?? []
require(!windows.isEmpty, "Open a window in the test space")
let window = windows[0]
var settable = DarwinBoolean(false)
require(AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue,
        "Window does not expose a writable AXSize")
require(AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success, "Cannot read window size")
let original = value as! AXValue
var size = CGSize.zero
require(AXValueGetValue(original, .cgSize, &size), "Invalid window size")
size.width += 40
size.height += 40
let resized = AXValueCreate(.cgSize, &size)!
let changed = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, resized)
Thread.sleep(forTimeInterval: 0.3)
var updated: CFTypeRef?
let read = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &updated)
let restored = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, original)
require(changed == .success && read == .success && restored == .success, "Resize/read/restore failed")
var actual = CGSize.zero
require(AXValueGetValue(updated as! AXValue, .cgSize, &actual) && abs(actual.width - size.width) < 2 && abs(actual.height - size.height) < 2,
        "Window ignored the requested size")
print("PASS: valid process identity, accessible window, resize and restore")
