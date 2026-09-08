# Change: Harden managed agent updater exec arguments

## Why
The managed agent release path still forwards gateway-sourced `version`, `command_id`, and `command_type` strings into the updater process without a tight validation boundary immediately before `exec`. Go does not invoke a shell here, but the current behavior still leaves unnecessary ambiguity for updater argument parsing, log safety, and future maintenance of the activation path.

SR-2026-002 correctly identifies this as a defense-in-depth gap at the gateway-to-agent trust boundary. Managed release activation should fail closed if those network-sourced fields are malformed, unexpected, or contain control characters.

## What Changes
- Validate the staged release version used for updater activation against a strict managed-release token format instead of only directory-safety rules.
- Validate the managed release `command_id` as a canonical UUID before passing it to the updater.
- Validate the managed release `command_type` against the allowed managed-release activation command type set, which currently contains only `agent.update_release`.
- Reject control characters and NUL bytes in updater-bound activation arguments and surface a specific activation validation error instead of executing the updater.
- Add focused agent tests covering accepted and rejected updater activation arguments.

## Impact
- Affected specs:
  - `agent-release-management`
- Affected code:
  - `go/pkg/agent/control_stream.go`
  - `go/pkg/agent/release_runtime.go`
  - `go/pkg/agent/release_update.go`
  - `go/pkg/agent/release_runtime_test.go`
  - release-path tests that cover staged activation
- Breaking behavior:
  - Managed release activation will now reject malformed or unexpected command metadata before the updater process is spawned.
