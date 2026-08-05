# Bumblebee scanner (vendored)

Upstream: https://github.com/perplexityai/bumblebee, tag `v0.1.1`, commit
`c24089804ee66ece4bec6f14638cb98985389cdb`. License in
`upstream/LICENSE.bumblebee`, pin recorded in `upstream/VERSION.bumblebee`.

ServiceRadar calls the scanner in-process rather than shelling out to an
upstream CLI binary. The first-party caller is `//go/pkg/bumblebee`, which is
*not* here — only vendored code lives under `third_party`.

## Why the extra `upstream/` level

The Go package clause is `package upstream`, and the directory name has to match
it or every import site reads `upstream.ScanRoot` against a path ending in
`bumblebee`. Keeping the component means the move touched no vendored `.go`
source at all — only import paths.

It also preserves Go's `internal/` rule. `upstream/internal/...` is importable
only by packages rooted at `upstream/`, which is what keeps the scanner's
internals sealed off from the rest of ServiceRadar. Flattening this directory
away, or hoisting `upstream/runner.go` up to `//go/pkg/bumblebee`, would break
that seal — `runner.go` imports five `internal/` packages, and Go rejects that
import from outside the subtree. If you need to change the boundary, add a
wrapper in `//go/pkg/bumblebee` instead.

## Upgrading

Replace `upstream/` wholesale from the new upstream tag, then re-apply the
import-path rewrite (`github.com/carverauto/serviceradar/third_party/bumblebee/upstream`)
and update `VERSION.bumblebee` plus the pin above. Run
`bazel run //:gazelle` to regenerate the BUILD files.
