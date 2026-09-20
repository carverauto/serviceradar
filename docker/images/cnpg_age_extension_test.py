"""AGE stays in the CNPG image for this change (OpenSpec 8.5)."""

from pathlib import Path
import unittest

CNPG_BZL = Path(__file__).resolve().parent / "cnpg_image.bzl"


class CnpgAgeExtensionTest(unittest.TestCase):
    def test_age_extension_layer_is_still_declared(self):
        text = CNPG_BZL.read_text()
        self.assertIn("age_extension_layer", text)
        self.assertIn("//database/age:source_tree", text)
        self.assertIn("shared_preload_libraries", text)
        self.assertIn("age.so", text)


if __name__ == "__main__":
    unittest.main()
