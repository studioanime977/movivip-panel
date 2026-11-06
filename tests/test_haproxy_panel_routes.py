import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER_PATH = ROOT / "lib" / "haproxy_panel_routes.py"
SPEC = importlib.util.spec_from_file_location("haproxy_panel_routes", HELPER_PATH)
ROUTES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ROUTES)


CONFIG = """global
    daemon

frontend multiport_frontend
    mode tcp
    bind *:443
    bind *:8443
    use_backend h2_recir_backend if acl_alpn_h2

frontend ssl_frontend
    mode tcp
    bind *:80
    bind *:8080
    acl acl_path_mxvmess path_reg -i ^/mx-vmess$
    use_backend mx_vmess_backend if acl_path_mxvmess
    use_backend websocket_backend if acl_upgrade acl_websocket
    default_backend ssh_ws_default_backend

frontend h2_frontend
    mode http
    default_backend h2_not_found_backend

backend existing_backend
    mode tcp
    server existing 127.0.0.1:10015 check

# BEGIN MOVIVIP-PANEL ROUTES
backend mx_vmess_backend
    mode tcp
    server mx_vmess 127.0.0.1:11002 check
# END MOVIVIP-PANEL ROUTES
"""


class HaproxyPanelRoutesTests(unittest.TestCase):
    def test_routes_are_separated_and_idempotent(self):
        updated = ROUTES.add_routes(CONFIG)
        repeated = ROUTES.add_routes(updated)
        self.assertEqual(updated, repeated)

        ssl_frontend = updated.split("frontend ssl_frontend\n", 1)[1].split(
            "\nfrontend h2_frontend", 1
        )[0]
        h2_frontend = updated.split("frontend h2_frontend\n", 1)[1].split(
            "\nbackend existing_backend", 1
        )[0]
        self.assertIn("req.payload(0,256)", ssl_frontend)
        self.assertNotIn(" path_reg ", ssl_frontend)
        self.assertLess(
            ssl_frontend.index("use_backend mx_vmess_backend"),
            ssl_frontend.index("use_backend websocket_backend if acl_upgrade"),
        )
        self.assertIn("path_beg -i /mx-vmess-grpc", h2_frontend)
        self.assertIn("use_backend mx_grpc_vmess_backend", h2_frontend)
        ssl_frontend = updated.split("frontend ssl_frontend\n", 1)[1].split(
            "\nfrontend h2_frontend", 1
        )[0]
        tls_frontend = updated.split("frontend multiport_frontend\n", 1)[1].split(
            "\nfrontend ssl_frontend", 1
        )[0]
        for port in (80, 8080):
            self.assertIn(f"bind *:{port}", ssl_frontend)
        for port in (443, 8443):
            self.assertIn(f"bind *:{port}", tls_frontend)

        for port in (11002, 11003, 11004, 11012, 11013, 11014):
            self.assertIn(f"127.0.0.1:{port}", updated)
        self.assertIn("server existing 127.0.0.1:10015 check", updated)
        self.assertEqual(updated.count("\nbackend mx_vmess_backend\n"), 1)
        self.assertNotIn("# BEGIN MOVIVIP-PANEL ROUTES\n", updated)

    def test_helper_reports_changes_and_unchanged_config(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config = Path(temp_dir) / "haproxy.cfg"
            config.write_text(CONFIG, encoding="utf-8")
            command = [sys.executable, str(HELPER_PATH), str(config)]
            first = subprocess.run(command, capture_output=True, text=True, check=True)
            second = subprocess.run(command, capture_output=True, text=True, check=True)
            self.assertIn("MOVIVIP_PANEL_ROUTES_UPDATED", first.stdout)
            self.assertIn("MOVIVIP_PANEL_ROUTES_UNCHANGED", second.stdout)


if __name__ == "__main__":
    unittest.main()
