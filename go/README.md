# Go Source Tree `/go/`

Bazel builds and tests everything here. `go build` and `go test` still work for quick local
iteration, but they are not the contract: the binaries that ship come out of the Bazel graph,
and CI only ever runs Bazel. When the two disagree, Bazel is right.

The tree holds 75 `go_library` targets, 18 `go_binary` targets and 58 test targets across
roughly 100 `BUILD.bazel` files.

## 1. Layout

| Directory | What lives there |
| --- | --- |
| `cmd/` | Program entry points, one directory per binary. Most become container images. |
| `pkg/` | The bulk of the code. Agent, gateway, sweeper, poller, database clients, models. |
| `internal/` | Code deliberately unimportable from outside the module. |
| `tools/` | Build and validation helpers that are not products. |
| `tests/` | Cross-package end-to-end tests, gated behind the `e2e` build tag. |

`third_party/` is not source. It is a stray Bazel disk cache that was committed by accident;
do not add anything to it.

## 2. The root module, and the ten that are not in it

`go.mod` at the repo root covers almost all of this tree. Ten directories carry their own
`go.mod` and are separate modules:

```
go/cmd/wasm-plugins/{alienvault-otx,awx,axis,dusk-checker,netbox,
                     opentext-nom,proxmox,sample-northbound,unifi-protect}
go/tools/wasm-plugin-harness
```

This trips people up, so be clear about what it means. `go test ./...` from the repo root does
not reach those ten; `go list ./go/cmd/wasm-plugins/...` reports "matched no packages". Their
full suites are not part of the root Go test surface. Bazel has focused signal-contract tests
for Axis, Proxmox, and UniFi Protect, but roughly 300 other test functions in the nested modules
still live outside that gate. If you touch a Wasm plugin, run its tests from inside its own
directory in addition to any focused Bazel target.

The separation is deliberate. Each plugin declares itself under `contrib/plugins/go/`, not
under the root module path, because it models what an external author writes against the
published SDK. The root module does not require that SDK at all, so merging them would drag it
and each plugin's own dependencies into the root `go.sum` for code that only ever compiles to
`wasip1`.

Keep the plugins on one SDK module path and version; each plugin's `go.mod`
owns its dependency pin. Commit the generated `vendor/` tree alongside `go.mod`
and `go.sum`, and declare `vendor/**` in the plugin's Bazel `:srcs` filegroup
so dependency resolution does not require network access inside the TinyGo sandbox.
See the [Go template SDK update instructions](../js/cli/templates/plugin-go/README.md#updating-the-sdk)
when refreshing dependencies. The build wrapper
[`build_wasm_binary.sh`](../build/wasm_plugins/build_wasm_binary.sh) owns the
`GOFLAGS` defaults and override behavior.

`go_deps.from_file` accepts a `go_work` label, so a `go.work` listing all eleven
modules would give one MVS resolution and let Gazelle generate `go_library` and
`go_test` targets for the plugins. `sample-northbound` no longer reads the
callback signing fields that were dropped from `sdk.ActionCallback`.

 A `go.work` unifies version resolution, not package patterns. `./...` still returns only the root module's
packages, so a workspace alone does not put the plugin tests in reach of `go test ./...`.

The plugins are compiled by TinyGo through `//build/wasm_plugins`, not by `rules_go`. Several
of their `BUILD.bazel` files carry `# gazelle:ignore` for that reason.

## 3. BUILD files are hand-maintained

Gazelle is configured and works. Run it on a new package and keep what it gives you:

```bash
bazel run //:gazelle -- go/pkg/yournewpackage
```

Do not run it across the tree. A repo-wide pass rewrites label style (`//go/pkg/config:config`
becomes `//go/pkg/config`), re-adds dependencies that were deliberately trimmed, and proposes
duplicate test targets next to existing ones. The diff is large and almost entirely noise. The
directives that shape it live in the root `BUILD.bazel`:

```python
# gazelle:prefix github.com/carverauto/serviceradar
# gazelle:exclude go/pkg/agent/testdata
```

## 4. Every test **file** needs to be in a `go_test`

`go test ./...` finds test files by walking the tree. Bazel only runs what a target names. A
package can therefore have a full test file and be silently untested for months, and nothing
reports it.

Check at file level, not package level. Both failure modes are real and the package-level check
only catches the first:

- A package with tests and no `go_test` target at all. Five packages were in this state:
  `pkg/edgeonboarding`, `pkg/cli`, `pkg/config`, `pkg/config/bootstrap`, `pkg/natsutil`.
- A package whose `go_test` exists but omits files. Five more files were in this state
  (`pkg/models/auth_test.go`, `pkg/models/sweep_deepcopy_test.go`, `pkg/mtr/socket_test.go`,
  `pkg/sysmon/process_test.go`, `internal/fastsum/api_test.go`), and the package-level check
  passed the whole time because each package did have a target.

The same drift hits libraries. `pkg/cpufreq` shipped a `go_library` missing
`hostfreq_sampler.go` and `snapshot_clone.go`, so on macOS `go build` compiled the buffered
sampler and Bazel did not. Build constraints kept it off Linux, so no image was ever affected,
but the two builds disagreed for months.

The audit that catches all of it compares declared `srcs` against disk:

```bash
# every _test.go Bazel actually names
for t in $(bazel query 'kind(go_test, //go/...)' --output=label); do
  bazel query "labels(srcs, $t)" --output=label
done | sed 's|^//||;s|:|/|' | grep '_test\.go$' | sort -u > /tmp/declared.txt

# every _test.go on disk in the root module
find go -name '*_test.go' -not -path '*/testdata/*' \
  | grep -v '^go/cmd/wasm-plugins/' | grep -v '^go/tools/wasm-plugin-harness/' | sort > /tmp/ondisk.txt

comm -23 /tmp/ondisk.txt /tmp/declared.txt
```

Anything it prints must either be added to a target or carry a build constraint that explains
itself. Swap `go_test`/`_test.go` for `go_library`/non-test files to audit the library side.

## 5. Pure mode, cgo and the race detector

`.bazelrc` pins every Go build to pure mode:

```
build --@io_bazel_rules_go//go/config:pure
test  --@io_bazel_rules_go//go/config:pure
```

That means `CGO_ENABLED=0`. You can confirm it from the action itself:

```bash
bazel aquery 'mnemonic("GoCompilePkg", //go/pkg/logger:logger)' --output=text | grep Environment
```

Static, cgo-free binaries are what the container images want, so this is the right default. It
has one consequence worth knowing: the race detector needs cgo, so `//go/config:race` on its own
does nothing. Both flags are required together.

```bash
bazel test --config=ci \
  --@io_bazel_rules_go//go/config:pure=false \
  --@io_bazel_rules_go//go/config:race \
  //go/...
```

Those two flags produce a configuration nothing else in the repo builds. Cache entries under it
are populated only by the job that uses it, so expect colder builds there than elsewhere.

## 6. Dependencies

`go.mod` is the single source of truth. Both the toolchain and the dependency set are derived
from it in `MODULE.bazel`:

```python
go_sdk.from_file(name = "go_sdk", go_mod = "//:go.mod")
go_deps.from_file(go_mod = "//:go.mod")
```

Adding a dependency is therefore `go get`, then `go mod tidy`, then Gazelle on the packages that
import it. `MODULE.bazel.lock` records the resolved versions and is checked in.

A handful of modules need help and get it through overrides in `MODULE.bazel`. Some need their
BUILD files generated (`build_file_generation = "on"`); `google.golang.org/protobuf` also needs
`gazelle:proto disable`; `github.com/spiffe/go-spiffe/v2` is patched. Add to that list only when
a dependency genuinely fails without it.

## 7. Protobuf

Bazel does not generate the Go bindings. The `.pb.go` files are checked in and wrapped by a
plain `go_library`, and `proto/BUILD.bazel` opens with `# gazelle:ignore` so nothing tries to
regenerate them. Non-Bazel tooling depends on those checked-in files existing. Regenerate them
with `make generate-proto` and commit the result.

## 8. What CI runs

Two workflows cover this tree, and they do different jobs.

`main.yml` runs `tests(//...)` on every push and pull request, which includes all 51 Go test
targets in the default pure configuration. This is the ordinary test gate.

`golang-tests.yml` runs the same targets under the race detector and nothing else. It exists
because `main.yml` cannot give you `-race`, and duplicating the non-race pass there would only
pay twice for the same answer. It is scoped to `//go/...`.

The three Go tests under `//build/...` are release tooling rather than product code.
`main.yml` covers them. Keep them out of `//go/...` sweeps, because
`//build/release:publish_packages_test` data-depends on the packaging archives and drags in
30,000 transitive dependencies against about 1,500 for a typical package here.

## 9. The `integration` build tag runs nowhere

Six files carry `//go:build integration`. Nothing compiles them. `GO_TEST_TAGS` in the Makefile
is `-tags=hostfreq_embed` or empty, the database-backed Elixir suite uses explicit Bazel targets,
and no workflow passes the Go tag. There is no Bazel target either, because Bazel
cannot apply a Go build constraint per target: it would need
`--@io_bazel_rules_go//go/config:tags=integration`, which forks the whole Go configuration the
way the race flags do.

Code nothing compiles rots, and this did. When the constraint was lifted, two files no longer
built against the current API:

| File | Drift found |
| --- | --- |
| `pkg/mtr/tracer_integration_test.go` | `DefaultOptions()` had gained a `string` parameter, and `ctx` was used five lines before it was created |
| `pkg/agent/snmp/snmp_integration_test.go` | `NewSNMPService` had gained a `logger.Logger` parameter |

Both are repaired, and all six now compile and skip cleanly rather than failing. What each one
needs before it can actually run:

| File | Needs |
| --- | --- |
| `pkg/mtr/tracer_integration_test.go` | Raw sockets. Works as root, which the RBE executor is |
| `pkg/agent/checker_integration_test.go` | Raw sockets, same |
| `pkg/agent/proxmox_console_ssh_integration_test.go` | `sshd` on `PATH`, found via `exec.LookPath` |
| `pkg/agent/remoteaccess/ssh_integration_test.go` | `sshd` on `PATH`, same |
| `pkg/remoteaccess/sshca/openssh_integration_test.go` | `sshd` on `PATH`, same |
| `pkg/agent/snmp/snmp_integration_test.go` | An SNMP agent named by `SERVICERADAR_TEST_SNMP_TARGET` |

Two practical notes for whoever wires the CI job. The three `sshd` tests want the binary in
their own process namespace, so a sidecar container does not satisfy them; adding
`openssh-server` to `docker/Dockerfile.rbe` is the cheaper fix. And the SNMP suite used to
point at a hardcoded `192.168.1.1`, a private address belonging to whoever wrote it, so it is
now env-driven and skips when unset rather than failing after a ten-second timeout.

Because four of the six skip silently when their dependency is absent, a job that runs them
must assert they actually ran. Otherwise it goes green while testing nothing, which is the
state this section exists to describe.

## 10. Targets that need something extra

Most targets are plain. These five are not, and each carries a comment explaining why:

| Target | What it needs | Why |
| --- | --- | --- |
| `pkg/sysmon:sysmon_test` | `env = {"PATH": ...}` | gopsutil shells out to `netstat` on macOS. Linux reads `/proc/net/dev` and spawns nothing. |
| `pkg/agent/remoteaccess:remoteaccess_test` | `tags = ["no-sandbox"]` | Writes a helper script into `t.TempDir()` and executes it. The sandbox denies that. |
| `pkg/scan/banner_grab:banner_grab_integration_test` | `tags = ["manual"]` | A one-million-host synthetic run. `banner-grab-large.yml` runs it nightly. |
| `pkg/agent:plugin_runtime_action_test` | `data` on Wasm genrules | Needs real `.wasm` fixtures, so a plain `bazel build //go/...` compiles Wasm plugins. |
| `cmd/agent:agent` | `x_defs` | Stamps the release signing key and version at link time. |

The PATH entry deserves a note, because it is easy to get wrong in a costly way. `.bazelrc`
does not set `test --test_env=PATH`. It used to, without a value, which meant the invoking
shell's PATH became part of the cache key of every test in the repo; CI produced a different
PATH on every run, so no test result was ever reusable. Tests now get Bazel's own action PATH,
`/bin:/usr/bin:/usr/local/bin`, which is identical everywhere. When a test needs more than
that, give it a fixed string on the target, the way `sysmon_test` does. Never restore the
inherited form to fix one test.

## 11. Binaries and images

`cmd/` binaries are consumed by `//docker/images`, which places them at their runtime paths:

```python
"//go/cmd/data-services:data_services": "usr/local/bin/serviceradar-datasvc",
```

A binary that ships needs a `go_binary` target and an entry there. Building it locally proves
nothing about the image until both exist.

## Quick reference

```bash
# Build everything
bazel build //go/...

# Test everything, as main.yml does
bazel test //go/...

# Test under the race detector, as golang-tests.yml does
bazel test --@io_bazel_rules_go//go/config:pure=false \
           --@io_bazel_rules_go//go/config:race //go/...

# Regenerate one package's BUILD file
bazel run //:gazelle -- go/pkg/yournewpackage

# List every test target, excluding the nightly one
bazel query 'let t = kind(go_test, //go/...) in $t except attr("tags", "manual", $t)'
```
