"""Release qualification policy for the LargeIngestionGate status."""

from __future__ import annotations

import ast
import io
import json
import math
import re
import subprocess
import tokenize
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Mapping, Protocol, Sequence
from urllib.parse import urlparse


MARKER_PATH = "build/ci/large_ingestion_gate_contract.v1"
MARKER_BYTES = b"large-ingestion-gate-contract-v1\n"
TARGET_PATH = "elixir/serviceradar_core/BUILD.bazel"
TARGET_TEXT = b'name = "large_ingestion_release_gate"'
ACTION_PATH = "buildbuddy.yaml"
ACTION_TEXT = b'name: "LargeIngestionGate"'
STATUS_CONTEXT = "LargeIngestionGate"
BUILDBUDDY_HOST = "carverauto.buildbuddy.io"
INVOCATION_PATH = "/invocation/"
TARGET_URL_PREFIX = "https://carverauto.buildbuddy.io/invocation/"
HISTORICAL_NOT_APPLICABLE = "HISTORICAL_NOT_APPLICABLE"
FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
FIRST_PARENT_WALK_LIMIT = 256


def _starlark_tokens(source: bytes) -> tuple[tokenize.TokenInfo, ...] | None:
    if not isinstance(source, bytes):
        return None
    try:
        source.decode("utf-8")
        tokens = tuple(tokenize.tokenize(io.BytesIO(source).readline))
    except (IndentationError, LookupError, SyntaxError, tokenize.TokenError, UnicodeDecodeError):
        return None

    delimiters = {"(": ")", "[": "]", "{": "}"}
    stack: list[str] = []
    for token in tokens:
        if token.type == tokenize.ERRORTOKEN and not token.string.isspace():
            return None
        if token.type != tokenize.OP:
            continue
        if token.string in delimiters:
            stack.append(delimiters[token.string])
        elif token.string in delimiters.values():
            if not stack or stack.pop() != token.string:
                return None
    if stack:
        return None

    ignored = {
        tokenize.COMMENT,
        tokenize.DEDENT,
        tokenize.ENCODING,
        tokenize.ENDMARKER,
        tokenize.INDENT,
        tokenize.NEWLINE,
        tokenize.NL,
    }
    return tuple(token for token in tokens if token.type not in ignored)


def has_large_ingestion_target(source: bytes) -> bool:
    """Recognize the active ex_unit_test declaration, excluding text and comments."""
    tokens = _starlark_tokens(source)
    if tokens is None:
        return False

    opening = {"(", "[", "{"}
    closing = {")", "]", "}"}
    for index, token in enumerate(tokens[:-1]):
        if (
            token.type != tokenize.NAME
            or token.string != "ex_unit_test"
            or token.start[1] != 0
            or tokens[index + 1].type != tokenize.OP
            or tokens[index + 1].string != "("
        ):
            continue

        depth = 1
        cursor = index + 2
        while cursor < len(tokens):
            current = tokens[cursor]
            if current.type == tokenize.OP and current.string in opening:
                depth += 1
            elif current.type == tokenize.OP and current.string in closing:
                depth -= 1
                if depth == 0:
                    break
            elif (
                depth == 1
                and current.type == tokenize.NAME
                and current.string == "name"
                and cursor + 3 < len(tokens)
                and tokens[cursor + 1].type == tokenize.OP
                and tokens[cursor + 1].string == "="
                and tokens[cursor + 2].type == tokenize.STRING
                and tokens[cursor + 3].type == tokenize.OP
                and tokens[cursor + 3].string in {",", ")"}
            ):
                try:
                    value = ast.literal_eval(tokens[cursor + 2].string)
                except (SyntaxError, ValueError):
                    return False
                if value == "large_ingestion_release_gate":
                    return True
            cursor += 1
    return False


def has_large_ingestion_action(source: bytes) -> bool:
    """Recognize the exact top-level action entry in the root actions mapping."""
    if not isinstance(source, bytes):
        return False
    try:
        text = source.decode("utf-8")
    except UnicodeDecodeError:
        return False
    for index, character in enumerate(text):
        if character == "\t" or character == "\x00":
            return False
        if ord(character) < 0x20 and character not in {"\n", "\r"}:
            return False
        if character == "\r" and (index + 1 == len(text) or text[index + 1] != "\n"):
            return False

    lines = text.splitlines()
    action_headers = [index for index, line in enumerate(lines) if line == "actions:"]
    if len(action_headers) != 1:
        return False

    found = False
    for line in lines[action_headers[0] + 1 :]:
        if line and not line[0].isspace() and not line.startswith("#"):
            break
        if line == '  - name: "LargeIngestionGate"':
            found = True
    return found


class PolicyError(Exception):
    """Expected fail-closed release policy error."""


class GitEvidence(Protocol):
    def resolve(self, revision: str) -> str: ...
    def is_shallow(self) -> bool: ...
    def is_ancestor(self, ancestor: str, descendant: str) -> bool: ...
    def tree_sha(self, commit: str) -> str: ...
    def first_parent_history(self, base_ref: str, limit: int = FIRST_PARENT_WALK_LIMIT) -> Sequence[str]: ...
    def read_tree_file(self, commit: str, path: str) -> bytes | None: ...
    def marker_introductions(self, base_ref: str) -> Sequence[str]: ...


class StatusSource(Protocol):
    def snapshot(self, timeout_seconds: float) -> Sequence["CommitStatus"]: ...


class Clock(Protocol):
    def monotonic(self) -> float: ...
    def sleep(self, seconds: float) -> None: ...


@dataclass(frozen=True)
class CommitStatus:
    state: str
    context: str
    target_url: str
    created_at: datetime
    id: int


@dataclass(frozen=True)
class GateResult:
    message: str
    target_url: str | None = None


class GitRepository:
    def __init__(self, workspace: Path, runner: Callable[..., object]):
        self.workspace = workspace
        self.runner = runner

    def _run(self, arguments: Sequence[str], operation: str):
        argv = ["git", "-C", str(self.workspace), *arguments]
        try:
            return self.runner(
                argv,
                capture_output=True,
                check=False,
                shell=False,
            )
        except OSError as error:
            raise PolicyError(f"git {operation} could not execute") from error

    @staticmethod
    def _stdout_bytes(result: object, operation: str) -> bytes:
        stdout = getattr(result, "stdout", None)
        if not isinstance(stdout, bytes):
            raise PolicyError(f"git {operation} returned malformed output")
        return stdout

    @staticmethod
    def _stderr_bytes(result: object, operation: str) -> bytes:
        stderr = getattr(result, "stderr", None)
        if not isinstance(stderr, bytes):
            raise PolicyError(f"git {operation} returned malformed diagnostics")
        return stderr

    @staticmethod
    def _decode(stdout: bytes, operation: str) -> str:
        try:
            return stdout.decode("utf-8")
        except UnicodeDecodeError as error:
            raise PolicyError(f"git {operation} returned invalid UTF-8") from error

    def resolve(self, revision: str) -> str:
        result = self._run(
            ["rev-parse", "--verify", f"{revision}^{{commit}}"], "resolution"
        )
        if getattr(result, "returncode", None) != 0:
            raise PolicyError("git revision could not be resolved")
        if self._stderr_bytes(result, "resolution"):
            raise PolicyError("git revision resolution was ambiguous or emitted a warning")
        value = self._decode(self._stdout_bytes(result, "resolution"), "resolution").strip()
        if not FULL_SHA.fullmatch(value):
            raise PolicyError("git resolution did not return one full SHA")
        return value

    def worktree_root(self) -> Path:
        result = self._run(["rev-parse", "--show-toplevel"], "worktree-root check")
        if getattr(result, "returncode", None) != 0:
            raise PolicyError("git worktree-root check failed")
        value = self._decode(
            self._stdout_bytes(result, "worktree-root check"), "worktree-root check"
        ).strip()
        if not value:
            raise PolicyError("git worktree-root check returned malformed output")
        return Path(value).resolve()

    def is_shallow(self) -> bool:
        result = self._run(
            ["rev-parse", "--is-shallow-repository"], "shallow-history check"
        )
        if getattr(result, "returncode", None) != 0:
            raise PolicyError("git shallow-history check failed")
        value = self._decode(
            self._stdout_bytes(result, "shallow-history check"),
            "shallow-history check",
        ).strip()
        if value not in ("true", "false"):
            raise PolicyError("git shallow-history check returned malformed output")
        return value == "true"

    def is_ancestor(self, ancestor: str, descendant: str) -> bool:
        result = self._run(
            ["merge-base", "--is-ancestor", ancestor, descendant], "ancestry check"
        )
        returncode = getattr(result, "returncode", None)
        if returncode == 0:
            return True
        if returncode == 1:
            return False
        raise PolicyError("git ancestry check returned an unexpected exit")

    def tree_sha(self, commit: str) -> str:
        result = self._run(
            ["rev-parse", "--verify", f"{commit}^{{tree}}"], "tree resolution"
        )
        if getattr(result, "returncode", None) != 0:
            raise PolicyError("git tree could not be resolved")
        if self._stderr_bytes(result, "tree resolution"):
            raise PolicyError("git tree resolution was ambiguous or emitted a warning")
        value = self._decode(self._stdout_bytes(result, "tree resolution"), "tree resolution").strip()
        if not FULL_SHA.fullmatch(value):
            raise PolicyError("git tree resolution did not return one full SHA")
        return value

    def first_parent_history(
        self, base_ref: str, limit: int = FIRST_PARENT_WALK_LIMIT
    ) -> Sequence[str]:
        if isinstance(limit, bool) or not isinstance(limit, int) or limit <= 0:
            raise PolicyError("first-parent history limit must be a positive integer")
        result = self._run(
            ["rev-list", "--first-parent", f"--max-count={limit}", base_ref],
            "first-parent history",
        )
        if getattr(result, "returncode", None) != 0:
            raise PolicyError("git first-parent history lookup failed")
        output = self._decode(
            self._stdout_bytes(result, "first-parent history"),
            "first-parent history",
        )
        commits = [line.strip() for line in output.splitlines() if line.strip()]
        if any(not FULL_SHA.fullmatch(commit) for commit in commits):
            raise PolicyError("git first-parent history returned a malformed SHA")
        return commits

    def read_tree_file(self, commit: str, path: str) -> bytes | None:
        listing = self._run(
            ["ls-tree", "-z", "--full-tree", commit, "--", path],
            "immutable-tree lookup",
        )
        if getattr(listing, "returncode", None) != 0:
            raise PolicyError("git immutable-tree lookup failed")
        listing_bytes = self._stdout_bytes(listing, "immutable-tree lookup")
        if not listing_bytes:
            return None
        entries = [entry for entry in listing_bytes.split(b"\0") if entry]
        if len(entries) != 1:
            raise PolicyError("git immutable-tree lookup returned malformed evidence")

        content = self._run(["show", f"{commit}:{path}"], "immutable-tree read")
        if getattr(content, "returncode", None) != 0:
            raise PolicyError("git immutable-tree read failed")
        return self._stdout_bytes(content, "immutable-tree read")

    def marker_introductions(self, base_ref: str) -> Sequence[str]:
        result = self._run(
            [
                "log",
                "--first-parent",
                "--reverse",
                "--diff-filter=A",
                "--format=%H",
                base_ref,
                "--",
                MARKER_PATH,
            ],
            "marker-introduction lookup",
        )
        if getattr(result, "returncode", None) != 0:
            raise PolicyError("git marker-introduction lookup failed")
        output = self._decode(
            self._stdout_bytes(result, "marker-introduction lookup"),
            "marker-introduction lookup",
        )
        return [line.strip() for line in output.splitlines() if line.strip()]


class GhStatusClient:
    def __init__(
        self,
        repository: str,
        commit: str,
        token: str,
        runner: Callable[..., object],
        environment: Mapping[str, str],
    ):
        self.repository = repository
        self.commit = commit
        self.token = token
        self.runner = runner
        self.environment = environment

    def snapshot(self, timeout_seconds: float) -> Sequence[CommitStatus]:
        if not math.isfinite(timeout_seconds) or timeout_seconds <= 0:
            raise PolicyError("GitHub status request timeout must be finite positive")
        argv = [
            "gh",
            "api",
            "--paginate",
            "--slurp",
            f"/repos/{self.repository}/commits/{self.commit}/statuses?per_page=100",
        ]
        child_environment = dict(self.environment)
        child_environment["GH_TOKEN"] = self.token
        # bazel run's hermetic PATH is the Python toolchain plus /bin:/usr/bin.
        # The signing runner's `gh` lives in $HOME/.local/bin (or /usr/local/bin)
        # and is invisible unless we put those directories back.
        path_parts = ["/usr/local/bin", "/usr/bin", "/bin"]
        home = child_environment.get("HOME")
        if isinstance(home, str) and home:
            path_parts.insert(0, str(Path(home) / ".local" / "bin"))
        existing_path = child_environment.get("PATH")
        if isinstance(existing_path, str) and existing_path:
            path_parts.append(existing_path)
        child_environment["PATH"] = ":".join(path_parts)
        try:
            result = self.runner(
                argv,
                capture_output=True,
                check=False,
                env=child_environment,
                shell=False,
                timeout=timeout_seconds,
            )
        except subprocess.TimeoutExpired as error:
            raise PolicyError("GitHub status request timed out") from error
        except OSError as error:
            raise PolicyError("GitHub status request could not execute") from error
        if getattr(result, "returncode", None) != 0:
            raise PolicyError("GitHub status request failed")
        stdout = getattr(result, "stdout", None)
        if not isinstance(stdout, bytes):
            raise PolicyError("GitHub status response was malformed")
        try:
            decoded = stdout.decode("utf-8")
            pages = json.loads(decoded)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise PolicyError("GitHub status response was not valid UTF-8 JSON") from error

        if not isinstance(pages, list) or not pages:
            raise PolicyError("GitHub status response did not contain page arrays")
        if any(not isinstance(page, list) for page in pages):
            raise PolicyError("GitHub status response had a malformed page shape")

        statuses = []
        for record in (item for page in pages for item in page):
            if not isinstance(record, dict):
                raise PolicyError("GitHub status response contained a malformed record")
            context = record.get("context")
            if not isinstance(context, str):
                raise PolicyError("GitHub status record had a malformed context")
            if context != STATUS_CONTEXT:
                continue
            required = ("state", "context", "target_url", "created_at", "id")
            if any(field not in record for field in required):
                raise PolicyError("LargeIngestionGate status record was incomplete")
            state = record["state"]
            target_url = record["target_url"]
            created_at = record["created_at"]
            status_id = record["id"]
            if not isinstance(state, str) or not isinstance(target_url, str):
                raise PolicyError("LargeIngestionGate status record had malformed text fields")
            if not isinstance(created_at, str):
                raise PolicyError("LargeIngestionGate status timestamp was malformed")
            if isinstance(status_id, bool) or not isinstance(status_id, int):
                raise PolicyError("LargeIngestionGate status id was malformed")
            try:
                timestamp = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
            except ValueError as error:
                raise PolicyError("LargeIngestionGate status timestamp was malformed") from error
            if timestamp.tzinfo is None or timestamp.utcoffset() is None:
                raise PolicyError("LargeIngestionGate status timestamp lacked a timezone")
            statuses.append(
                CommitStatus(
                    state=state,
                    context=context,
                    target_url=target_url,
                    created_at=timestamp.astimezone(timezone.utc),
                    id=status_id,
                )
            )
        return statuses


def determine_applicability(
    git: GitEvidence, release_commit: str, base_ref: str
) -> bool:
    resolved_release = git.resolve(release_commit)
    resolved_base = git.resolve(base_ref)
    if resolved_release != release_commit:
        raise PolicyError("release resolution did not preserve the supplied immutable SHA")
    if git.is_shallow():
        raise PolicyError("shallow git history cannot prove release applicability")
    if not git.is_ancestor(resolved_release, resolved_base):
        raise PolicyError("release commit is not reachable from the fetched base")

    base_marker = git.read_tree_file(resolved_base, MARKER_PATH)
    if base_marker != MARKER_BYTES:
        raise PolicyError("base marker is absent or malformed")

    introductions = list(git.marker_introductions(base_ref))
    if len(introductions) != 1 or not FULL_SHA.fullmatch(introductions[0]):
        raise PolicyError("marker introduction evidence must contain exactly one full SHA")
    introduction = introductions[0]

    release_marker = git.read_tree_file(resolved_release, MARKER_PATH)
    if release_marker is not None:
        if release_marker != MARKER_BYTES:
            raise PolicyError("release marker is malformed")
        target = git.read_tree_file(resolved_release, TARGET_PATH)
        if target is None or not has_large_ingestion_target(target):
            raise PolicyError("release tree lacks the large-ingestion Bazel target")
        action = git.read_tree_file(resolved_release, ACTION_PATH)
        if action is None or not has_large_ingestion_action(action):
            raise PolicyError("release tree lacks the LargeIngestionGate action")
        return True

    if git.is_ancestor(introduction, resolved_release):
        raise PolicyError("release tree deleted or corrupted the permanent marker")
    if git.is_ancestor(resolved_release, introduction):
        return False
    raise PolicyError("release and marker introduction have divergent history")


def qualification_commits(
    git: GitEvidence, release_commit: str, base_ref: str
) -> tuple[str, ...]:
    """Release SHA plus same-tree first-parent descendants on the fetched base.

    Ancestry-preserving merges of the chore commit onto staging keep the tree
    and change the SHA. LargeIngestionGate runs on the staging push, not the
    tag, so publication must accept the merge commit's status.
    """
    resolved_release = git.resolve(release_commit)
    release_tree = git.tree_sha(resolved_release)
    ordered = [resolved_release]
    seen = {resolved_release}
    for commit in git.first_parent_history(base_ref, FIRST_PARENT_WALK_LIMIT):
        if commit in seen:
            continue
        if not git.is_ancestor(resolved_release, commit):
            break
        if git.tree_sha(commit) != release_tree:
            continue
        ordered.append(commit)
        seen.add(commit)
    return tuple(ordered)


def latest_status(statuses: Sequence[CommitStatus]) -> CommitStatus | None:
    matching = [status for status in statuses if status.context == STATUS_CONTEXT]
    if not matching:
        return None
    return max(matching, key=lambda status: (status.created_at, status.id))


def validate_target_url(candidate: str, configured_prefix: str) -> str:
    if not isinstance(candidate, str) or not isinstance(configured_prefix, str):
        raise PolicyError("BuildBuddy invocation URL could not be parsed")
    if any(
        character.isspace() or ord(character) < 0x20 or ord(character) == 0x7F
        for value in (candidate, configured_prefix)
        for character in value
    ):
        raise PolicyError("BuildBuddy invocation URL contains raw whitespace or control characters")
    try:
        configured = urlparse(configured_prefix)
        parsed = urlparse(candidate)
        configured_port = configured.port
        candidate_port = parsed.port
    except (TypeError, ValueError) as error:
        raise PolicyError("BuildBuddy invocation URL could not be parsed") from error

    if (
        configured_prefix != TARGET_URL_PREFIX
        or configured.scheme != "https"
        or configured.hostname != BUILDBUDDY_HOST
        or configured.username is not None
        or configured.password is not None
        or configured_port is not None
        or configured.path != INVOCATION_PATH
        or configured.params
        or configured.query
        or configured.fragment
    ):
        raise PolicyError("configured BuildBuddy URL prefix is not the fixed safe prefix")
    if (
        parsed.scheme != "https"
        or parsed.hostname != BUILDBUDDY_HOST
        or parsed.username is not None
        or parsed.password is not None
        or candidate_port is not None
        or not parsed.path.startswith(INVOCATION_PATH)
    ):
        raise PolicyError("status target URL is not a BuildBuddy invocation URL")
    invocation_id = parsed.path[len(INVOCATION_PATH) :].split("/", 1)[0]
    if not invocation_id:
        raise PolicyError("status target URL has no BuildBuddy invocation id")
    return candidate


def wait_for_gate(
    git: GitEvidence,
    status_factory: Callable[[str], StatusSource],
    clock: Clock,
    release_commit: str,
    base_ref: str,
    timeout_seconds: float,
    poll_seconds: float,
    target_url_prefix: str,
) -> GateResult:
    if (
        not math.isfinite(timeout_seconds)
        or not math.isfinite(poll_seconds)
        or timeout_seconds <= 0
        or poll_seconds <= 0
    ):
        raise PolicyError("timeout and polling intervals must be finite positive values")

    applicable = determine_applicability(git, release_commit, base_ref)
    if not applicable:
        return GateResult(HISTORICAL_NOT_APPLICABLE)

    commits = qualification_commits(git, release_commit, base_ref)
    sources = {sha: status_factory(sha) for sha in commits}
    deadline = clock.monotonic() + timeout_seconds
    while True:
        before_snapshot = clock.monotonic()
        if before_snapshot >= deadline:
            raise PolicyError("timed out waiting for LargeIngestionGate success")

        newest_by_sha: dict[str, CommitStatus | None] = {}
        after_snapshot = before_snapshot
        for sha, source in sources.items():
            now = clock.monotonic()
            if now >= deadline:
                raise PolicyError("timed out waiting for LargeIngestionGate success")
            snapshot = source.snapshot(deadline - now)
            after_snapshot = clock.monotonic()
            if after_snapshot >= deadline:
                raise PolicyError("timed out waiting for LargeIngestionGate success")
            newest_by_sha[sha] = latest_status(snapshot)

        successes = [
            newest
            for newest in newest_by_sha.values()
            if newest is not None and newest.state == "success"
        ]
        if successes:
            target_url = validate_target_url(successes[0].target_url, target_url_prefix)
            return GateResult("QUALIFIED", target_url)

        terminals = [
            newest
            for newest in newest_by_sha.values()
            if newest is not None and newest.state not in ("success", "pending")
        ]
        missing_or_pending = [
            newest
            for newest in newest_by_sha.values()
            if newest is None or newest.state == "pending"
        ]
        if terminals and not missing_or_pending:
            state_name = terminals[0].state
            if state_name in ("failure", "error"):
                raise PolicyError(
                    f"newest LargeIngestionGate status is terminal {state_name}"
                )
            raise PolicyError(
                f"newest LargeIngestionGate status has unknown state {state_name!r}"
            )

        clock.sleep(min(poll_seconds, deadline - after_snapshot))
