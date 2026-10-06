"""Execute the release package step against synthetic Git trees; never publish."""

import os
import json
import platform
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

import yaml


ROOT = (
    Path(os.environ["TEST_SRCDIR"]) / os.environ["TEST_WORKSPACE"]
    if "TEST_SRCDIR" in os.environ
    else Path(__file__).resolve().parents[2]
)


class ReleasePackageWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Extract executable YAML block content, not assertions about shell spelling.
        lines = (ROOT / ".github/workflows/release.yml").read_text().splitlines()
        start = lines.index("      - name: Publish release packages and agent manifest assets")
        run = lines.index("        run: |", start) + 1
        end = run
        while end < len(lines) and (not lines[end].strip() or lines[end].startswith("          ")):
            end += 1
        cls.script = textwrap.dedent("\n".join(lines[run:end]))
        if not cls.script.strip():
            raise ValueError("package publication step has no executable body")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git_env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.git("init", "-q")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release-test@example.invalid")
        self.file = self.repo / "VERSION"
        self.file.write_text("9.8.7\n")
        self.git("add", "VERSION")
        self.git("commit", "-qm", "synthetic release")
        self.commit = self.git("rev-parse", "HEAD").strip()
        self.git("tag", "v9.8.7")
        self.record = self.root / "bazel-args"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        bazel = bin_dir / "bazel"
        bazel.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$BAZEL_RECORD"\n')
        bazel.chmod(0o755)
        self.env = dict(
            self.git_env,
            PATH=f"{bin_dir}:{os.environ['PATH']}",
            BAZEL_RECORD=str(self.record),
            RELEASE_TAG="v9.8.7",
            VERSION="9.8.7",
            SOURCE_TAG="v9.8.7",
            SOURCE_COMMIT=self.commit,
            RELEASE_COMMIT=self.commit,
            MACOS_RESULT="success",
            RUNNER_TEMP=str(self.root),
            NOTES_FILE="",
            DRY_RUN="false",
            APPEND_NOTES="false",
            PRERELEASE="false",
            DRAFT="false",
            OVERWRITE_ASSETS="false",
            BAZEL_BUILD_FLAGS="-c opt --config=ci",
        )

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, env=self.git_env, text=True)

    def run_step(self):
        return subprocess.run(
            ["bash", "-c", self.script], cwd=self.repo, env=self.env,
            capture_output=True, text=True, timeout=20,
        )

    def assert_rejected(self, message):
        result = self.run_step()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)
        self.assertFalse(self.record.exists(), "publisher ran despite invalid release source")

    def test_clean_tag_tree_passes_pinned_commit_and_platform_artifacts(self):
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.record.read_text().splitlines(), [
            "run", "-c", "opt", "--config=ci", "//build/release:publish_packages", "--",
            "--tag", "v9.8.7", "--commit", self.commit,
            "--macos_pkg", str(self.root / "macos-release/serviceradar-agent_9.8.7_darwin_arm64.pkg"),
            "--macos_provenance", str(self.root / "macos-release/serviceradar-agent_9.8.7_darwin_arm64.provenance.json"),
            "--windows_dir", str(self.root / "windows-release"), "--draft", "--overwrite_assets=false",
        ])
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), self.commit)

    def test_rejects_empty_release_tag(self):
        self.env["RELEASE_TAG"] = ""
        self.assert_rejected("Release tag is empty")

    def test_rejects_platform_source_mismatch(self):
        for key, value in (("SOURCE_TAG", "v9.8.6"), ("SOURCE_COMMIT", "0" * 40)):
            with self.subTest(key=key):
                original = self.env[key]
                self.env[key] = value
                self.assert_rejected("must come from the same release commit")
                self.env[key] = original

    def test_rejects_newer_workflow_commit_even_with_same_version(self):
        self.git("commit", "--allow-empty", "-qm", "synthetic workflow update")
        self.assert_rejected("refusing mixed-source artifacts")

    def test_rejects_modified_tracked_content(self):
        self.file.write_text("9.8.8\n")
        self.assert_rejected("refusing mixed-source artifacts")

    def test_rejects_staged_content_change(self):
        self.file.write_text("9.8.8\n")
        self.git("add", "VERSION")
        self.assert_rejected("refusing mixed-source artifacts")

    def test_stat_only_change_does_not_block_publication(self):
        stat = self.file.stat()
        os.utime(self.file, ns=(stat.st_atime_ns, stat.st_mtime_ns + 2_000_000_000))
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.record.exists())


def _pinned_jq_binary():
    """Locate the pinned jq for this host inside the test runfiles.

    Mirrors scripts/test-external-wasm-plugin-release-workflow.sh: match the
    arch-specific repository by substring because Bzlmod runfiles use the
    canonical repository name (+http_file+jq_linux_<arch>), not the apparent
    one. Fail explicitly when the declared tool is unavailable: no host
    fallback, no skips.
    """
    machine = platform.machine().lower()
    if machine in ("x86_64", "amd64"):
        repository = "jq_linux_amd64"
    elif machine in ("aarch64", "arm64"):
        repository = "jq_linux_arm64"
    else:
        raise FileNotFoundError(f"no pinned jq for machine {machine!r}")
    srcdir = Path(os.environ["TEST_SRCDIR"])
    for dirpath, _dirnames, filenames in os.walk(srcdir, followlinks=True):
        if repository in dirpath and "downloaded" in filenames:
            candidate = Path(dirpath) / "downloaded"
            if os.access(candidate, os.X_OK):
                return candidate
    raise FileNotFoundError("declared jq runfile is unavailable")


class ReleaseImageSecurityWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # BaseLoader preserves GitHub's `on` key rather than treating it as a
        # YAML 1.1 boolean. These mappings are the Actions scheduling contract.
        cls.release = yaml.load((ROOT / ".github/workflows/release.yml").read_text(), Loader=yaml.BaseLoader)
        cls.scan = yaml.load((ROOT / ".github/workflows/image-security.yml").read_text(), Loader=yaml.BaseLoader)

    def test_scan_cannot_start_before_publish_and_finalization_waits_for_dispatch(self):
        self.assertEqual(set(self.scan["on"]), {"workflow_dispatch"})
        jobs = self.release["jobs"]
        dispatcher = jobs["image-security-dispatch"]
        self.assertEqual(dispatcher["needs"], "publish")
        self.assertEqual(set(jobs["finalize"]["needs"]), {"publish", "image-security-dispatch"})
        self.assertEqual(dispatcher["permissions"], {"contents": "write", "actions": "write"})
        self.assertEqual(self.scan["jobs"]["image-security"]["steps"][0]["with"]["ref"], "${{ inputs.tag }}")

    def run_dispatch(self, *, assets=(), release_tag="v9.8.7", draft=True, fail_post=False):
        step = next(s for s in self.release["jobs"]["image-security-dispatch"]["steps"] if "run" in s)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            record = root / "requests.jsonl"
            (root / "jq").symlink_to(_pinned_jq_binary())
            fake_gh = root / "gh"
            fake_gh.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "with open(os.environ['REQUESTS'], 'a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                "if '--method' in sys.argv: sys.exit(23 if os.environ['FAIL_POST'] == 'true' else 0)\n"
                "print(os.environ['RELEASE_RESPONSE'])\n"
            )
            fake_gh.chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", REQUESTS=str(record),
                       FAIL_POST=str(fail_post).lower(), RELEASE_TAG="v9.8.7", RELEASE_ID="123",
                       GITHUB_REPOSITORY="example/release-fixture", GH_TOKEN="invented-test-token",
                       RELEASE_RESPONSE=json.dumps({"id": 123, "tag_name": release_tag, "draft": draft,
                                                   "assets": list(assets)}))
            result = subprocess.run(["bash", "-c", step["run"]], env=env, capture_output=True,
                                    text=True, timeout=20)
            requests = [json.loads(line) for line in record.read_text().splitlines()]
            return result, requests

    def test_missing_bundle_dispatches_same_tag_after_publish(self):
        result, requests = self.run_dispatch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests, [
            ["api", "repos/example/release-fixture/releases/123"],
            ["api", "--method", "POST", "repos/example/release-fixture/actions/workflows/image-security.yml/dispatches",
             "-f", "ref=v9.8.7", "-f", "inputs[tag]=v9.8.7"],
        ])

    def test_retry_preserves_existing_bundle_and_does_not_dispatch_again(self):
        bundle = {"name": "serviceradar-image-security-v9.8.7.tar.gz", "size": 100}
        result, requests = self.run_dispatch(assets=[bundle])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(requests), 1)

    def test_dispatch_fails_closed_for_wrong_release_or_api_failure(self):
        for options in ({"release_tag": "v9.8.6"}, {"draft": False}, {"fail_post": True}):
            with self.subTest(options=options):
                result, requests = self.run_dispatch(**options)
                self.assertNotEqual(result.returncode, 0)
                if not options.get("fail_post"):
                    self.assertEqual(len(requests), 1)


if __name__ == "__main__":
    unittest.main()
