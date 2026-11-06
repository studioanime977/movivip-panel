import copy
import importlib.util
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER_PATH = ROOT / "lib" / "haproxy_panel_inbounds.py"
SPEC = importlib.util.spec_from_file_location("haproxy_panel_inbounds", HELPER_PATH)
INBOUNDS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INBOUNDS)


class HaproxyPanelInboundTests(unittest.TestCase):
    def setUp(self):
        self.preset = json.loads(
            (ROOT / "presets" / "haproxy-inbounds.json").read_text(encoding="utf-8")
        )
        self.inbound = self.preset["inbounds"][1]
        self.existing = {
            "id": 8,
            "up": 1024,
            "down": 2048,
            "total": 0,
            "remark": "443 público | VLESS | interno 11003",
            "enable": True,
            "expiryTime": 0,
            "listen": "127.0.0.1",
            "port": 11003,
            "protocol": "vless",
            "settings": json.dumps(
                {"clients": [{"id": "preserve-this-client", "email": "existing"}]}
            ),
            "streamSettings": json.dumps(self.inbound["streamSettings"]),
            "tag": "mx-vless-ws",
            "sniffing": {"enabled": True, "destOverride": ["http", "tls"]},
            "allocate": {"strategy": "always"},
            "lastOnline": 123,
        }

    def test_api_base_includes_and_normalizes_panel_web_base_path(self):
        self.assertEqual(
            INBOUNDS.api_base("54322", "/secret-prefix/"),
            "http://127.0.0.1:54322/secret-prefix",
        )
        self.assertEqual(
            INBOUNDS.api_base("54322", ""),
            "http://127.0.0.1:54322",
        )

    def test_existing_route_changes_only_display_remark_and_preserves_clients(self):
        self.existing["listen"] = ""
        original = copy.deepcopy(self.existing)
        calls = []

        def request(method, path, payload):
            calls.append((method, path, payload))
            return {"success": True}

        failures = INBOUNDS.sync_inbounds(
            {"inbounds": [self.inbound]}, [self.existing], request, set()
        )

        self.assertEqual(failures, [])
        self.assertEqual(len(calls), 1)
        method, path, payload = calls[0]
        self.assertEqual((method, path), ("POST", "/panel/api/inbounds/update/8"))
        self.assertEqual(payload["remark"], self.inbound["remark"])
        self.assertEqual(payload["settings"], original["settings"])
        self.assertEqual(payload["streamSettings"], original["streamSettings"])
        self.assertEqual(payload["tag"], original["tag"])
        self.assertEqual(payload["allocate"], original["allocate"])
        self.assertEqual(payload["up"], original["up"])
        self.assertNotIn("id", payload)
        self.assertNotIn("lastOnline", payload)
        self.assertEqual(payload["listen"], "")
        self.assertEqual(self.existing, original)

    def test_matching_name_is_idempotent(self):
        current = copy.deepcopy(self.existing)
        current["remark"] = self.inbound["remark"]
        calls = []

        failures = INBOUNDS.sync_inbounds(
            {"inbounds": [self.inbound]},
            [current],
            lambda *args: calls.append(args),
            set(),
        )

        self.assertEqual(failures, [])
        self.assertEqual(calls, [])

    def test_missing_route_is_created_with_visible_port_map(self):
        calls = []

        def request(method, path, payload):
            calls.append((method, path, payload))
            return {"success": True}

        failures = INBOUNDS.sync_inbounds(
            {"inbounds": [self.inbound]}, [], request, set()
        )

        self.assertEqual(failures, [])
        self.assertEqual(calls[0][1], "/panel/api/inbounds/add")
        self.assertEqual(calls[0][2]["remark"], self.inbound["remark"])

    def test_preset_has_six_inbounds_with_shared_public_port_notes(self):
        inbounds = self.preset["inbounds"]
        self.assertEqual(len(inbounds), 6)
        self.assertNotIn("port_specific", self.preset)

        ws = [item for item in inbounds if item["streamSettings"]["network"] == "ws"]
        grpc = [item for item in inbounds if item["streamSettings"]["network"] == "grpc"]
        self.assertEqual(len(ws), 3)
        self.assertEqual(len(grpc), 3)
        for inbound in ws:
            self.assertIn("80/8080", inbound["remark"])
            self.assertIn("443/8443", inbound["remark"])
        for inbound in grpc:
            self.assertIn("443/8443", inbound["remark"])

    def test_full_sync_creates_only_six_shared_inbounds(self):
        calls = []

        def request(method, path, payload):
            calls.append((path, payload))
            return {"success": True}

        failures = INBOUNDS.sync_inbounds(self.preset, [], request, set())

        self.assertEqual(failures, [])
        self.assertEqual(len(calls), 6)
        created = {payload["tag"]: payload for _, payload in calls}
        for inbound in self.preset["inbounds"]:
            self.assertEqual(created[inbound["tag"]]["port"], inbound["port"])
            self.assertEqual(created[inbound["tag"]]["remark"], inbound["remark"])
        self.assertEqual(
            INBOUNDS.verify_inbounds(self.preset, list(created.values())), []
        )

    def test_port_collision_with_different_route_is_not_modified(self):
        other = copy.deepcopy(self.existing)
        other["streamSettings"] = json.dumps(
            {"network": "ws", "wsSettings": {"path": "/unrelated"}}
        )
        calls = []

        failures = INBOUNDS.sync_inbounds(
            {"inbounds": [self.inbound]},
            [other],
            lambda *args: calls.append(args),
            set(),
        )

        self.assertEqual(failures, [self.inbound["tag"]])
        self.assertEqual(calls, [])

if __name__ == "__main__":
    unittest.main()
