#!/usr/bin/env python3
"""Prepare local profiles without starting apps or changing audio/LED state."""
import argparse
import copy
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
DEFAULT_SETTINGS = {
    "brightness": 100, "sensitivity": 65, "fps": 60,
    "dailyColor": 255, "startupMode": "daily", "lastMode": "daily",
}


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def identity(controller):
    result = {key: controller[key] for key in ("vendor", "description", "serial")}
    if not all(isinstance(value, str) for value in result.values()):
        raise ValueError("Controller identity fields must be strings")
    return result


def select_controller(profile, index=None):
    controllers = profile.get("controllers", [])
    eligible = [i for i, c in enumerate(controllers)
                if c.get("colors") and any(m.get("name") == "Direct" for m in c.get("modes", []))]
    if index is None:
        if len(eligible) != 1:
            raise ValueError("Use --list, then choose exactly one --controller-index")
        index = eligible[0]
    if index not in eligible:
        raise ValueError("Selected controller must have LEDs and Direct mode")
    controller = controllers[index]
    selected = identity(controller)
    if sum(identity(c) == selected for c in controllers) != 1:
        raise ValueError("Controller identity is ambiguous; cannot safely select this device")
    if not controller.get("zones"):
        raise ValueError("Selected controller has no zones for the music effect")
    return controller


def select_speaker(devices, uid=None):
    if uid:
        matches = [d for d in devices if d.get("uid") == uid]
    else:
        matches = [d for d in devices if d.get("name") == "USB AUDIO"]
    if len(matches) != 1:
        raise ValueError("Use --list, then supply the speaker's --speaker-uid")
    device = matches[0]
    if device.get("output_channels") != 2 or not device.get("volume_writable") or not device.get("mute_writable"):
        raise ValueError("Speaker must have 2 output channels and writable master volume/mute")
    if device["uid"] in ("BlackHole2ch_UID", "local.openrgb.music-sync.usb-audio"):
        raise ValueError("Select the physical speaker, not a virtual or multi-output device")
    return device


def make_music_profile(profile, controller, template, audio_device_index=0):
    effect = copy.deepcopy(template)
    effect["ControllerZones"] = []
    effect["CustomSettings"]["audio_settings"]["audio_device"] = audio_device_index
    for index, _ in enumerate(controller["zones"]):
        zone = {key: controller.get(key, "") for key in ("vendor", "description", "serial", "location", "version")}
        zone.update(name="", is_segment=False, reverse=False, segment_idx=-1,
                    self_brightness=100, zone_idx=index)
        effect["ControllerZones"].append(zone)
    return {
        "profile_name": "音乐同步", "profile_version": profile["profile_version"],
        "controllers": [copy.deepcopy(controller)],
        "plugins": {"OpenRGB Effects Plugin": {"version": 2, "Effects": [effect]}},
    }


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".openrgb-config-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def write_configuration(data_dir, profiles_dir, config, music, replace=False):
    targets = {
        data_dir / "device-config.json": config,
        profiles_dir / "音乐同步.json": music,
    }
    settings = data_dir / "manager-settings.json"
    if not settings.exists():
        targets[settings] = DEFAULT_SETTINGS
    conflicts = [path for path in targets if path.exists()]
    if conflicts and not replace:
        raise ValueError("Existing configuration found; inspect it first, then use --replace to back up and replace")
    before = {path: path.read_bytes() if path.exists() else None for path in targets}
    if conflicts:
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        backup = data_dir / "config-backups" / stamp
        backup.mkdir(parents=True)
        for path in conflicts:
            shutil.copy2(path, backup / path.name)
        print(f"Backup: {backup}")
    written = []
    try:
        for path, value in targets.items():
            atomic_write(path, (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
            written.append(path)
    except Exception:
        for path in reversed(written):
            if before[path] is None:
                path.unlink()
            else:
                atomic_write(path, before[path])
        raise
    return list(targets)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="List audio devices and saved controllers only")
    parser.add_argument("--speaker-uid")
    parser.add_argument("--controller-index", type=int)
    parser.add_argument("--audio-device-index", type=int, default=0, help="Effects Plugin audio input index; verify BlackHole in the plugin")
    parser.add_argument("--binary", type=Path, default=PROJECT / "dist/OpenRGB Volume.app/Contents/MacOS/OpenRGBVolume")
    parser.add_argument("--data-dir", type=Path, default=Path(os.environ.get("OPENRGB_MANAGER_DATA_DIR", Path.home() / "Library/Application Support/OpenRGB-Volume")))
    parser.add_argument("--profiles-dir", type=Path, default=Path(os.environ.get("OPENRGB_MANAGER_PROFILE_DIR", Path.home() / ".config/OpenRGB/profiles")))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--replace", action="store_true", help="Back up and replace device/music configuration; preserve user settings")
    args = parser.parse_args()
    try:
        devices = json.loads(subprocess.check_output([str(args.binary), "--list-audio"], text=True))
        profile = read_json(args.profiles_dir / "default.json")
        if args.list:
            print(json.dumps({"audio": devices, "controllers": [
                {"index": i, "name": c.get("name"), "vendor": c.get("vendor"),
                 "leds": len(c.get("colors", [])), "modes": [m.get("name") for m in c.get("modes", [])]}
                for i, c in enumerate(profile.get("controllers", []))]}, ensure_ascii=False, indent=2))
            return
        if args.audio_device_index < 0:
            raise ValueError("Audio input index must be nonnegative")
        controller = select_controller(profile, args.controller_index)
        speaker = select_speaker(devices, args.speaker_uid)
        config = {"speakerUID": speaker["uid"], "controller": identity(controller)}
        music = make_music_profile(profile, controller, read_json(PROJECT / "config/music-effect.json"), args.audio_device_index)
        print(f"Speaker: {speaker['name']}; controller: {controller.get('name') or controller['description']}")
        if args.dry_run:
            print("Dry run: no files, audio routes, or lights changed")
            return
        for path in write_configuration(args.data_dir, args.profiles_dir, config, music, args.replace):
            print(f"Written: {path}")
        print("Configuration ready. No apps started; audio routing and lights unchanged.")
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Configuration failed: {error}\n")


if __name__ == "__main__":
    main()
