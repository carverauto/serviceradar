"""Release charts may use only image roots in the matching promotion receipt."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("bundle", ROOT / "scripts/ci/publish-helm-bundle.py")
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class ChartPins(unittest.TestCase):
    def setUp(self):
        self.digest = "sha256:" + "a" * 64
        self.repository = "registry.example.invalid/protected/example-core"
        self.inventory = [("example-core", {"repository": self.repository, "chart_service": "core"})]
        self.receipt = {"artifacts": [{"reference": self.repository + "@" + self.digest}],
                        "published": [{"repository": "example-core", "digest": self.digest, "tags": ["v1.2.3"]}]}

    def test_matching_receipt_pins_temporary_chart_without_changing_release_source(self):
        pins = bundle.image_pins(self.receipt, self.inventory, "v1.2.3")
        with tempfile.TemporaryDirectory() as directory:
            source, staged = Path(directory) / "source", Path(directory) / "staged"
            source.mkdir()
            original = 'image:\n  registry: registry.example.invalid/protected\n  digests: {}\n'
            (source / "values.yaml").write_text(original)
            bundle.stage_chart(source, staged, pins)
            self.assertEqual((source / "values.yaml").read_text(), original)
            line = next(line for line in (staged / "values.yaml").read_text().splitlines() if 'digests:' in line)
            self.assertEqual(json.loads(line.split(': ', 1)[1]), {"core": self.digest})

    def test_wrong_release_or_unverified_root_cannot_be_packaged(self):
        with self.assertRaisesRegex(ValueError, "promoted release image"):
            bundle.image_pins(self.receipt, self.inventory, "v1.2.4")
        self.receipt["artifacts"] = [{"reference": self.repository.replace('protected', 'builds') + "@" + self.digest}]
        with self.assertRaisesRegex(ValueError, "lacks image root"):
            bundle.image_pins(self.receipt, self.inventory, "v1.2.3")

    def test_legacy_signature_roots_do_not_replace_the_published_image(self):
        self.receipt["artifacts"].append({"reference": self.repository + "@sha256:" + "b" * 64})
        self.assertEqual(bundle.image_pins(self.receipt, self.inventory, "v1.2.3"), {"core": self.digest})


if __name__ == "__main__":
    unittest.main()
