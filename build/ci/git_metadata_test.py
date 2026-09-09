from pathlib import Path
import subprocess
import unittest

from build.ci.git_metadata import GitMetadata, MetadataError


OID = "1" * 40


def indexed(path, mode="160000", stage="0"):
    return f"{mode} {OID} {stage}\t{path}\0".encode()


def mapping(path="Local Packages/core", url=b"https://example.com/core.git"):
    return b"submodule.core.path\n" + path.encode() + b"\0submodule.core.url\n" + url + b"\0"


class GitMetadataTest(unittest.TestCase):
    def verify(self, index, config=b"", config_status=0, expected=None, diff_status=0):
        root = Path.cwd().resolve()
        calls = []

        def runner(command, **kwargs):
            args = command[3:]
            calls.append(args)
            if args == ["rev-parse", "--show-toplevel"]:
                output, status = str(root).encode() + b"\n", 0
            elif args == ["ls-files", "--stage", "-z", "--full-name"]:
                output, status = index, 0
            elif args[:1] == ["config"]:
                self.assertEqual(args, ["config", "--no-includes", "--null", "--blob", OID,
                                        "--get-regexp", r"^submodule\..*\.(path|url)$"])
                output, status = config, config_status
            elif args[:2] == ["rev-parse", "--verify"]:
                output, status = OID.encode() + b"\n", 0
            elif args[:1] == ["diff-index"]:
                self.assertEqual(args, ["diff-index", "--cached", "--quiet",
                                        "--ignore-submodules=none", expected, "--"])
                output, status = b"", diff_status
            else:
                self.fail("Unexpected Git command")
            return subprocess.CompletedProcess(command, status, output, b"private config detail")

        count = GitMetadata(root, runner).verify(expected)
        return count, calls

    def test_valid_whitespace_mapping_and_source_revision(self):
        count, _ = self.verify(indexed("Local Packages/core") + indexed(".gitmodules", "100644"),
                               mapping(), expected=OID)
        self.assertEqual(count, 1)

    def test_ordinary_package_needs_no_submodule_registration(self):
        count, _ = self.verify(indexed("LocalPackages/core/Package.swift", "100644"))
        self.assertEqual(count, 0)

    def test_registration_without_gitlink_is_valid_git_metadata(self):
        count, _ = self.verify(indexed(".gitmodules", "100644"), mapping())
        self.assertEqual(count, 0)

    def test_invalid_metadata(self):
        index = indexed("Local Packages/core") + indexed(".gitmodules", "100644")
        cases = [
            (indexed("Local Packages/core"), b"", 0),
            (index, b"submodule.core.path\nLocal Packages/core\0", 0),
            (index, mapping(url=b"  "), 0),
            (index, mapping("elsewhere"), 0),
            (index, mapping() + b"submodule.core.path\nLocal Packages/core\0", 0),
            (index, mapping() + mapping().replace(b"submodule.core.", b"submodule.other."), 0),
            (index, mapping() + b"submodule.core.url\nhttps://example.com/other.git\0", 0),
            (index, b"", 3),
            (index, b"", 1),
            (indexed(".gitmodules", "120000"), mapping(), 0),
            (indexed("file", "100644", "2"), b"", 0),
            (indexed("file")[:-1], b"", 0),
        ]
        for data, config, status in cases:
            with self.subTest(index=data, config=config, status=status):
                with self.assertRaises(MetadataError):
                    self.verify(data, config, config_status=status)

    def test_unsafe_paths(self):
        for path in ("../core", "/core", "a//core", "a/./core", "a/.git/core", "C:/core",
                     "a\\core", "-core", "a\ncore"):
            with self.subTest(path=path), self.assertRaises(MetadataError):
                self.verify(indexed(path) + indexed(".gitmodules", "100644"), mapping(path))

    def test_unsafe_submodule_names(self):
        for name in ("", "..", "../core", "core/..", "a/../core",
                     "..\\core", "core\\..", "a\\..\\core", "a/..\\core"):
            with self.subTest(name=name), self.assertRaisesRegex(MetadataError, "Unsafe submodule name"):
                self.verify(indexed("Local Packages/core") + indexed(".gitmodules", "100644"),
                            mapping().replace(b"submodule.core.", f"submodule.{name}.".encode()))

    def test_dotted_submodule_names(self):
        for name in ("core.v2", "core..v2", "...", "group/core.v2"):
            with self.subTest(name=name):
                count, _ = self.verify(
                    indexed("Local Packages/core") + indexed(".gitmodules", "100644"),
                    mapping().replace(b"submodule.core.", f"submodule.{name}.".encode()))
                self.assertEqual(count, 1)

    def test_index_must_match_expected_commit(self):
        with self.assertRaises(MetadataError):
            self.verify(b"", expected=OID, diff_status=1)
        with self.assertRaises(MetadataError):
            self.verify(b"", expected="HEAD")

    def test_missing_git_fails(self):
        def missing(*args, **kwargs):
            raise FileNotFoundError()
        with self.assertRaises(MetadataError):
            GitMetadata(Path.cwd(), missing).verify()

    def test_root_mismatch_fails(self):
        def other_root(command, **kwargs):
            return subprocess.CompletedProcess(command, 0, b"/different-root\n", b"")
        with self.assertRaises(MetadataError):
            GitMetadata(Path.cwd(), other_root).verify()

    def test_errors_do_not_disclose_config(self):
        with self.assertRaisesRegex(MetadataError, "^Git metadata command failed$"):
            self.verify(indexed(".gitmodules", "100644"), config_status=3)


if __name__ == "__main__":
    unittest.main()
