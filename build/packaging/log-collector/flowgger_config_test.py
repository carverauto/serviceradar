"""Protect the RFC3164 timezone default in the shipped collector configuration."""

from pathlib import Path
import sys
import tomllib
import unittest


CONFIG_PATH = Path(sys.argv.pop(1))


class FlowggerConfigTest(unittest.TestCase):
    def test_rfc3164_uses_utc_by_default(self):
        with CONFIG_PATH.open("rb") as config_file:
            config = tomllib.load(config_file)

        self.assertEqual(config["input"]["rfc3164_timezone"], "UTC")


if __name__ == "__main__":
    unittest.main()
