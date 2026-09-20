"""AGE stays in the CNPG image for this change (OpenSpec 8.5).

The contract pinned here is the build-graph edge Bazel reads out of
``cnpg_image.bzl``: the published ``cnpg_image_amd64`` must carry the layer that
compiles AGE. Bazel cannot be the consumer from inside a py_test -- the AGE
layer is ``target_compatible_with`` Linux and compiles on RBE -- so the file is
parsed into a rule model and the edge is asserted on that model.

Text matching is what this replaced, and it failed open: the previous guard
asserted four substrings anywhere in the file, and every one of them survived
deleting ``:age_extension_layer`` from the image's ``tars``. Two lived only in
prose (the module docstring and a comment), and the other two lived on the
genrule, which stays in the file as an orphan once nothing consumes it.
"""

import ast
import unittest
from pathlib import Path

CNPG_BZL = Path(__file__).resolve().parent / "cnpg_image.bzl"

IMAGE_RULE = "cnpg_image_amd64"
AGE_LAYER = "age_extension_layer"
AGE_SOURCE_TREE = "//database/age:source_tree"


def _literal(node):
    """Value of a literal Starlark node, or None when it is not a literal."""
    try:
        return ast.literal_eval(node)
    except (ValueError, TypeError, SyntaxError):
        return None


def _rule_model(path):
    """Parse a .bzl file into {(rule_kind, name): {attr: literal_value}}.

    Only call expressions carrying a literal `name` are modelled, which is
    every rule instantiation. A comment or a docstring produces no node here,
    so it cannot satisfy an assertion about a rule.
    """
    tree = ast.parse(path.read_text(), filename=str(path))
    rules = {}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        if isinstance(func, ast.Attribute):
            kind = func.attr  # native.genrule -> "genrule"
        elif isinstance(func, ast.Name):
            kind = func.id  # oci_image -> "oci_image"
        else:
            continue
        attrs = {kw.arg: _literal(kw.value) for kw in node.keywords if kw.arg}
        name = attrs.get("name")
        if isinstance(name, str):
            rules[(kind, name)] = attrs
    return rules


class CnpgAgeExtensionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rules = _rule_model(CNPG_BZL)

    def test_cnpg_image_layers_include_the_age_extension_layer(self):
        image = self.rules.get(("oci_image", IMAGE_RULE))
        self.assertIsNotNone(
            image,
            "no oci_image named {!r} in {}".format(IMAGE_RULE, CNPG_BZL.name),
        )

        tars = image.get("tars")
        self.assertIsNotNone(
            tars, "oci_image {!r} declares no `tars`".format(IMAGE_RULE)
        )
        self.assertIn(
            ":{}".format(AGE_LAYER),
            tars,
            "oci_image {!r} does not ship AGE".format(IMAGE_RULE),
        )

    def test_age_extension_layer_builds_from_the_age_source_tree(self):
        """The layer the image ships must be the one that compiles AGE."""
        layer = self.rules.get(("genrule", AGE_LAYER))
        self.assertIsNotNone(
            layer,
            "no genrule named {!r} in {}".format(AGE_LAYER, CNPG_BZL.name),
        )
        self.assertIn(AGE_SOURCE_TREE, layer.get("srcs") or [])


if __name__ == "__main__":
    unittest.main()
