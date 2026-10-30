"""Exercise the packaged systemd invocation with the real collector binary."""

import configparser
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import tempfile
import unittest


BINARY, UNIT, CONFIG = sys.argv[1:4]
del sys.argv[1:]


class ServiceLaunchTest(unittest.TestCase):
    def test_unit_loads_packaged_json_before_starting_network_clients(self):
        unit = configparser.ConfigParser(interpolation=None, strict=False)
        unit.read(UNIT)
        argv = shlex.split(unit["Service"]["ExecStart"])
        config = json.loads(Path(CONFIG).read_text())
        # Hold the metrics port to stop startup deterministically after config
        # validation and before a NATS connection. No deployed service is used.
        with socket.socket() as occupied, tempfile.TemporaryDirectory() as tmp:
            occupied.bind(("127.0.0.1", 0))
            occupied.listen()
            config["metrics_addr"] = "127.0.0.1:" + str(occupied.getsockname()[1])
            config_path = Path(tmp) / "bmp-collector.json"
            config_path.write_text(json.dumps(config))
            argv[0] = str(Path(BINARY).resolve())
            argv = [str(config_path) if value == "/etc/serviceradar/bmp-collector.json" else value for value in argv]
            result = subprocess.run(argv, capture_output=True, text=True, timeout=15, env={**os.environ, "RUST_LOG": "info"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("starting bmp collector", result.stderr)
        self.assertIn("Address already in use", result.stderr)


if __name__ == "__main__":
    unittest.main()
