"""Contract tests for OCI push target declarations."""

from pathlib import Path
import re
import unittest


class PushTargetsTest(unittest.TestCase):
    def setUp(self):
        self.push_calls = []
        inventory = [
            {
                "image": "alpha_image_amd64",
                "repository": "registry.example/alpha",
            },
            {
                "image": "bravo_image_amd64",
                "push_image": "bravo_image_multiarch",
                "repository": "registry.example/bravo",
            },
        ]

        namespace = {
            "PUBLISHABLE_IMAGES": inventory,
            "command": lambda **_kwargs: None,
            "expand_template": lambda **_kwargs: None,
            "immutable_push_tags": lambda **_kwargs: None,
            "load": lambda *_args: None,
            "multirun": lambda **_kwargs: None,
            "oci_push": lambda **kwargs: self.push_calls.append(kwargs),
        }
        source = Path(__file__).with_name("push_targets.bzl").read_text()
        exec(compile(source, "push_targets.bzl", "exec"), namespace)
        namespace["declare_oci_push_targets"]()

    def test_commit_only_targets_use_only_the_stamped_commit_tag(self):
        commit_only_calls = {
            call["name"]: call
            for call in self.push_calls
            if call["name"].endswith("_push_commit_only")
        }

        self.assertEqual(
            commit_only_calls,
            {
                "alpha_image_amd64_push_commit_only": {
                    "name": "alpha_image_amd64_push_commit_only",
                    "image": ":alpha_image_amd64",
                    "repository": "registry.example/alpha",
                    "remote_tags": ":alpha_image_amd64_commit_tag",
                    "visibility": ["//visibility:public"],
                },
                "bravo_image_amd64_push_commit_only": {
                    "name": "bravo_image_amd64_push_commit_only",
                    "image": ":bravo_image_multiarch",
                    "repository": "registry.example/bravo",
                    "remote_tags": ":bravo_image_amd64_commit_tag",
                    "visibility": ["//visibility:public"],
                },
            },
        )

    def test_bulk_push_target_pattern_excludes_commit_only_targets(self):
        commit_only_names = [
            call["name"]
            for call in self.push_calls
            if call["name"].endswith("_push_commit_only")
        ]

        self.assertEqual(len(commit_only_names), 2)
        for name in commit_only_names:
            self.assertIsNone(re.fullmatch(r".*_push", name))


if __name__ == "__main__":
    unittest.main()
