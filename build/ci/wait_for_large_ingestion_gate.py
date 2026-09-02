"""CLI composition root for LargeIngestionGate release qualification."""

from __future__ import annotations

import argparse
import math
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Mapping, Sequence, TextIO

from build.ci.large_ingestion_gate import (
    GhStatusClient,
    GitRepository,
    PolicyError,
    TARGET_URL_PREFIX,
    wait_for_gate,
)


FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise PolicyError(f"invalid arguments: {message}")


class SystemClock:
    @staticmethod
    def monotonic():
        return time.monotonic()

    @staticmethod
    def sleep(seconds):
        time.sleep(seconds)


def _parser() -> SafeArgumentParser:
    parser = SafeArgumentParser(add_help=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--base-ref", required=True)
    parser.add_argument("--token-env", required=True)
    parser.add_argument("--timeout-seconds", required=True, type=float)
    parser.add_argument("--poll-seconds", required=True, type=float)
    parser.add_argument("--target-url-prefix", required=True)
    return parser


def _run(
    argv: Sequence[str],
    environment: Mapping[str, str],
    stdout: TextIO,
    runner,
) -> None:
    arguments = _parser().parse_args(list(argv))
    if not REPOSITORY.fullmatch(arguments.repository):
        raise PolicyError("repository must be a safe owner/repo name")
    if not FULL_SHA.fullmatch(arguments.commit):
        raise PolicyError("commit must be a lowercase 40-hex-character SHA")
    if not arguments.base_ref:
        raise PolicyError("base ref must be nonempty")
    if not arguments.token_env:
        raise PolicyError("token environment variable name must be nonempty")
    if (
        not math.isfinite(arguments.timeout_seconds)
        or not math.isfinite(arguments.poll_seconds)
        or arguments.timeout_seconds <= 0
        or arguments.poll_seconds <= 0
    ):
        raise PolicyError("timeout and polling intervals must be finite positive values")
    if arguments.target_url_prefix != TARGET_URL_PREFIX:
        raise PolicyError("target URL prefix must be the fixed BuildBuddy invocation prefix")

    token = environment.get(arguments.token_env, "")
    if not token:
        raise PolicyError("the configured GitHub token variable is unavailable")

    workspace_value = environment.get("BUILD_WORKSPACE_DIRECTORY", "")
    if not workspace_value:
        raise PolicyError("BUILD_WORKSPACE_DIRECTORY is unavailable")
    workspace = Path(workspace_value).resolve()
    if not workspace.is_dir() or not (workspace / ".git").exists():
        raise PolicyError("BUILD_WORKSPACE_DIRECTORY is not a git worktree root")

    git = GitRepository(workspace, runner)
    if git.worktree_root() != workspace:
        raise PolicyError("BUILD_WORKSPACE_DIRECTORY is not the git worktree root")
    child_environment = dict(environment)
    child_environment.pop(arguments.token_env, None)
    child_environment.pop("GITHUB_TOKEN", None)
    child_environment.pop("GH_ENTERPRISE_TOKEN", None)

    result = wait_for_gate(
        git=git,
        status_factory=lambda sha: GhStatusClient(
            repository=arguments.repository,
            commit=sha,
            token=token,
            runner=runner,
            environment=child_environment,
        ),
        clock=SystemClock(),
        release_commit=arguments.commit,
        base_ref=arguments.base_ref,
        timeout_seconds=arguments.timeout_seconds,
        poll_seconds=arguments.poll_seconds,
        target_url_prefix=arguments.target_url_prefix,
    )
    if result.target_url is None:
        print(result.message, file=stdout)
    else:
        print(f"{result.message} {result.target_url}", file=stdout)


def run_cli(
    argv: Sequence[str],
    environment: Mapping[str, str],
    stdout: TextIO,
    stderr: TextIO,
    runner=subprocess.run,
) -> int:
    try:
        _run(argv, environment, stdout, runner)
    except PolicyError as error:
        print(f"ERROR: {error}", file=stderr)
        return 1
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    try:
        return run_cli(
            sys.argv[1:] if argv is None else argv,
            os.environ,
            sys.stdout,
            sys.stderr,
        )
    except PolicyError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
