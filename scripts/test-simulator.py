#!/usr/bin/env python3
"""Opt-in browser integration test. Creates/deletes only its own disposable Device."""
import argparse
import json
from pathlib import Path
import selectors
import shutil
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def run(*args, capture=False, timeout=180):
    result = subprocess.run(args, cwd=ROOT, text=True, check=True,
                            stdout=subprocess.PIPE if capture else None, timeout=timeout)
    return result.stdout.strip() if capture else None


def wait_for(check, description, timeout=20):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            if check():
                return
        except (OSError, ValueError):
            pass
        time.sleep(0.1)
    raise AssertionError(f"Timed out: {description}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device-type", default="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
    args = parser.parse_args()
    if not shutil.which("agent-browser"):
        raise RuntimeError("Install agent-browser and Chrome to run this opt-in test")
    run("make", "cli")
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "-j", capture=True))["runtimes"]
    available = [r for r in runtimes if r.get("isAvailable") and ".iOS-" in r["identifier"]
                 and int(r["version"].split(".")[0]) >= 26]
    if not available:
        raise RuntimeError("Install an iOS 26+ Simulator runtime in Xcode first")
    runtime = max(available, key=lambda r: tuple(map(int, r["version"].split("."))))
    udid, other_udid, server, session, peer = None, None, None, None, None
    with tempfile.TemporaryDirectory(prefix="simulator-smoke-", dir=ROOT / "build") as folder:
        app = Path(folder) / "SimulatorSmoke.app"
        app.mkdir()
        shutil.copyfile(ROOT / "Tests/SimulatorSmoke/Info.plist", app / "Info.plist")
        sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path", capture=True)
        run("xcrun", "--sdk", "iphonesimulator", "swiftc", "-parse-as-library", "-sdk", sdk,
            "-target", "arm64-apple-ios26.0-simulator", "Tests/SimulatorSmoke/App.swift",
            "-o", str(app / "SimulatorSmoke"))
        run("codesign", "--force", "--sign", "-", str(app))
        try:
            udid = run("xcrun", "simctl", "create", "Muxify browser smoke test", args.device_type,
                       runtime["identifier"], capture=True)
            other_udid = run("xcrun", "simctl", "create", "Muxify browser smoke peer", args.device_type,
                             runtime["identifier"], capture=True)
            session = "muxify-smoke-" + udid.lower()
            peer = session + "-peer"
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                port = reservation.getsockname()[1]
            # Use the distributable executable, with no NSApplication or desktop app startup.
            server = subprocess.Popen([str(ROOT / "build/bin/muxify"), "simulator", "serve", "--port", str(port)],
                                      cwd=ROOT, text=True, stdout=subprocess.PIPE)
            selector = selectors.DefaultSelector()
            selector.register(server.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=20):
                raise RuntimeError("Simulator Server did not print its URL")
            url = server.stdout.readline().strip().removeprefix("Muxify Simulator: ")
            selector.close()
            if not url.startswith("http://"):
                raise RuntimeError(f"Simulator Server did not start (exit={server.poll()}, output={url!r})")

            def browser(*arguments, client=None):
                result = run("agent-browser", "--session", client or session, "--json", *arguments, capture=True, timeout=35)
                reply = json.loads(result)
                if not reply.get("success"):
                    raise AssertionError(reply)
                return reply.get("data", {}).get("result")

            def evaluate(code):
                return browser("eval", code)

            def device_state(device=udid):
                records = json.loads(run("xcrun", "simctl", "list", "devices", "-j", capture=True))["devices"]
                return next(d["state"] for group in records.values() for d in group if d["udid"] == device)

            def click_at(x, y):
                point = evaluate(f"(() => {{ const r=document.getElementById('screen').getBoundingClientRect(); return [r.left+r.width*{x},r.top+r.height*{y}]; }})()")
                browser("mouse", "move", str(round(point[0])), str(round(point[1])))
                browser("mouse", "down")
                browser("mouse", "up")

            browser("open", url)
            browser("wait", "--fn", f"!!document.querySelector('#devices option[value=\"{udid}\"]')")
            browser("select", "#devices", udid)
            browser("wait", "--fn", "!document.getElementById('start').disabled")
            assert device_state() == "Shutdown", "Selection unexpectedly booted Device"
            browser("click", "#start")
            wait_for(lambda: device_state() == "Booted", "explicit browser Start Device", timeout=120)
            browser("wait", "--fn", "!document.getElementById('screen').hidden")
            # Another browser and another tab in the same browser may share one Device.
            browser("open", url, client=peer)
            browser("wait", "--fn", f"!!document.querySelector('#devices option[value=\"{udid}\"]')", client=peer)
            browser("select", "#devices", udid, client=peer)
            browser("wait", "--fn", "!document.getElementById('screen').hidden && document.getElementById('viewers').textContent.startsWith('2 ')", client=peer)
            browser("tab", "new", "--label", "shared", url)
            browser("wait", "--fn", f"!!document.querySelector('#devices option[value=\"{udid}\"]')")
            browser("select", "#devices", udid)
            browser("wait", "--fn", "!document.getElementById('screen').hidden && document.getElementById('viewers').textContent.startsWith('3 ')")
            browser("tab", "close", "shared")
            browser("tab", "t1")
            browser("wait", "--fn", "document.getElementById('viewers').textContent.startsWith('2 ')")

            # Rotate SpringBoard too: its portrait-only layout must not undo a physical turn.
            for expected in [90, 180, 270, 0]:
                browser("click", "#rotate")
                browser("wait", "--fn", f"state.rotation === {expected} && shownRotation === {expected}")
                browser("wait", "--fn", f"state.rotation === {expected} && shownRotation === {expected}", client=peer)
            browser("select", "#devices", other_udid, client=peer)
            browser("wait", "--fn", "!document.getElementById('start').disabled", client=peer)
            browser("wait", "--fn", "document.getElementById('viewers').textContent.startsWith('1 ')")
            assert device_state(other_udid) == "Shutdown", "Peer selection booted Device"
            browser("click", "#start", client=peer)
            wait_for(lambda: device_state(other_udid) == "Booted", "independent peer Start", timeout=120)
            browser("wait", "--fn", "!document.getElementById('screen').hidden", client=peer)
            browser("click", "#rotate", client=peer)
            browser("wait", "--fn", "shownRotation === 90", client=peer)
            assert evaluate("state.selected") == udid and evaluate("shownRotation") == 0, "Peer changed original Device"
            browser("click", "#stop", client=peer)
            wait_for(lambda: device_state(other_udid) == "Shutdown", "independent peer Stop")
            assert device_state() == "Booted", "Peer Stop shut down original Device"
            browser("select", "#devices", udid, client=peer)
            browser("wait", "--fn", "!document.getElementById('screen').hidden", client=peer)
            run("xcrun", "simctl", "install", udid, str(app))
            run("xcrun", "simctl", "launch", udid, "dev.muxify.simulator-smoke")
            container = Path(run("xcrun", "simctl", "get_app_container", udid,
                                 "dev.muxify.simulator-smoke", "data", capture=True))
            fixture = container / "Documents/smoke.json"
            read_fixture = lambda: json.loads(fixture.read_text())
            wait_for(lambda: fixture.exists(), "fixture launch")
            click_at(0.5, 0.25)
            browser("press", "Shift+a")
            browser("press", "b")
            browser("press", "Shift+1")
            wait_for(lambda: read_fixture()["text"] == "Ab!", "real browser keyboard input")
            # The guest can keep its software keyboard visible with hardware input enabled.
            # Submit the field so that it no longer covers the fixture's Tap button.
            browser("press", "Enter")
            wait_for(lambda: not read_fixture()["textFocused"], "dismiss guest software keyboard")
            click_at(0.5, 0.75)
            wait_for(lambda: read_fixture()["taps"] >= 1, "portrait tap")
            point = evaluate("(() => { const r=document.getElementById('screen').getBoundingClientRect(); return [r.left+r.width/2,r.top+r.height/2,r.height]; })()")
            browser("mouse", "move", str(round(point[0])), str(round(point[1])))
            browser("mouse", "down")
            for step in range(1, 6):
                browser("mouse", "move", str(round(point[0])), str(round(point[1] - point[2] * step / 100)))
            browser("mouse", "up")
            wait_for(lambda: read_fixture()["drags"] >= 1, "real browser swipe")
            portrait = ROOT / "build/simulator-browser-portrait.png"
            browser("screenshot", str(portrait))
            for width, height in [(320, 640), (390, 844), (768, 1024), (1280, 720)]:
                browser("set", "viewport", str(width), str(height))
                browser("wait", "--fn", "(() => { const r=document.getElementById('device-frame').getBoundingClientRect(), stage=document.querySelector('.stage').getBoundingClientRect(); return document.documentElement.scrollWidth<=innerWidth && r.left>=stage.left && r.right<=stage.right && r.top>=stage.top && r.bottom<=stage.bottom; })()")
                browser("screenshot", str(ROOT / f"build/simulator-browser-{width}.png"))
            browser("click", "#rotate")
            browser("wait", "--fn", "document.getElementById('screen').width > document.getElementById('screen').height && !document.getElementById('rotate').disabled")
            wait_for(lambda: read_fixture()["width"] > read_fixture()["height"], "guest landscape layout")
            browser("wait", "--fn", "document.getElementById('screen').width > document.getElementById('screen').height", client=peer)
            # UIKit reports the new size before its rotation animation finishes; it
            # intentionally ignores touches during that animation, as in Apple's Simulator.
            time.sleep(0.7)
            taps = read_fixture()["taps"]
            click_at(0.5, 0.75)
            wait_for(lambda: read_fixture()["taps"] > taps, "landscape input coordinate mapping")
            browser("screenshot", str(ROOT / "build/simulator-browser-landscape.png"))
            # Global Home must also clear another browser's locally held modifier state.
            evaluate("(() => { const screen=document.getElementById('screen'); screen.focus(); screen.dispatchEvent(new KeyboardEvent('keydown',{code:'ShiftLeft',key:'Shift',shiftKey:true})); })()")
            browser("click", "#home", client=peer)
            wait_for(lambda: read_fixture()["phase"] == "background", "browser Home button")
            browser("wait", "--fn", "heldKeys.size === 0")
            browser("close")
            assert device_state() == "Booted", "Closing browser shut down Device"
            browser("open", url)
            browser("wait", "--fn", f"!!document.querySelector('#devices option[value=\"{udid}\"]')")
            browser("select", "#devices", udid)
            browser("wait", "--fn", "!document.getElementById('screen').hidden")
            browser("click", "#stop")
            wait_for(lambda: device_state() == "Shutdown", "explicit browser Stop Device")
            browser("wait", "--fn", "document.getElementById('screen').hidden && !document.getElementById('start').disabled", client=peer)
            print("PASS: shared tabs/browsers, independent Devices, selection/start, JPEG rendering, responsive frames, keyboard, tap/swipe, four-way Home-screen rotation, guest rotation, Home, disconnect/reconnect, shared stop")
        except Exception:
            if session:
                subprocess.run(["agent-browser", "--session", session, "screenshot",
                                str(ROOT / "build/simulator-browser-failure.png")], cwd=ROOT, timeout=30)
                subprocess.run(["agent-browser", "--session", session, "errors"], cwd=ROOT, timeout=30)
            if "fixture" in locals() and fixture.exists():
                print("Fixture state:", fixture.read_text(), flush=True)
            raise
        finally:
            if session:
                subprocess.run(["agent-browser", "--session", session, "close"], cwd=ROOT, timeout=30)
            if peer:
                subprocess.run(["agent-browser", "--session", peer, "close"], cwd=ROOT, timeout=30)
            if server:
                server.terminate()
                try:
                    server.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    server.kill(); server.wait(timeout=5)
            for disposable in [other_udid, udid]:
                if not disposable:
                    continue
                # Never shutdown all or touch another Device, even after a failed assertion.
                if "device_state" not in locals() or device_state(disposable) != "Shutdown":
                    subprocess.run(["xcrun", "simctl", "shutdown", disposable], cwd=ROOT, timeout=60)
                run("xcrun", "simctl", "delete", disposable)


if __name__ == "__main__":
    main()
