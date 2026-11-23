import fcntl
import json
import os
import re
import subprocess
import sys
import time


def hyprctl(deadline, *args):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("desktop did not respond in time")
    return subprocess.check_output(
        ["hyprctl", *args], text=True, timeout=min(1, remaining)
    ).strip()


def pane_rect(monitor, role):
    # Split the monitor in logical coordinates after accounting for rotation and scale.
    width, height = monitor["width"], monitor["height"]
    if monitor["transform"] % 2:
        width, height = height, width
    left, top, right, bottom = monitor["reserved"]
    width = int(width / monitor["scale"]) - left - right
    height = int(height / monitor["scale"]) - top - bottom
    half = width // 2
    w = max(1, half - 16)
    h = max(1, min(height - 100, w * 9 // 16))
    x = monitor["x"] + left + 8 + (half if role == "guest" else 0)
    return x, monitor["y"] + top + 40, w, h


def place(output, titles, deadline):
    pending = set(titles)
    if not pending or any(not re.fullmatch(r"War pane \d+-\d+-(host|guest)", t) for t in pending):
        return

    # Use Lua dispatchers on Hyprland 0.55 and later.
    # https://wiki.hypr.land/0.55.0/configuring/basics/dispatchers/
    # https://wiki.hypr.land/0.54.0/configuring/dispatchers/
    version = json.loads(hyprctl(deadline, "-j", "version"))
    release = re.search(r"(\d+)\.(\d+)", version.get("version") or version.get("tag", ""))
    use_lua_dispatch = release and tuple(map(int, release.groups())) >= (0, 55)
    monitors = json.loads(hyprctl(deadline, "-j", "monitors"))
    monitor = next((m for m in monitors if m["name"] == output), None)
    for delay in (0.05, 0.2, 0.4):
        time.sleep(delay)
        clients = json.loads(hyprctl(deadline, "-j", "clients"))
        lua, legacy = [], []
        for title in sorted(pending):
            matches = [c for c in clients if title in (c["initialTitle"], c["title"])]
            if len(matches) != 1:
                continue
            client = matches[0]
            if monitor is None:
                monitor = next((m for m in monitors if m["id"] == client["monitor"]), None)
            if monitor is None:
                continue
            field = "initialtitle" if client["initialTitle"] == title else "title"
            selector = f"{field}:^{title}$"
            x, y, w, h = pane_rect(monitor, title.rsplit("-", 1)[1])
            if use_lua_dispatch:
                target = f'window="{selector}"'
                lua.extend([
                    f'hl.dispatch(hl.dsp.window.float({{{target},action="set"}}))',
                    f'hl.dispatch(hl.dsp.window.resize({{{target},x={w},y={h},relative=false}}))',
                    f'hl.dispatch(hl.dsp.window.move({{{target},x={x},y={y},relative=false}}))',
                ])
            else:
                legacy.extend([
                    "dispatch setfloating " + selector,
                    f"dispatch resizewindowpixel exact {w} {h},{selector}",
                    f"dispatch movewindowpixel exact {x} {y},{selector}",
                ])
            pending.remove(title)

        if lua:
            hyprctl(deadline, "eval", "\n".join(lua))
        if legacy:
            hyprctl(deadline, "--batch", "; ".join(legacy))
        if not pending:
            return
    if pending:
        sys.exit("War pane placement timed out waiting for the new window")


if __name__ == "__main__":
    try:
        deadline = time.monotonic() + 2
        # Serialize pane placement when two clients share a desktop.
        with open(os.path.join(os.environ["XDG_RUNTIME_DIR"], "war-hyprland-placement.lock"), "a") as lock:
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline - 1:
                        sys.exit("War pane placement skipped: another request is still active")
                    time.sleep(0.05)
            place(sys.argv[1], sys.argv[2:], deadline)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(f"War pane placement failed: {error}")
