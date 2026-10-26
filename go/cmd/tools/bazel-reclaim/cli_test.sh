#!/usr/bin/env bash
# Drive the bazel-reclaim binary (not the in-process helpers) against disposable
# output-user roots. The oracle is the reclaim contract: dry-run deletes nothing;
# --apply deletes a base only when the workspace is positively gone; a live
# checkout, an uncertain stat/git failure, and a live Bazel server stay.
set -euo pipefail

resolve_bin() {
  local arg="${1:?binary path required}"
  local candidate
  local candidates=(
    "$arg"
    "${RUNFILES_DIR:-}/$arg"
    "${TEST_SRCDIR:-}/$arg"
    "${RUNFILES_DIR:-}/_main/$arg"
    "${TEST_SRCDIR:-}/_main/$arg"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if [[ -n "${TEST_SRCDIR:-}" ]]; then
    candidate="$(find "$TEST_SRCDIR" -type f -name bazel-reclaim -perm -111 2>/dev/null | head -n 1 || true)"
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  echo "bazel-reclaim binary not executable from arg: $arg" >&2
  exit 1
}

BIN="$(resolve_bin "${1:?}")"
WORKDIR="$(mktemp -d "${TEST_TMPDIR:-/tmp}/bazel-reclaim.XXXXXX")"
SANDBOX_HOME="$WORKDIR/home"
mkdir -p "$SANDBOX_HOME"
# The sandbox home and fixture root must be searchable by an unprivileged
# uid when the permission scenario drops root.
chmod 755 "$WORKDIR" "$SANDBOX_HOME"
if command -v git >/dev/null 2>&1; then
  export GIT_CONFIG_GLOBAL="$WORKDIR/gitconfig"
  git config --file "$GIT_CONFIG_GLOBAL" --add safe.directory '*' >/dev/null
fi

cleanup() {
  # Permission-denied fixtures must be writable again before the sandbox wipes them.
  chmod -R u+rwx "$WORKDIR" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

pass() { echo "PASS: $*"; }

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# tool runs the product with a private HOME and USER so a missing flag cannot
# scan the executor's real output user root.
tool() {
  env -u XDG_CACHE_HOME HOME="$SANDBOX_HOME" USER="reclaimtest" "$BIN" "$@"
}

write_base() {
  local root="$1"
  local name="$2"
  local workspace="$3"
  local base="$root/$name"

  mkdir -p "$base"
  printf '%s\n' "$workspace" >"$base/DO_NOT_BUILD_HERE"
  printf '%s\n' "$base"
}

assert_exists() {
  [[ -d "$1" ]] || fail "$2: expected directory to remain: $1"
}

assert_gone() {
  [[ ! -e "$1" ]] || fail "$2: expected directory to be deleted: $1"
}

# --- missing output user root names the parent of output_base ---
missing_root_out="$WORKDIR/missing-root.out"
if tool >"$missing_root_out" 2>&1; then
  fail "no configured root exited 0: $(cat "$missing_root_out")"
fi
grep -F 'parent of bazel info output_base' "$missing_root_out" >/dev/null \
  || fail "empty-root error does not name the parent of output_base: $(cat "$missing_root_out")"
pass "empty output user root tells the operator to use the parent of bazel info output_base"

# --- default root discovery under an isolated HOME ---
default_root="$SANDBOX_HOME/.cache/bazel/_bazel_reclaimtest"
default_ws="$WORKDIR/default-gone"
default_base="$(write_base "$default_root" "hashdefault" "$default_ws")"
default_out="$WORKDIR/default.out"
tool >"$default_out"
grep -F "stale" "$default_out" >/dev/null || fail "default root did not report the stale base: $(cat "$default_out")"
grep -F "$default_base" "$default_out" >/dev/null || fail "default root did not list $default_base: $(cat "$default_out")"
assert_exists "$default_base" "default-root dry-run"
grep -F 'dry run: nothing deleted' "$default_out" >/dev/null || fail "dry-run notice missing: $(cat "$default_out")"
pass "dry-run against the isolated default output user root reports stale and deletes nothing"

# --- XDG_CACHE_HOME is an output user root when that variable is set ---
xdg_home="$WORKDIR/xdg-cache"
xdg_root="$xdg_home/bazel/_bazel_reclaimtest"
xdg_ws="$WORKDIR/xdg-gone"
xdg_base="$(write_base "$xdg_root" "hashxdg" "$xdg_ws")"
xdg_out="$WORKDIR/xdg.out"
HOME="$SANDBOX_HOME" USER="reclaimtest" XDG_CACHE_HOME="$xdg_home" "$BIN" >"$xdg_out"
grep -F "stale" "$xdg_out" >/dev/null || fail "XDG root did not report the stale base: $(cat "$xdg_out")"
grep -F "$xdg_base" "$xdg_out" >/dev/null || fail "XDG root did not list $xdg_base: $(cat "$xdg_out")"
assert_exists "$xdg_base" "xdg dry-run"
pass "dry-run with XDG_CACHE_HOME set reports the base under that cache"

# --- explicit root: keep a live checkout, report a missing workspace, delete nothing ---
pair_root="$WORKDIR/pair-root"
mkdir -p "$pair_root"
live_ws="$WORKDIR/live-main"
mkdir -p "$live_ws/.git"
live_base="$(write_base "$pair_root" "hashlive" "$live_ws")"
gone_base="$(write_base "$pair_root" "hashgone" "$WORKDIR/does-not-exist")"
mkdir -p "$pair_root/not-a-base"
pair_out="$WORKDIR/pair.out"
tool --output-user-root "$pair_root" >"$pair_out"
grep -F "keep" "$pair_out" >/dev/null || fail "live checkout not kept: $(cat "$pair_out")"
grep -F "stale" "$pair_out" >/dev/null || fail "missing workspace not stale: $(cat "$pair_out")"
grep -F 'not-a-base' "$pair_out" && fail "directory without DO_NOT_BUILD_HERE was reported: $(cat "$pair_out")" || true
assert_exists "$live_base" "pair dry-run live"
assert_exists "$gone_base" "pair dry-run stale"
pass "dry-run keeps a live checkout, reports a missing workspace, and ignores non-bases"

# --- --apply deletes only the stale base ---
tool --output-user-root "$pair_root" --apply >"$WORKDIR/pair-apply.out"
assert_exists "$live_base" "apply live checkout"
assert_gone "$gone_base" "apply missing workspace"
assert_exists "$live_ws" "apply must not delete the workspace itself"
grep -F "deleted" "$WORKDIR/pair-apply.out" >/dev/null || fail "apply did not report deleted: $(cat "$WORKDIR/pair-apply.out")"
pass "--apply deletes the missing-workspace base and leaves the live checkout"

# --- workspace path that exists as a file is not a removed checkout ---
file_root="$WORKDIR/file-root"
mkdir -p "$file_root"
file_ws="$WORKDIR/not-a-directory"
: >"$file_ws"
file_base="$(write_base "$file_root" "hashfile" "$file_ws")"
tool --output-user-root "$file_root" --apply >"$WORKDIR/file-apply.out"
assert_exists "$file_base" "apply file workspace"
[[ -f "$file_ws" ]] || fail "apply must not delete the workspace file: $file_ws"
grep -F 'keep' "$WORKDIR/file-apply.out" >/dev/null \
  || fail "file workspace reason: $(cat "$WORKDIR/file-apply.out")"
if grep -F 'deleted' "$WORKDIR/file-apply.out" >/dev/null; then
  fail "apply deleted a base whose workspace path is a file: $(cat "$WORKDIR/file-apply.out")"
fi
pass "--apply keeps a base whose workspace path is a file"

# --- linked worktree with a missing gitdir is stale even when git would not say so ---
missing_gitdir_root="$WORKDIR/missing-gitdir-root"
mkdir -p "$missing_gitdir_root"
missing_gitdir_ws="$WORKDIR/missing-gitdir-ws"
mkdir -p "$missing_gitdir_ws"
printf 'gitdir: %s\n' "$WORKDIR/no-such-gitdir" >"$missing_gitdir_ws/.git"
missing_gitdir_base="$(write_base "$missing_gitdir_root" "hashpruned" "$missing_gitdir_ws")"
fake_keep="$WORKDIR/fake-keep-bin"
mkdir -p "$fake_keep"
cat >"$fake_keep/git" <<'EOF'
#!/bin/sh
echo 'fatal: detected dubious ownership in repository' >&2
exit 128
EOF
chmod +x "$fake_keep/git"
PATH="$fake_keep:$PATH" tool --output-user-root "$missing_gitdir_root" --apply >"$WORKDIR/missing-gitdir.out"
assert_gone "$missing_gitdir_base" "apply missing gitdir"
assert_exists "$missing_gitdir_ws" "missing gitdir must not delete the workspace"
grep -F 'worktree gitdir no longer exists' "$WORKDIR/missing-gitdir.out" >/dev/null \
  || fail "missing gitdir reason: $(cat "$WORKDIR/missing-gitdir.out")"
pass "--apply deletes a linked worktree whose gitdir is gone, without asking git"

# --- gitdir exists, git fails for a reason other than 'not a git repository': keep ---
uncertain_root="$WORKDIR/uncertain-root"
mkdir -p "$uncertain_root"
uncertain_ws="$WORKDIR/uncertain-ws"
uncertain_gitdir="$WORKDIR/uncertain-gitdir"
mkdir -p "$uncertain_ws" "$uncertain_gitdir"
printf 'gitdir: %s\n' "$uncertain_gitdir" >"$uncertain_ws/.git"
uncertain_base="$(write_base "$uncertain_root" "hashuncertain" "$uncertain_ws")"
PATH="$fake_keep:$PATH" tool --output-user-root "$uncertain_root" --apply >"$WORKDIR/uncertain.out"
assert_exists "$uncertain_base" "apply uncertain git"
grep -F 'worktree registration unreadable' "$WORKDIR/uncertain.out" >/dev/null \
  || fail "uncertain git reason: $(cat "$WORKDIR/uncertain.out")"
pass "--apply keeps a base when git fails without proving the worktree is gone"

# --- successful worktree list that omits the path: stale ---
omit_root="$WORKDIR/omit-root"
mkdir -p "$omit_root"
omit_ws="$WORKDIR/omit-ws"
omit_gitdir="$WORKDIR/omit-gitdir"
mkdir -p "$omit_ws" "$omit_gitdir"
printf 'gitdir: %s\n' "$omit_gitdir" >"$omit_ws/.git"
omit_base="$(write_base "$omit_root" "hashomit" "$omit_ws")"
fake_omit="$WORKDIR/fake-omit-bin"
mkdir -p "$fake_omit"
cat >"$fake_omit/git" <<'EOF'
#!/bin/sh
printf '%s\n' 'worktree /somewhere/else' 'HEAD abc' 'branch refs/heads/main'
exit 0
EOF
chmod +x "$fake_omit/git"
PATH="$fake_omit:$PATH" tool --output-user-root "$omit_root" --apply >"$WORKDIR/omit.out"
assert_gone "$omit_base" "apply omitted worktree"
grep -F 'worktree no longer registered' "$WORKDIR/omit.out" >/dev/null \
  || fail "omitted list reason: $(cat "$WORKDIR/omit.out")"
pass "--apply deletes a base when a successful worktree list omits its path"

# --- successful list that includes the path: keep ---
listed_root="$WORKDIR/listed-root"
mkdir -p "$listed_root"
listed_ws="$WORKDIR/listed-ws"
listed_gitdir="$WORKDIR/listed-gitdir"
mkdir -p "$listed_ws" "$listed_gitdir"
printf 'gitdir: %s\n' "$listed_gitdir" >"$listed_ws/.git"
listed_base="$(write_base "$listed_root" "hashlisted" "$listed_ws")"
fake_list="$WORKDIR/fake-list-bin"
mkdir -p "$fake_list"
cat >"$fake_list/git" <<EOF
#!/bin/sh
printf '%s\n' 'worktree $listed_ws' 'HEAD abc'
exit 0
EOF
chmod +x "$fake_list/git"
PATH="$fake_list:$PATH" tool --output-user-root "$listed_root" --apply >"$WORKDIR/listed.out"
assert_exists "$listed_base" "apply listed worktree"
grep -F 'workspace exists' "$WORKDIR/listed.out" >/dev/null \
  || fail "listed worktree reason: $(cat "$WORKDIR/listed.out")"
pass "--apply keeps a base when the worktree list includes its path"

# --- real git: empty gitdir is not a repository, so the base is stale ---
if ! command -v git >/dev/null 2>&1; then
  fail "git is not on PATH; cannot drive the real-git scenarios"
fi
real_missing_root="$WORKDIR/real-missing-root"
mkdir -p "$real_missing_root"
real_missing_ws="$WORKDIR/real-missing-ws"
real_missing_gitdir="$WORKDIR/real-missing-gitdir"
mkdir -p "$real_missing_ws" "$real_missing_gitdir"
printf 'gitdir: %s\n' "$real_missing_gitdir" >"$real_missing_ws/.git"
real_missing_base="$(write_base "$real_missing_root" "hashrealmissing" "$real_missing_ws")"
# Prove the host git actually produces the phrase the classifier matches,
# using the same arguments the tool will run.
real_git_err="$WORKDIR/real-git.err"
set +e
git -C "$real_missing_ws" worktree list --porcelain >"$WORKDIR/real-git.out" 2>"$real_git_err"
real_git_code=$?
set -e
[[ "$real_git_code" -ne 0 ]] || fail "expected git to reject an empty gitdir, got: $(cat "$WORKDIR/real-git.out")"
grep -F -i 'not a git repository' "$real_git_err" >/dev/null \
  || fail "host git stderr lacks 'not a git repository': $(cat "$real_git_err")"
tool --output-user-root "$real_missing_root" --apply >"$WORKDIR/real-missing.out"
assert_gone "$real_missing_base" "apply real git missing repository"
grep -F 'worktree registration no longer exists' "$WORKDIR/real-missing.out" >/dev/null \
  || fail "real git missing-repo reason: $(cat "$WORKDIR/real-missing.out")"
pass "--apply deletes a base when real git reports the worktree is not a repository"

# --- real git: a registered linked worktree is kept ---
real_repo="$WORKDIR/real-repo"
real_wt="$WORKDIR/real-wt"
git init -b main "$real_repo" >/dev/null
git -C "$real_repo" -c user.email='reclaim@example.com' -c user.name='reclaim' commit --allow-empty -m init >/dev/null
git -C "$real_repo" worktree add "$real_wt" >/dev/null
real_keep_root="$WORKDIR/real-keep-root"
mkdir -p "$real_keep_root"
real_keep_base="$(write_base "$real_keep_root" "hashrealkeep" "$real_wt")"
tool --output-user-root "$real_keep_root" --apply >"$WORKDIR/real-keep.out"
assert_exists "$real_keep_base" "apply registered worktree"
assert_exists "$real_wt" "registered worktree directory"
grep -F 'workspace exists' "$WORKDIR/real-keep.out" >/dev/null \
  || fail "registered worktree reason: $(cat "$WORKDIR/real-keep.out")"
pass "--apply keeps the output base of a worktree real git still lists"

# --- unreadable workspace (permission), not a missing path: keep ---
unreadable_root="$WORKDIR/unreadable-root"
mkdir -p "$unreadable_root"
unreadable_parent="$WORKDIR/unreadable-parent"
unreadable_ws="$unreadable_parent/ws"
mkdir -p "$unreadable_ws"
unreadable_base="$(write_base "$unreadable_root" "hashunreadable" "$unreadable_ws")"
chmod 000 "$unreadable_parent"
chmod 755 "$unreadable_root" "$unreadable_base"
unreadable_out="$WORKDIR/unreadable.out"
run_unreadable() {
  if [[ "$(id -u)" -ne 0 ]]; then
    tool --output-user-root "$unreadable_root" --apply >"$unreadable_out"
    return $?
  fi

  # root still stats mode 000, which would look like a live workspace.
  if ! id nobody >/dev/null 2>&1; then
    echo "no nobody user" >&2
    return 2
  fi

  if command -v setpriv >/dev/null 2>&1; then
    local gid="nogroup"
    id -g nobody >/dev/null 2>&1 && gid="$(id -gn nobody)"
    setpriv --reuid=nobody --regid="$gid" --init-groups --inh-caps=-all \
      env HOME="$SANDBOX_HOME" USER="reclaimtest" "$BIN" --output-user-root "$unreadable_root" --apply \
      >"$unreadable_out"
    return $?
  fi

  if command -v runuser >/dev/null 2>&1; then
    runuser -u nobody -- env HOME="$SANDBOX_HOME" USER="reclaimtest" "$BIN" --output-user-root "$unreadable_root" --apply \
      >"$unreadable_out"
    return $?
  fi

  echo "no setpriv or runuser" >&2
  return 2
}
set +e
run_unreadable
unreadable_status=$?
set -e
chmod 755 "$unreadable_parent" || true
if [[ "$unreadable_status" -eq 0 ]]; then
  assert_exists "$unreadable_base" "apply unreadable workspace"
  grep -F 'workspace path unreadable' "$unreadable_out" >/dev/null \
    || fail "unreadable workspace reason: $(cat "$unreadable_out")"
  pass "--apply keeps a base when the workspace path cannot be stat-ed"
else
  echo "UNTESTED: unreadable-workspace (could not run the binary as an unprivileged uid: status $unreadable_status $(cat "$unreadable_out" 2>/dev/null || true))"
fi

# --- live server pid wins over a missing workspace ---
live_root="$WORKDIR/live-server-root"
mkdir -p "$live_root"
sleep 300 &
sleep_pid=$!
live_server_base="$(write_base "$live_root" "hashserver" "$WORKDIR/server-workspace-gone")"
mkdir -p "$live_server_base/server"
printf '%s\n' "$sleep_pid" >"$live_server_base/server/server.pid.txt"
tool --output-user-root "$live_root" --apply >"$WORKDIR/live-server.out"
kill "$sleep_pid" 2>/dev/null || true
wait "$sleep_pid" 2>/dev/null || true
assert_exists "$live_server_base" "apply live server"
grep -F 'skip-live-server' "$WORKDIR/live-server.out" >/dev/null \
  || fail "live server verdict: $(cat "$WORKDIR/live-server.out")"
pass "--apply leaves a base whose Bazel server pid is alive, even if the workspace is gone"

# --- dead pid does not protect a missing workspace ---
dead_root="$WORKDIR/dead-server-root"
mkdir -p "$dead_root"
dead_base="$(write_base "$dead_root" "hashdead" "$WORKDIR/dead-workspace-gone")"
mkdir -p "$dead_base/server"
dead_pid=2147483000
if kill -0 "$dead_pid" 2>/dev/null; then
  fail "chosen dead pid $dead_pid is alive; refusing to guess another"
fi
printf '%s\n' "$dead_pid" >"$dead_base/server/server.pid.txt"
tool --output-user-root "$dead_root" --apply >"$WORKDIR/dead-server.out"
assert_gone "$dead_base" "apply dead server pid"
pass "--apply deletes a missing-workspace base when server.pid.txt names a dead pid"

# --- a comma inside one --output-user-root value is part of the path ---
comma_root="$WORKDIR/cache,root"
mkdir -p "$comma_root"
comma_base="$(write_base "$comma_root" "hashcomma" "$WORKDIR/comma-workspace-gone")"
comma_out="$WORKDIR/comma.out"
tool --output-user-root "$comma_root" >"$comma_out"
grep -F "stale" "$comma_out" >/dev/null || fail "comma root did not report stale: $(cat "$comma_out")"
grep -F "$comma_base" "$comma_out" >/dev/null || fail "comma root did not list $comma_base: $(cat "$comma_out")"
assert_exists "$comma_base" "comma-root dry-run"
pass "--output-user-root keeps a comma inside one path and reports that missing workspace stale"

# --- inherited git repo env must not hide a registered worktree ---
# A successful list of some other repository, or a missing GIT_DIR, used to
# make --apply delete a live linked worktree. An empty gitdir stays stale.
git_env_root="$WORKDIR/git-env-root"
mkdir -p "$git_env_root"
git_env_other="$WORKDIR/git-env-other"
git init -b main "$git_env_other" >/dev/null
git -C "$git_env_other" -c user.email='reclaim@example.com' -c user.name='reclaim' commit --allow-empty -m init >/dev/null
git_env_repo="$WORKDIR/git-env-repo"
git_env_wt="$WORKDIR/git-env-wt"
git init -b main "$git_env_repo" >/dev/null
git -C "$git_env_repo" -c user.email='reclaim@example.com' -c user.name='reclaim' commit --allow-empty -m init >/dev/null
git -C "$git_env_repo" worktree add "$git_env_wt" >/dev/null
git_env_live="$(write_base "$git_env_root" "hashgitlive" "$git_env_wt")"
git_env_empty_ws="$WORKDIR/git-env-empty-ws"
git_env_empty_gitdir="$WORKDIR/git-env-empty-gitdir"
mkdir -p "$git_env_empty_ws" "$git_env_empty_gitdir"
printf 'gitdir: %s\n' "$git_env_empty_gitdir" >"$git_env_empty_ws/.git"
git_env_empty="$(write_base "$git_env_root" "hashgitempty" "$git_env_empty_ws")"
git_env_missing="$WORKDIR/git-env-missing"
run_git_env() {
  env -u XDG_CACHE_HOME \
    HOME="$SANDBOX_HOME" USER="reclaimtest" \
    GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" \
    GIT_DIR="${1:?}" \
    GIT_WORK_TREE="${2:?}" \
    GIT_COMMON_DIR="${3:?}" \
    GIT_OBJECT_DIRECTORY="${4:?}" \
    "$BIN" --output-user-root "$git_env_root" --apply
}
run_git_env "$git_env_other/.git" "$git_env_other" "$git_env_other/.git" "$git_env_other/.git/objects" \
  >"$WORKDIR/git-env-other.out"
assert_exists "$git_env_live" "apply with GIT_DIR pointed at another repository"
assert_exists "$git_env_wt" "worktree directory with GIT_DIR pointed at another repository"
grep -F 'workspace exists' "$WORKDIR/git-env-other.out" >/dev/null \
  || fail "GIT_DIR other-repo reason: $(cat "$WORKDIR/git-env-other.out")"
assert_gone "$git_env_empty" "apply empty gitdir while GIT_DIR points at another repository"
pass "--apply keeps a registered worktree when GIT_DIR names another repository, and still deletes an empty gitdir"

git_env_empty_ws="$WORKDIR/git-env-empty-ws-2"
git_env_empty_gitdir="$WORKDIR/git-env-empty-gitdir-2"
mkdir -p "$git_env_empty_ws" "$git_env_empty_gitdir"
printf 'gitdir: %s\n' "$git_env_empty_gitdir" >"$git_env_empty_ws/.git"
git_env_empty="$(write_base "$git_env_root" "hashgitempty2" "$git_env_empty_ws")"
run_git_env "$git_env_missing" "$git_env_missing-wt" "$git_env_missing-common" "$git_env_missing-objects" \
  >"$WORKDIR/git-env-missing.out"
assert_exists "$git_env_live" "apply with GIT_DIR pointed at a missing path"
grep -F 'workspace exists' "$WORKDIR/git-env-missing.out" >/dev/null \
  || fail "GIT_DIR missing-path reason: $(cat "$WORKDIR/git-env-missing.out")"
assert_gone "$git_env_empty" "apply empty gitdir while GIT_DIR points at a missing path"
pass "--apply keeps a registered worktree when GIT_DIR names a missing path, and still deletes an empty gitdir"

# Permission denials are only observable for a uid that is not root. Drop to
# nobody when the test itself is root; otherwise the current uid is the oracle.
tool_user_available() {
  if [[ "$(id -u)" -ne 0 ]]; then
    return 0
  fi
  id nobody >/dev/null 2>&1 && command -v setpriv >/dev/null 2>&1
}

as_tool_user() {
  if [[ "$(id -u)" -ne 0 ]]; then
    "$@"
    return $?
  fi
  local gid="nogroup"
  id -g nobody >/dev/null 2>&1 && gid="$(id -gn nobody)"
  setpriv --reuid=nobody --regid="$gid" --init-groups --inh-caps=-all "$@"
}

apply_as_tool_user() {
  local root="$1"
  local out="$2"
  as_tool_user env -u XDG_CACHE_HOME \
    HOME="$SANDBOX_HOME" USER="reclaimtest" GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" \
    "$BIN" --output-user-root "$root" --apply >"$out"
}

# --- unreadable gitdir, or registration files git cannot use, keeps the base ---
if ! tool_user_available; then
  echo "UNTESTED: unreadable-gitdir (root and no setpriv/nobody; mode 000 is still readable by root)"
else
  perm_repo="$WORKDIR/perm-repo"
  perm_wt="$WORKDIR/perm-wt"
  git init -b main "$perm_repo" >/dev/null
  git -C "$perm_repo" -c user.email='reclaim@example.com' -c user.name='reclaim' commit --allow-empty -m init >/dev/null
  git -C "$perm_repo" worktree add "$perm_wt" >/dev/null
  perm_gitdir="$(sed -n 's/^gitdir: //p' "$perm_wt/.git")"
  if [[ "$perm_gitdir" != /* ]]; then
    perm_gitdir="$perm_wt/$perm_gitdir"
  fi
  perm_root="$WORKDIR/perm-root"
  mkdir -p "$perm_root"
  perm_base="$(write_base "$perm_root" "hashperm" "$perm_wt")"

  # Nobody must be able to traverse the fixture and execute the binary.
  chmod -R a+rX "$WORKDIR"
  chmod 755 "$perm_gitdir"

  restore_perm() {
    chmod 755 "$perm_gitdir" "$(dirname "$perm_gitdir")" 2>/dev/null || true
    chmod 644 "$perm_gitdir/HEAD" 2>/dev/null || true
    chmod 755 "$perm_repo/.git/objects" "$perm_repo/.git/refs" 2>/dev/null || true
  }

  expect_keep_when_denied() {
    local label="$1"
    local out="$WORKDIR/perm-${label}.out"
    set +e
    apply_as_tool_user "$perm_root" "$out"
    local status=$?
    set -e
    restore_perm
    if [[ "$status" -ne 0 ]]; then
      fail "$label: bazel-reclaim exited $status: $(cat "$out" 2>/dev/null || true)"
    fi
    assert_exists "$perm_base" "apply $label"
    assert_exists "$perm_wt" "workspace $label"
    if grep -F 'deleted' "$out" >/dev/null; then
      fail "$label deleted the base: $(cat "$out")"
    fi
    grep -F 'keep' "$out" >/dev/null || fail "$label verdict: $(cat "$out")"
    pass "--apply keeps the output base ($label)"
  }

  # mode 000 gitdir: the directory exists but cannot be listed.
  chmod 000 "$perm_gitdir"
  if as_tool_user ls "$perm_gitdir" >/dev/null 2>&1; then
    restore_perm
    echo "UNTESTED: mode-000-gitdir (tool uid can still list the gitdir)"
  else
    expect_keep_when_denied "mode-000-gitdir"
  fi

  # mode 000 parent of the gitdir: stat of the gitdir fails closed.
  perm_parent="$(dirname "$perm_gitdir")"
  chmod 755 "$perm_gitdir"
  chmod 000 "$perm_parent"
  if as_tool_user ls "$perm_gitdir" >/dev/null 2>&1; then
    restore_perm
    echo "UNTESTED: mode-000-gitdir-parent (tool uid can still stat the gitdir)"
  else
    expect_keep_when_denied "mode-000-gitdir-parent"
  fi

  # Registration files still present. Git's "not a git repository" is not
  # enough to delete while HEAD, or the backing objects/refs, cannot be read.
  deny_registration() {
    local label="$1"
    local target="$2"
    chmod 000 "$target"
    local err="$WORKDIR/perm-${label}.git.err"
    set +e
    as_tool_user env GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" \
      git -C "$perm_wt" worktree list --porcelain >"$WORKDIR/perm-${label}.git.out" 2>"$err"
    local code=$?
    set -e
    if [[ "$code" -eq 0 ]]; then
      restore_perm
      echo "UNTESTED: $label (git still listed the worktree after mode 000 on $target)"
      return 0
    fi
    if ! grep -F -i 'not a git repository' "$err" >/dev/null; then
      restore_perm
      echo "UNTESTED: $label (git did not report not a git repository: $(cat "$err"))"
      return 0
    fi
    expect_keep_when_denied "$label"
  }

  deny_registration "mode-000-head" "$perm_gitdir/HEAD"
  deny_registration "mode-000-objects" "$perm_repo/.git/objects"
  deny_registration "mode-000-refs" "$perm_repo/.git/refs"
  restore_perm
fi

echo "BIN=$BIN"
echo "ALL_DRIVEN_SCENARIOS_COMPLETE"
