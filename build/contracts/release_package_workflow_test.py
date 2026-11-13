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
        # A non-dry run hands the publisher a checksum signer and requires cosign
        # on PATH; never let the host's cosign (or its absence) decide the result.
        cosign = bin_dir / "cosign"
        cosign.write_text("#!/bin/bash\nexit 99\n")
        cosign.chmod(0o755)
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
            "--windows_dir", str(self.root / "windows-release"),
            "--checksums_signer", str(self.repo.resolve() / "scripts/sign-release-checksums.sh"),
            "--draft", "--overwrite_assets=false",
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


class ReleaseAssetWorkflowTest(unittest.TestCase):
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

    def run_asset_verification(self, macos_result, assets):
        step = next(s for s in self.release["jobs"]["publish"]["steps"]
                    if s.get("id") == "release_assets")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "jq").symlink_to(_pinned_jq_binary())
            curl = root / "curl"
            curl.write_text("#!/usr/bin/env python3\nimport os\nprint(os.environ['RELEASE_RESPONSE'])\n")
            curl.chmod(0o755)
            output = root / "output"
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", MACOS_RESULT=macos_result,
                       RELEASE_TAG="v9.8.7", VERSION="9.8.7", GITHUB_OUTPUT=str(output),
                       GITHUB_REPOSITORY="example/release-fixture", GITHUB_TOKEN="invented-test-token",
                       RELEASE_RESPONSE=json.dumps({"id": 123, "tag_name": "v9.8.7", "draft": True,
                                                   "assets": assets}))
            result = subprocess.run(["bash", "-c", step["run"]], env=env, capture_output=True,
                                    text=True, timeout=20)
            return result, output.read_text() if output.exists() else ""

    def test_asset_verification_requires_the_artifacts_selected_for_publication(self):
        step = next(s for s in self.release["jobs"]["publish"]["steps"]
                    if s.get("id") == "release_assets")
        self.assertEqual(step["env"]["MACOS_RESULT"], "${{ needs.macos.result }}")
        installables = (
            "serviceradar-agent_9.8.7_amd64.deb", "serviceradar-agent_9.8.7_arm64.deb",
            "serviceradar-agent_9.8.7_linux_amd64.tar.gz",
            "serviceradar-agent_9.8.7_linux_arm64.tar.gz",
            "serviceradar-agent-9.8.7-1.x86_64.rpm", "serviceradar-agent-9.8.7-1.aarch64.rpm",
        )
        common = [
            {"name": name, "size": 100} for name in (
                *installables,
                "serviceradar-agent-release-manifest.json", "serviceradar-agent-release-manifest.sig",
                "SHA256SUMS", "SHA256SUMS.sigstore.json",
                *(f"{name}.sha256" for name in installables),
            )
        ]
        installer = {"name": "serviceradar-agent_9.8.7_darwin_arm64.pkg", "size": 100}
        installer_sum = {"name": "serviceradar-agent_9.8.7_darwin_arm64.pkg.sha256", "size": 100}
        provenance = {"name": "serviceradar-agent_9.8.7_darwin_arm64.provenance.json", "size": 100}
        missing = "Missing or duplicate required release asset"
        unchecked = "Release assets published without a .sha256 sidecar"
        without = lambda name: [a for a in common if a["name"] != name]
        cases = [
            (status, common, None) for status in ("failure", "cancelled", "skipped")
        ] + [
            ("success", common + [installer, installer_sum, provenance], None),
            ("success", common + [installer, provenance], unchecked),
            ("success", common + [installer, installer_sum], missing),
            ("success", common + [provenance], missing),
            ("failure", common[1:], missing),
            ("failure", common + [common[0]], missing),
            ("failure", without("SHA256SUMS"), missing),
            ("failure", without("SHA256SUMS.sigstore.json"), missing),
            ("failure", without("serviceradar-agent_9.8.7_amd64.deb.sha256"), unchecked),
        ]
        for status, assets, rejection in cases:
            with self.subTest(status=status, assets=[a["name"] for a in assets]):
                result, output = self.run_asset_verification(status, assets)
                if rejection is None:
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(output, "release_id=123\n")
                else:
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn(rejection, result.stderr)
                    self.assertEqual(output, "")



class ImageSecurityScanStepTest(unittest.TestCase):
    """Run the image scan step against fake scanners on a host with no docker daemon."""

    REPOSITORIES = ("registry.example.test/sr/alpha", "registry.example.test/sr/beta")

    @classmethod
    def setUpClass(cls):
        workflow = yaml.load((ROOT / ".github/workflows/image-security.yml").read_text(), Loader=yaml.BaseLoader)
        steps = workflow["jobs"]["image-security"]["steps"]
        cls.step = next(s for s in steps if s["name"] == "Generate image SBOMs and OSV reports")

    def run_scan(self, osv_exit_by_image):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir, work, runner_temp = root / "bin", root / "work", root / "runner-temp"
            for path in (bin_dir, work / "scripts", runner_temp):
                path.mkdir(parents=True)
            fakes = {
                "list-publishable-oci-repositories.sh": "printf '%s\\n' " + " ".join(self.REPOSITORIES),
                "syft": "exit 0",
                # Like skopeo: write the archive named by the docker-archive destination.
                "skopeo": 'dest="${@: -1}"; dest="${dest#docker-archive:}"; : > "${dest%%:*}"',
                # Like osv-scanner: a registry reference needs dockerd, which this host
                # lacks (127); an archive is scanned and reports the image's result.
                "osv-scanner": textwrap.dedent("""\
                    echo "$*" >> "${OSV_CALLS}"
                    archive=""; out=""
                    while [[ $# -gt 0 ]]; do
                      case "$1" in --archive) archive="$2"; shift ;; --output-file) out="$2"; shift ;; esac
                      shift
                    done
                    [[ -n "${archive}" && -f "${archive}" ]] || exit 127
                    echo '{"results":[]}' > "${out}"
                    name="$(basename "${archive}" .tar)"
                    exit "$(python3 -c 'import json,os,sys; print(json.loads(os.environ["OSV_EXITS"])[sys.argv[1]])' "${name}")"
                """),
            }
            for name, body in fakes.items():
                target = work / "scripts" / name if name.endswith(".sh") else bin_dir / name
                target.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body + "\n")
                target.chmod(0o755)
            github_env, calls = root / "github_env", root / "osv_calls"
            github_env.touch()
            calls.touch()
            env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", RELEASE_TAG="v9.8.7",
                       RUNNER_TEMP=str(runner_temp), GITHUB_ENV=str(github_env), OSV_CALLS=str(calls),
                       OSV_EXITS=json.dumps(osv_exit_by_image))
            result = subprocess.run(["bash", "-c", self.step["run"]], cwd=work, env=env,
                                    capture_output=True, text=True, timeout=20)
            return result, github_env.read_text(), calls.read_text().splitlines()

    def test_scans_archives_and_reports_findings_without_a_docker_daemon(self):
        for exits, reported in (({"alpha": 0, "beta": 0}, "OSV_EXIT=0\n"),
                                ({"alpha": 1, "beta": 0}, "OSV_EXIT=1\n")):
            with self.subTest(exits=exits):
                result, github_env, calls = self.run_scan(exits)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(len(calls), 2)
                self.assertEqual(github_env, reported)

    def test_scanner_error_fails_the_scan_instead_of_counting_as_findings(self):
        result, github_env, _ = self.run_scan({"alpha": 0, "beta": 127})
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("OSV scan failed for registry.example.test/sr/beta:v9.8.7", result.stderr)
        self.assertNotIn("OSV_EXIT", github_env)


if __name__ == "__main__":
    unittest.main()
