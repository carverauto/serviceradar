# Go Source Tree `/go/`

Bazel builds and tests everything here. `go build` and `go test` still work for quick local
iteration, but they are not the contract: the binaries that ship come out of the Bazel graph,
and CI only ever runs Bazel. When the two disagree, Bazel is right.

The tree holds 89 `go_library` targets, 16 `go_binary` targets and 51 test targets across
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
                     opentext-network-automation,proxmox,sample-northbound,unifi-protect}
go/tools/wasm-plugin-harness
```

This trips people up, so be clear about what it means. `go test ./...` from the repo root does
not reach those ten; `go list ./go/cmd/wasm-plugins/...` reports "matched no packages". Their
tests are not part of the Go test surface at all, and no Bazel target runs them either. Roughly
300 test functions live there without a gate. If you touch a Wasm plugin, run its tests from
inside its own directory.

The separation is deliberate. Each plugin declares itself under `contrib/plugins/go/`, not
under the root module path, because it models what an external author writes against the
published SDK. The root module does not require that SDK at all, so merging them would drag it
and each plugin's own dependencies into the root `go.sum` for code that only ever compiles to
`wasip1`.

One thing does block unification, and it is worth fixing on its own. Eight plugins require the
SDK as `code.carverauto.dev/carverauto/serviceradar-sdk-go` while `dusk-checker` requires
`github.com/carverauto/serviceradar-sdk-go`, and the SDK declares the second. Those two cannot
coexist in one module, and Gazelle fails on the mismatch:

```
module declares its path as: github.com/carverauto/serviceradar-sdk-go
        but was required as: code.carverauto.dev/carverauto/serviceradar-sdk-go
```

Getting the plugin tests under Bazel does not need the modules merged. `go_deps.from_file`
accepts several `go.mod` files, so the order of work is: normalise the SDK path across all nine,
add a `from_file` entry per plugin module, then let Gazelle generate `go_library` and `go_test`
targets. Those run as host Go and leave the TinyGo build path alone.

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

## 4. Every package with tests needs a `go_test`

`go test ./...` finds test files by walking the tree. Bazel only runs targets that exist. A
package can therefore have a full test file and be silently untested for months, and nothing
reports it.

This has already happened once. Five packages had tests that `go test ./...` ran and Bazel did
not: `pkg/edgeonboarding`, `pkg/cli`, `pkg/config`, `pkg/config/bootstrap` and `pkg/natsutil`,
42 test functions between them. Adding a `_test.go` file is not enough. Add the target too.

To check that the invariant still holds, compare the two views:

```bash
go list -f '{{if or .TestGoFiles .XTestGoFiles}}{{.Dir}}{{end}}' ./... | sed "s|^$PWD/||" | sort
grep -rl "go_test(" --include=BUILD.bazel go | sed 's|/BUILD.bazel||' | sort
```

Every path in the first list must appear in the second.

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

## 9. Targets that need something extra

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

## 10. Binaries and images

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
