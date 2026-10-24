import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("configure", PROJECT / "scripts/configure.py")
configure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configure)


def profile():
    return {"profile_version": 1, "controllers": [{
        "name": "Test case", "vendor": "Example vendor", "description": "Test controller",
        "serial": "TEST-ONLY", "location": "test-location", "version": "1",
        "colors": [0, 0, 0], "zones": [{"name": "Front"}, {"name": "Rear"}],
        "modes": [{"name": "Direct"}],
    }]}


class ConfigurationTests(unittest.TestCase):
    def test_requires_explicit_choice_for_multiple_controllers(self):
        data = profile()
        second = copy.deepcopy(data["controllers"][0])
        second["serial"] = "SECOND-TEST-ONLY"
        data["controllers"].append(second)
        with self.assertRaises(ValueError):
            configure.select_controller(data)
        self.assertEqual(configure.select_controller(data, 1)["serial"], "SECOND-TEST-ONLY")

    def test_rejects_ambiguous_identity_and_unsupported_modes(self):
        data = profile()
        data["controllers"] *= 2
        with self.assertRaises(ValueError):
            configure.select_controller(data, 0)
        data = profile()
        data["controllers"][0]["modes"] = [{"name": "Static"}]
        with self.assertRaises(ValueError):
            configure.select_controller(data, 0)

    def test_requires_writable_physical_speaker(self):
        device = {"uid": "TEST-SPEAKER", "name": "USB AUDIO", "output_channels": 2,
                  "volume_writable": True, "mute_writable": True}
        self.assertEqual(configure.select_speaker([device])["uid"], "TEST-SPEAKER")
        for key, value in [("volume_writable", False), ("mute_writable", False),
                           ("output_channels", 4), ("uid", "BlackHole2ch_UID")]:
            invalid = dict(device, **{key: value})
            with self.assertRaises(ValueError):
                configure.select_speaker([invalid], invalid["uid"])

    def test_music_profile_only_targets_selected_device(self):
        data = profile()
        before = copy.deepcopy(data)
        template = configure.read_json(PROJECT / "config/music-effect.json")
        music = configure.make_music_profile(data, data["controllers"][0], template, 2)
        zones = music["plugins"]["OpenRGB Effects Plugin"]["Effects"][0]["ControllerZones"]
        self.assertEqual([z["zone_idx"] for z in zones], [0, 1])
        self.assertTrue(all(z["serial"] == "TEST-ONLY" for z in zones))
        self.assertEqual(data, before)
        self.assertEqual(template["ControllerZones"], [])

    def test_repeated_setup_preserves_settings_and_backs_up_profiles(self):
        with tempfile.TemporaryDirectory() as temp:
            data, profiles = Path(temp) / "data", Path(temp) / "profiles"
            configure.write_configuration(data, profiles, {"version": 1}, {"music": 1})
            settings = data / "manager-settings.json"
            settings.write_text('{"userSetting":42}')
            default = profiles / "default.json"
            default.write_text('{"untouched":true}')
            before = (data / "device-config.json").read_bytes()
            with self.assertRaises(ValueError):
                configure.write_configuration(data, profiles, {"version": 2}, {"music": 2})
            self.assertEqual((data / "device-config.json").read_bytes(), before)
            configure.write_configuration(data, profiles, {"version": 2}, {"music": 2}, replace=True)
            self.assertEqual(settings.read_text(), '{"userSetting":42}')
            self.assertEqual(default.read_text(), '{"untouched":true}')
            backup = next((data / "config-backups").iterdir())
            self.assertEqual((backup / "device-config.json").read_bytes(), before)

    def test_partial_write_failure_restores_prior_configuration(self):
        with tempfile.TemporaryDirectory() as temp:
            data, profiles = Path(temp) / "data", Path(temp) / "profiles"
            configure.write_configuration(data, profiles, {"version": 1}, {"music": 1})
            before = (data / "device-config.json").read_bytes()
            real_write = configure.atomic_write

            def fail_music(path, payload):
                if path.name == "音乐同步.json":
                    raise OSError("simulated storage failure")
                real_write(path, payload)

            with patch.object(configure, "atomic_write", side_effect=fail_music):
                with self.assertRaises(OSError):
                    configure.write_configuration(data, profiles, {"version": 2}, {"music": 2}, replace=True)
            self.assertEqual((data / "device-config.json").read_bytes(), before)
            self.assertEqual(json.loads((profiles / "音乐同步.json").read_text()), {"music": 1})


if __name__ == "__main__":
    unittest.main()
