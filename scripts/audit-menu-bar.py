#!/usr/bin/env python3
"""Finite native hide/reveal audit. Does not install apps or edit their preferences.

Usage: scripts/audit-menu-bar.py /path/to/Portside.app --target com.example.app
The target must already have a visible menu bar item. Requires Accessibility
for the host and Portside. Results distinguish the tested binary from source.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


PROBE = r'''
import AppKit
import ApplicationServices
func attribute(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success ? value : nil
}
let pid = pid_t(CommandLine.arguments[1])!
let target = CommandLine.arguments[2].lowercased()
let press = CommandLine.arguments.last == "press"
var drawn: [pid_t] = []
var readable = AXIsProcessTrusted()
var windowCount = 0
if let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first {
    let app = AXUIElementCreateApplication(agent.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 0.5)
    if let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] {
        windowCount = windows.count
        for window in windows {
            guard let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement] else { readable = false; continue }
            for child in children {
                var element = child
                var owner = agent.processIdentifier
                for _ in 0..<10 {
                    guard AXUIElementGetPid(element, &owner) == .success else { readable = false; break }
                    if owner != agent.processIdentifier { break }
                    guard let next = (attribute(element, kAXChildrenAttribute) as? [AXUIElement])?.first else { break }
                    element = next
                }
                drawn.append(owner)
            }
        }
    } else { readable = false }
} else { readable = false }
let targetPIDs = Set(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier?.lowercased() == target }.map(\.processIdentifier))
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 0.5)
var controls: [AXUIElement] = []
var label = ""
if let bar = attribute(app, kAXExtrasMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() {
    for child in attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        let description = attribute(child, kAXDescriptionAttribute) as? String ?? ""
        if description.hasPrefix("Menu bar shelf.") { controls.append(child); label = description }
    }
}
var result: [String: Any] = ["readable": readable, "windows": windowCount, "ownDrawn": drawn.filter { $0 == pid }.count,
    "targetDrawn": drawn.filter { targetPIDs.contains($0) }.count, "controlLabel": label, "controls": controls.count]
if press {
    result["pressResult"] = controls.count == 1 ? AXUIElementPerformAction(controls[0], kAXPressAction as CFString).rawValue : -1
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--target", required=True)
    parser.add_argument("--seconds", type=float, default=20)
    args = parser.parse_args()
    if not 5 <= args.seconds <= 60:
        parser.error("--seconds must be between 5 and 60")
    if not all(c.isalnum() or c in ".-_" for c in args.target):
        parser.error("--target must be a bundle identifier")
    binary = args.app.resolve() / "Contents/MacOS/portside"
    if not binary.is_file():
        parser.error("Portside executable missing")
    if subprocess.run(["pgrep", "-x", "portside"], capture_output=True).returncode == 0:
        parser.error("Portside already running; refusing a second manager")
    root = Path(tempfile.mkdtemp(prefix="portside-menu-audit-", dir="/tmp"))
    (root / "probe.swift").write_text(PROBE)
    subprocess.run(["swiftc", str(root / "probe.swift"), "-o", str(root / "probe")], check=True)
    home = root / "home"
    config = home / "Library/Application Support/com.james.portside/dock.json"
    config.parent.mkdir(parents=True)
    config.write_text(json.dumps({"edge": "left", "hideNativeDock": False, "automaticUpdateChecks": False,
        "modules": {"menuBarShelf": {"enabled": True}},
        "menuBarTriggers": {"scroll": False, "emptyClick": False, "hover": False,
                            "strategy": "timed", "rehideSeconds": 0}}))
    # CFPreferences can share its daemon cache across launches of one bundle.
    # NSArgumentDomain pins this process's assignments without changing disk.
    assignment = '{ "' + args.target.lower() + ':#0" = hidden; }'
    report = {"binary": str(binary), "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "target": args.target, "samples": [], "failures": [], "action": "AXPress on shelf control"}
    started = time.monotonic()
    process = None

    def sample(action=None):
        command = [str(root / "probe"), str(process.pid if process else 0), args.target]
        if action:
            command.append(action)
        result = json.loads(subprocess.check_output(command, text=True, timeout=10))
        result["elapsed"] = round(time.monotonic() - started, 3)
        report["samples"].append(result)
        return result

    def press():
        result = sample("press")
        if result.get("pressResult") != 0:
            raise RuntimeError("shelf AXPress unavailable")

    try:
        baseline = sample()
        if not baseline["readable"] or baseline["targetDrawn"] == 0:
            raise RuntimeError("target not drawn or Accessibility unavailable before launch")
        with (root / "launch.log").open("w") as log:
            process = subprocess.Popen([str(binary), "-menuBarLayout.assignments", assignment],
                env=dict(os.environ, CFFIXED_USER_HOME=str(home), PORTSIDE_ASSERTION_HIDING="1"),
                stdout=log, stderr=subprocess.STDOUT)
            time.sleep(4)
            state = sample()
            if "items are hidden" in state["controlLabel"]:
                press()
                time.sleep(1)
                state = sample()
            if state["ownDrawn"] == 0 or state["targetDrawn"] == 0:
                raise RuntimeError("cannot establish revealed baseline")
            press()
            hidden_once = False
            deadline = time.monotonic() + args.seconds
            while time.monotonic() < deadline:
                time.sleep(0.25)
                state = sample()
                if not state["readable"]:
                    raise RuntimeError("AX snapshot unavailable during hold")
                hidden_once |= state["targetDrawn"] == 0
                if state["ownDrawn"] == 0:
                    report["failures"].append("Portside control owner disappeared while hiding")
                if hidden_once and state["targetDrawn"] > 0:
                    report["failures"].append("target reappeared without a reveal action")
            if not hidden_once:
                report["failures"].append("target never hid")
            if "items are hidden" in state["controlLabel"]:
                press()
            time.sleep(1)
            if sample()["targetDrawn"] == 0:
                report["failures"].append("explicit reveal failed")
    except (RuntimeError, subprocess.SubprocessError) as error:
        report["failures"].append(str(error))
    finally:
        if process:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            time.sleep(0.5)
            try:
                if sample()["targetDrawn"] == 0:
                    report["failures"].append("target not restored after process exit")
            except subprocess.SubprocessError as error:
                report["failures"].append(str(error))
        report["failures"] = sorted(set(report["failures"]))
        (root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"report": str(root / "report.json"), "failures": report["failures"]}))
    return bool(report["failures"])


if __name__ == "__main__":
    raise SystemExit(main())
