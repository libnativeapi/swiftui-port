#!/usr/bin/env python3
"""Exercise the DazzUI SwiftUI Gallery on the HarmonyOS PC emulator."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

deveco = Path(os.environ.get("DEVECO_STUDIO_HOME", "/Applications/DevEco-Studio.app/Contents"))
device = os.environ.get("HARMONY_DEVICE", "127.0.0.1:5555")
hdc = [str(deveco / "sdk/default/openharmony/toolchains/hdc"), "-t", device]
bundle = "dev.swiftuiport.runtimeprobe"
guest_layout = "/data/local/tmp/swiftui-gallery-layout.json"
guest_screenshot = "/data/local/tmp/swiftui-gallery-screenshot.jpeg"
screenshot_dir = os.environ.get("HARMONY_GALLERY_SCREENSHOTS")


def run(*args):
    return subprocess.run([*hdc, *args], text=True, check=True, capture_output=True, timeout=15).stdout


def controls(node):
    if node.get("attributes"):
        yield node["attributes"]
    for child in node.get("children", []):
        yield from controls(child)


def layout(local):
    run("shell", f"uitest dumpLayout -b {bundle} -p {guest_layout}")
    run("file", "recv", guest_layout, str(local))
    return list(controls(json.loads(local.read_text())))


def bounds(node):
    return tuple(map(int, re.findall(r"-?\d+", node["bounds"])))


def visible(node):
    x1, y1, x2, y2 = bounds(node)
    return x1 < x2 and y1 < y2


def wait(local, description, find):
    for _ in range(15):
        result = find(layout(local))
        if result:
            return result
        time.sleep(0.3)
    raise SystemExit(f"Could not verify {description}")


def text(nodes, name):
    return [node for node in nodes if node.get("text") == name and visible(node)]


def click(node):
    x1, y1, x2, y2 = bounds(node)
    run("shell", f"uitest uiInput click {(x1 + x2) // 2} {(y1 + y2) // 2}")


def control(nodes, key):
    return next((node for node in nodes if node.get("id") == key and visible(node)), None)


def selected(nodes, key):
    return (control(nodes, key) or {}).get("selected") == "true"


def screenshot(name):
    if screenshot_dir:
        output = Path(screenshot_dir)
        output.mkdir(parents=True, exist_ok=True)
        run("shell", f"snapshot_display -f {guest_screenshot}")
        run("file", "recv", guest_screenshot, str(output / f"{name}.jpeg"))


def button_typography(nodes):
    headings = text(nodes, "Theme")
    labels = text(nodes, "filled")
    button = control(nodes, "swift-action-filled")
    toggle = control(nodes, "swift-action-Switch to dark")
    if not headings or not labels or not button or not toggle:
        return False
    _, top, _, bottom = bounds(headings[0])
    _, toggle_top, _, toggle_bottom = bounds(toggle)
    x1, y1, x2, y2 = bounds(button)
    lx1, ly1, lx2, ly2 = bounds(labels[0])
    return bottom - top < toggle_bottom - toggle_top and x1 < lx1 < lx2 < x2 and y1 < ly1 < ly2 < y2


with tempfile.TemporaryDirectory() as directory:
    local = Path(directory) / "layout.json"
    run("shell", f"aa force-stop {bundle}")
    response = run("shell", f"aa start -b {bundle} -a EntryAbility --ps gallery true")
    assert "start ability successfully" in response, response

    wait(local, "Button page", lambda nodes: text(nodes, "Variants"))
    wait(local, "single-line Theme heading and button label within its control", button_typography)
    screenshot("button-light")
    print("SWIFT_GALLERY_PROBE PASS Button typography", flush=True)

    studio = wait(local, "Studio theme", lambda nodes: control(nodes, "swift-action-Studio"))
    click(studio)
    wait(local, "Studio selected", lambda nodes: selected(nodes, "swift-action-Studio"))

    bright = wait(local, "Bright theme", lambda nodes: control(nodes, "swift-action-Bright"))
    click(bright)
    wait(local, "Bright selected", lambda nodes: selected(nodes, "swift-action-Bright"))
    print("SWIFT_GALLERY_PROBE PASS Bright -> Studio -> Bright", flush=True)

    toggle = wait(local, "light theme toggle", lambda nodes: control(nodes, "swift-action-Switch to dark"))
    click(toggle)
    toggle = wait(local, "dark theme toggle", lambda nodes: control(nodes, "swift-action-Switch to light"))
    screenshot("button-dark")
    click(toggle)
    wait(local, "light theme restored", lambda nodes: control(nodes, "swift-action-Switch to dark"))
    print("SWIFT_GALLERY_PROBE PASS light -> dark -> light", flush=True)

    calendar = wait(local, "Calendar in the sidebar", lambda nodes: text(nodes, "Calendar"))[0]
    click(calendar)
    wait(local, "Calendar page", lambda nodes: len(text(nodes, "Calendar")) > 1)
    screenshot("calendar")
    print("SWIFT_GALLERY_PROBE PASS Button -> Calendar", flush=True)

    overview = wait(local, "Overview in the sidebar", lambda nodes: text(nodes, "Overview"))[0]
    click(overview)
    wait(local, "Overview", lambda nodes: len(text(nodes, "Overview")) > 1)
    screenshot("overview")
    print("SWIFT_GALLERY_PROBE PASS Calendar -> Overview", flush=True)

    collapsible = wait(local, "Collapsible in the sidebar", lambda nodes: control(nodes, "swift-action-Collapsible"))
    click(collapsible)
    test_log = wait(local, "Collapsible's Test log", lambda nodes: text(nodes, "Test log"))[0]
    click(test_log)
    wait(local, "Test log opened", lambda nodes: text(nodes, "All 37 tests passed."))
    screenshot("collapsible")
    click(wait(local, "open Test log", lambda nodes: text(nodes, "Test log"))[0])
    wait(local, "Test log closed", lambda nodes: not text(nodes, "All 37 tests passed."))
    print("SWIFT_GALLERY_PROBE PASS Collapsible opens and closes", flush=True)

    before = wait(local, "Calendar before scrolling", lambda nodes: text(nodes, "Calendar"))[0]
    scroll = next(node for node in layout(local) if node.get("type") == "Scroll" and visible(node))
    x1, y1, x2, y2 = bounds(scroll)
    x = x1 + (x2 - x1) // 2
    run("shell", f"uitest uiInput swipe {x} {y2 - 140} {x} {y1 + 300} 600")
    wait(local, "sidebar scrolling", lambda nodes: not text(nodes, "Calendar") or
         bounds(text(nodes, "Calendar")[0]) != bounds(before))
    print("SWIFT_GALLERY_PROBE PASS sidebar scroll", flush=True)

    run("shell", f"aa force-stop {bundle}")
    response = run("shell", f"aa start -b {bundle} -a EntryAbility --ps gallery true")
    assert "start ability successfully" in response, response
    editor = wait(local, "Search editor", lambda nodes: next(
        (node for node in nodes if node.get("type") == "TextInput" and
         node.get("hint") == "Search" and visible(node)), None))
    x1, y1, x2, y2 = bounds(editor)
    run("shell", f"uitest uiInput inputText {(x1 + x2) // 2} {(y1 + y2) // 2} Calendar")
    wait(local, "Swift search filter", lambda nodes: text(nodes, "Calendar") and
         not text(nodes, "Accordion") and any(node.get("type") == "TextInput" and
         node.get("text") == "Calendar" for node in nodes))
    print("SWIFT_GALLERY_PROBE PASS native search input filters Swift views", flush=True)
