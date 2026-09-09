import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from build.ci.git_metadata import GitMetadata, MetadataError


CLEANUP = ('git config --local --name-only --get-regexp core.sshCommand && '
           'git config --local --unset-all core.sshCommand || :')


class CheckoutRegression(unittest.TestCase):
    def setUp(self):
        workspace = os.environ.get("BUILD_WORKSPACE_DIRECTORY", os.getcwd())
        self.temporary = tempfile.TemporaryDirectory(prefix="git-checkout-", dir=workspace)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_TERMINAL_PROMPT="0")
        self.child = self.root / "child"
        self.repo = self.root / "parent"
        for directory in (self.child, self.repo):
            directory.mkdir()
            self.git(directory, "init", "--quiet")
            (directory / "ordinary.txt").write_text("synthetic checkout content\n")
            self.git(directory, "add", "ordinary.txt")
            self.commit(directory)
        self.oid = self.git(self.child, "rev-parse", "HEAD").stdout.decode().strip()
        self.path = "Local Packages/core"
        self.git(self.repo, "update-index", "--add", "--cacheinfo",
                 f"160000,{self.oid},{self.path}")
        self.modules = self.repo / ".gitmodules"
        self.valid = '[submodule "core"]\n path = "Local Packages/core"\n url = ../child\n'

    def git(self, directory, *args, check=True):
        return subprocess.run(["git", "-C", str(directory), *args], env=self.env,
                              check=check, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def commit(self, directory):
        self.git(directory, "-c", "user.name=Synthetic Checkout", "-c",
                 "user.email=checkout@example.com", "-c", "commit.gpgsign=false",
                 "commit", "--quiet", "-m", "Synthetic checkout")

    def stage_modules(self, content):
        self.modules.write_text(content)
        self.git(self.repo, "add", ".gitmodules")

    def validator(self, directory=None):
        def runner(command, **kwargs):
            return subprocess.run(command, env=self.env, **kwargs)
        return GitMetadata(directory or self.repo, runner)

    def cleanup(self):
        return self.git(self.repo, "submodule", "foreach", "--recursive", CLEANUP, check=False)

    def test_valid_recursive_cleanup_and_sparse_checkout(self):
        self.stage_modules(self.valid)
        self.commit(self.repo)
        sha = self.git(self.repo, "rev-parse", "HEAD").stdout.decode().strip()
        self.assertEqual(self.validator().verify(sha), 1)
        self.git(self.repo, "-c", "protocol.file.allow=always", "submodule", "update", "--init")
        self.git(self.repo / self.path, "config", "--local", "core.sshCommand", "synthetic-command")
        self.assertEqual(self.cleanup().returncode, 0)
        self.assertEqual(self.git(self.repo / self.path, "config", "--local", "--get",
                                  "core.sshCommand", check=False).returncode, 1)
        self.git(self.repo, "submodule", "deinit", "--all", "--force")
        self.git(self.repo, "sparse-checkout", "set", "--no-cone", "/ordinary.txt")
        self.assertFalse(self.modules.exists())
        self.assertEqual(self.validator().verify(sha), 1)
        self.assertEqual(self.cleanup().returncode, 0)

    def test_orphan_checkout_cleanup(self):
        with self.assertRaises(MetadataError):
            self.validator().verify()
        result = self.cleanup()
        print(f"Orphan foreach cleanup exit status: {result.returncode}; validator rejected it", flush=True)

    def test_missing_url(self):
        self.stage_modules('[submodule "core"]\n path = "Local Packages/core"\n')
        with self.assertRaises(MetadataError):
            self.validator().verify()

    def test_mismatched_mapping(self):
        self.stage_modules(self.valid.replace("Local Packages/core", "Other Packages/core"))
        with self.assertRaises(MetadataError):
            self.validator().verify()

    def test_duplicate_mapping(self):
        self.stage_modules(self.valid + self.valid.replace('"core"', '"other"'))
        with self.assertRaises(MetadataError):
            self.validator().verify()

    def test_unstaged_repair_does_not_hide_index(self):
        self.stage_modules('[submodule "core"]\n path = "Local Packages/core"\n')
        self.modules.write_text(self.valid)
        with self.assertRaises(MetadataError):
            self.validator().verify()

    def test_malformed_config_fails(self):
        self.stage_modules('[submodule "core"\n')
        with self.assertRaises(MetadataError):
            self.validator().verify()

    def test_unresolved_index_fails(self):
        self.git(self.repo, "update-index", "--force-remove", "ordinary.txt")
        blob = self.git(self.repo, "rev-parse", "HEAD:ordinary.txt").stdout.decode().strip()
        subprocess.run(["git", "-C", str(self.repo), "update-index", "--index-info"],
                       input=f"100644 {blob} 2\tordinary.txt\n".encode(), env=self.env, check=True)
        with self.assertRaises(MetadataError):
            self.validator().verify()

    def test_expected_revision_rejects_changed_index(self):
        self.stage_modules(self.valid)
        self.commit(self.repo)
        sha = self.git(self.repo, "rev-parse", "HEAD").stdout.decode().strip()
        (self.repo / "ordinary.txt").write_text("different synthetic content\n")
        self.git(self.repo, "add", "ordinary.txt")
        with self.assertRaises(MetadataError):
            self.validator().verify(sha)

    def test_worktree_root(self):
        self.stage_modules(self.valid)
        self.commit(self.repo)
        worktree = self.root / "worktree"
        self.git(self.repo, "worktree", "add", "--detach", str(worktree), "HEAD")
        self.assertTrue((worktree / ".git").is_file())
        self.assertEqual(self.validator(worktree).verify(), 1)
        with self.assertRaises(MetadataError):
            self.validator(worktree / "Local Packages").verify()


if __name__ == "__main__":
    unittest.main()
