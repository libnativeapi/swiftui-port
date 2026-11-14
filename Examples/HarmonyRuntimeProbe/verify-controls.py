#!/usr/bin/env python3
"""Click the ArkUI node generated from Swift and verify the updated label."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def controls(node):
    yield node.get("attributes", {})
    for child in node.get("children", []):
        yield from controls(child)


deveco = Path(os.environ.get("DEVECO_STUDIO_HOME", "/Applications/DevEco-Studio.app/Contents"))
device = os.environ.get("HARMONY_DEVICE", "127.0.0.1:5555")
hdc = [str(deveco / "sdk/default/openharmony/toolchains/hdc"), "-t", device]
bundle = "dev.swiftuiport.runtimeprobe"
guest_layout = "/data/local/tmp/swiftui-runtime-probe-layout.json"


def layout(local):
    subprocess.run([*hdc, "shell", f"uitest dumpLayout -b {bundle} -p {guest_layout}"],
                   check=True, capture_output=True, timeout=10)
    subprocess.run([*hdc, "file", "recv", guest_layout, str(local)],
                   check=True, capture_output=True, timeout=10)
    return list(controls(json.loads(local.read_text())))


with tempfile.TemporaryDirectory() as directory:
    local = Path(directory) / "layout.json"
    for _ in range(8):
        nodes = layout(local)
        buttons = [node for node in nodes if node.get("type") == "Button" and
                   node.get("text") == "Increment" and node.get("clickable") == "true"]
        if len(buttons) == 1 and any(node.get("text") == "Count: 1" for node in nodes):
            break
        time.sleep(0.25)
    else:
        raise SystemExit("Native Increment button and initial Swift label were not found")

    x1, y1, x2, y2 = map(int, re.findall(r"-?\d+", buttons[0]["bounds"]))
    if x1 >= x2 or y1 >= y2:
        raise SystemExit("Native Increment button is not visible")
    x, y = (x1 + x2) // 2, (y1 + y2) // 2
    subprocess.run([*hdc, "shell", f"uitest uiInput click {x} {y}"], check=True, timeout=10)

    for _ in range(8):
        if any(node.get("text") == "Count: 2" for node in layout(local)):
            print("SWIFT_ARKUI_PROBE PASS Count: 1 -> Count: 2")
            break
        time.sleep(0.25)
    else:
        raise SystemExit("The native Swift label did not change after the click")
