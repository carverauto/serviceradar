# Chart unit tests (`helm unittest`)

Run by `//helm/serviceradar:helm_unittest_suite_test`, so `bazel test //...` and
`make test` cover them. Locally:

```
helm unittest ./helm/serviceradar
```

New `*_test.yaml` files here are picked up automatically — the Bazel target globs the
directory and cross-checks the suite count helm-unittest reports against the files
present, so a suite cannot silently not-run.

## Four traps, all of which shipped broken

Until 2026-08, no CI job invoked `helm unittest` (the Helm Lint workflow runs `helm
lint`, which executes no assertions). 26 assertions across 10 suites were committed
having never once been run. Every one had been written by reading `helm template`
output, which differs from what the plugin sees:

1. **Document order.** `helm template` prints documents in Helm's kind-sorted install
   order; helm-unittest indexes them in raw template order. A `documentIndex` copied
   from `helm template` output addresses the wrong document. Prefer a
   `documentSelector` over an index — it also survives a listener or route being
   toggled off, which shifts every later index.

2. **Release namespace.** `helm template` defaults to `default`; helm-unittest's
   default is the literal `NAMESPACE`. Set it explicitly rather than asserting either
   default:

   ```yaml
   release:
     namespace: serviceradar-test
   ```

   Asserting a plausible-looking `default` is worse than useless: it passes against a
   template that hardcodes the string instead of using `.Release.Namespace`.

3. **Ambiguous `documentSelector`.** Several documents in one template routinely share
   `metadata.name` — `web.yaml` renders a ServiceAccount, a Service and a Deployment
   all named `serviceradar-web-ng`, and the job templates render four objects each.
   Selecting on the name yields `multiple indexes found`. Select on something unique
   within the template (usually `kind`) and scope the assert with `template:`.

4. **`failedTemplate` needs `template:`.** In a multi-template suite an unscoped assert
   is checked against every listed template. `fail` fires while rendering exactly one
   of them, so the others report `No failed document` and the assert fails even though
   the chart does reject the input. Scope it to the template that raises.

## Versions

The `unittest` plugin 0.7.2 is pinned in `//MODULE.bazel` and fetched by Bazel. The
Bazel target runs the plugin's `untt` binary directly rather than through
`helm unittest`: helm only execs it (`command: "$HELM_PLUGIN_DIR/untt"`), `untt` links
the Helm libraries itself, and get.helm.sh is not reachable from the BuildBuddy
runners. So the gate needs no helm binary, and its result does not depend on whichever
helm you have installed locally.
