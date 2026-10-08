"""Collisions that exist only after merging with latest staging must fail."""

import hashlib
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import build.migration_collision.migration_collision as migration_collision_module
from build.migration_collision.migration_collision import (
    DEFAULT_DIRECTORY,
    check_merge,
    find_collisions,
    merged_migration_files,
)

SCRIPT = Path(migration_collision_module.__file__)
DIRECTORY = DEFAULT_DIRECTORY


def source(module: str, marker: str) -> bytes:
    return (
        f"defmodule ServiceRadar.Repo.Migrations.{module} do\n"
        f"  use Ecto.Migration\n"
        f"  def change, do: :{marker}\n"
        f"end\n"
    ).encode()


class FindCollisionsTest(unittest.TestCase):
    def test_unique_files_pass(self):
        files = {
            "migrations/100_create_widgets.exs": source("CreateWidgets", "create"),
            "migrations/200_add_widget_notes.exs": source("AddWidgetNotes", "notes"),
        }
        self.assertEqual(find_collisions(files), [])

    def test_duplicate_version_names_every_file(self):
        notes = "migrations/200_add_widget_notes.exs"
        flags = "migrations/200_add_widget_flags.exs"
        messages = find_collisions(
            {
                notes: source("AddWidgetNotes", "notes"),
                flags: source("AddWidgetFlags", "flags"),
            }
        )
        self.assertEqual(messages, [f"duplicate migration version 200: {flags}, {notes}"])

    def test_duplicate_module_with_different_bytes_names_every_file(self):
        first = "migrations/300_add_widget_notes.exs"
        second = "migrations/301_add_widget_notes_again.exs"
        messages = find_collisions(
            {
                first: source("AddWidgetNotes", "notes"),
                second: source("AddWidgetNotes", "notes-again"),
            }
        )
        module = "ServiceRadar.Repo.Migrations.AddWidgetNotes"
        self.assertEqual(messages, [f"duplicate migration module {module}: {first}, {second}"])

    def test_byte_identical_files_report_module_and_contents(self):
        body = source("AddWidgetNotes", "notes")
        first = "migrations/400_add_widget_notes.exs"
        second = "migrations/401_add_widget_notes_copy.exs"
        messages = find_collisions({first: body, second: body})
        digest = hashlib.sha256(body).hexdigest()
        module = "ServiceRadar.Repo.Migrations.AddWidgetNotes"
        self.assertEqual(
            messages,
            [
                f"duplicate migration contents {digest}: {first}, {second}",
                f"duplicate migration module {module}: {first}, {second}",
            ],
        )

    def test_three_files_sharing_a_version_are_one_collision(self):
        paths = [
            "migrations/200_add_widget_flags.exs",
            "migrations/200_add_widget_notes.exs",
            "migrations/200_add_widget_tags.exs",
        ]
        files = {
            paths[0]: source("AddWidgetFlags", "flags"),
            paths[1]: source("AddWidgetNotes", "notes"),
            paths[2]: source("AddWidgetTags", "tags"),
        }
        self.assertEqual(
            find_collisions(files),
            ["duplicate migration version 200: " + ", ".join(paths)],
        )

    def test_unreadable_migration_fails_closed(self):
        cases = {
            "malformed": (
                {"migrations/not_a_migration.exs": source("CreateWidgets", "create")},
                "malformed migration path: migrations/not_a_migration.exs",
            ),
            "empty": (
                {"migrations/100_create_widgets.exs": b" \n"},
                "empty migration: migrations/100_create_widgets.exs",
            ),
            "missing module": (
                {"migrations/100_create_widgets.exs": b"use Ecto.Migration\n"},
                "migration module missing: migrations/100_create_widgets.exs",
            ),
            "two modules": (
                {
                    "migrations/100_create_widgets.exs": source("CreateWidgets", "create")
                    + source("AddWidgetNotes", "notes")
                },
                "migration module declares multiple modules: migrations/100_create_widgets.exs",
            ),
            "bigint": (
                {"migrations/" + ("9" * 20) + "_too_big.exs": source("TooBig", "big")},
                "migration version outside positive bigint: migrations/" + ("9" * 20) + "_too_big.exs",
            ),
        }
        for name, (files, message) in cases.items():
            with self.subTest(name=name):
                self.assertEqual(find_collisions(files), [message])


class MergeCollisionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo"
        self.repo.mkdir()
        self.git_env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.git("init", "-q", "-b", "base")
        self.git("config", "user.name", "Migration Collision Test")
        self.git("config", "user.email", "migration-collision@example.invalid")
        self.migrations = self.repo / DIRECTORY

    def git(self, *args: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(self.repo), *args],
            capture_output=True,
            text=True,
            env=self.git_env,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def commit(self, branch: str, files: dict[str, bytes], parent: str | None = None) -> str:
        if parent is None:
            self.git("checkout", "-q", "-B", branch)
        else:
            self.git("checkout", "-q", "-B", branch, parent)
        for name, body in files.items():
            path = self.migrations / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(body)
            self.git("add", "--", f"{DIRECTORY}/{name}")
        self.git("commit", "-qm", branch)
        return self.git("rev-parse", "HEAD")

    def remove(self, branch: str, name: str, parent: str) -> str:
        self.git("checkout", "-q", "-B", branch, parent)
        self.git("rm", "-q", f"{DIRECTORY}/{name}")
        self.git("commit", "-qm", f"drop {name}")
        return self.git("rev-parse", "HEAD")

    def test_branch_clean_against_its_base_fails_against_staging_that_took_the_version(self):
        base = self.commit("base", {"100_create_widgets.exs": source("CreateWidgets", "create")})
        staging = self.commit(
            "staging",
            {"200_add_widget_notes.exs": source("AddWidgetNotes", "notes")},
            parent=base,
        )
        feature = self.commit(
            "feature",
            {"200_add_widget_flags.exs": source("AddWidgetFlags", "flags")},
            parent=base,
        )

        head_files, head_conflicts = merged_migration_files(self.repo, feature, feature)
        self.assertEqual(head_conflicts, [])
        self.assertEqual(find_collisions(head_files), [])

        against_base = check_merge(self.repo, base, feature)
        self.assertEqual(against_base, [])

        against_staging = check_merge(self.repo, staging, feature)
        notes = f"{DIRECTORY}/200_add_widget_notes.exs"
        flags = f"{DIRECTORY}/200_add_widget_flags.exs"
        self.assertEqual(against_staging, [f"duplicate migration version 200: {flags}, {notes}"])

        stale = self.run_cli(base, feature)
        self.assertEqual(stale.returncode, 0, stale.stderr)
        current = self.run_cli(staging, feature)
        self.assertEqual(current.returncode, 1, current.stdout + current.stderr)
        self.assertIn(notes, current.stderr)
        self.assertIn(flags, current.stderr)
        self.assertIn("duplicate migration version 200", current.stderr)

    def test_comparing_a_clean_commit_to_itself_passes(self):
        commit = self.commit("base", {"100_create_widgets.exs": source("CreateWidgets", "create")})
        self.assertEqual(check_merge(self.repo, commit, commit), [])
        result = self.run_cli(commit, commit)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_comparing_a_commit_that_already_contains_the_duplicate_to_itself_fails(self):
        commit = self.commit(
            "base",
            {
                "200_add_widget_notes.exs": source("AddWidgetNotes", "notes"),
                "200_add_widget_flags.exs": source("AddWidgetFlags", "flags"),
            },
        )
        messages = check_merge(self.repo, commit, commit)
        self.assertEqual(len(messages), 1)
        self.assertIn("duplicate migration version 200", messages[0])
        self.assertIn("200_add_widget_notes.exs", messages[0])
        self.assertIn("200_add_widget_flags.exs", messages[0])

    def test_deleting_a_migration_removes_it_from_the_merge(self):
        base = self.commit(
            "base",
            {
                "100_create_widgets.exs": source("CreateWidgets", "create"),
                "200_add_widget_notes.exs": source("AddWidgetNotes", "notes"),
            },
        )
        feature = self.remove("feature", "200_add_widget_notes.exs", parent=base)
        files, conflicts = merged_migration_files(self.repo, base, feature)
        self.assertEqual(conflicts, [])
        self.assertEqual(sorted(Path(path).name for path in files), ["100_create_widgets.exs"])
        self.assertEqual(check_merge(self.repo, base, feature), [])

    def test_merge_conflict_inside_the_migrations_directory_fails(self):
        base = self.commit("base", {"100_create_widgets.exs": source("CreateWidgets", "create")})
        left = self.commit(
            "left",
            {"100_create_widgets.exs": source("CreateWidgets", "left")},
            parent=base,
        )
        right = self.commit(
            "right",
            {"100_create_widgets.exs": source("CreateWidgets", "right")},
            parent=base,
        )
        messages = check_merge(self.repo, left, right)
        path = f"{DIRECTORY}/100_create_widgets.exs"
        self.assertIn(f"migration merge conflict: {path}", messages)

    def run_cli(self, base: str, head: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--repo",
                str(self.repo),
                "--base",
                base,
                "--head",
                head,
            ],
            capture_output=True,
            text=True,
            check=False,
        )


if __name__ == "__main__":
    unittest.main()
