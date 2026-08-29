# Flow Collector Multi-Pod Ingest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the flow collector run more than one replica, by moving the one-time `events` -> `flows` cutover into a Helm hook Job, making the pods stateless, and exposing the parser's hard exporter ceiling as config.

**Architecture:** The collector today is a control-plane singleton wearing a data-plane hat: it performs a JetStream stream create/update reconciled from durable markers on a ReadWriteOnce PVC. We keep the self-healing `ensure` in the pods but remove the *divergence* -- the markers move to a bootstrap Job, so every pod derives its subject list from config alone and concurrent ensures converge.

**Tech Stack:** Rust (tokio, async-nats, netflow_parser 1.0.6), Helm, NATS JetStream.

**Spec:** `docs/superpowers/specs/2026-08-28-flow-collector-multipod-design.md`

## Global Constraints

- Issue: carverauto/serviceradar#4107. Base branch: `staging`. Never push to `staging`.
- Docs under `docs/docs/` must be **ASCII only**.
- Rust: run `cargo fmt` and `cargo clippy --all-targets -- -D warnings` on touched crates.
- `netflow_parser` is pinned at workspace level (`Cargo.toml` `[workspace.dependencies]`). Do **not** add a version to `rust/flow-collector/Cargo.toml`.
- Full gate before PR: `make test` (this is the only command that covers the Elixir shards too).
- The `flows` stream's subject list must never lose a subject. Verify with `nats stream info flows` before and after any cluster step.
- Measured constraint, do not regress: pods get **one** Tokio worker under a 0.5 CPU quota, so per-pod parse throughput is single-threaded.
- **Prerequisite already merged, do not redo:** carverauto/serviceradar#4109 moved the template-store KV worker onto its own runtime and keeps that runtime driven while idle. Verify it is present before starting: `grep -c spawn_driven_worker rust/flow-collector/src/template_store.rs` must be > 0.
- Task 6 needs a **published** chart carrying the `$KV.flow_templates.>` NATS grant. No release up to 1.4.46 has it. Verify with `helm pull oci://registry.carverauto.dev/serviceradar/charts/serviceradar --version <X>` then grepping the extracted `templates/nats.yaml` for `flowTemplateBucket`.

---

### Task 1: `--bootstrap-stream` mode

Adds a mode that performs the stream ensure (including the crash-safe cutover) and exits, so a Helm hook Job can own it. Nothing else changes yet; the pods still ensure on startup exactly as they do today.

**Files:**
- Modify: `rust/flow-collector/src/main.rs` (Args struct, `main`)
- Modify: `rust/flow-collector/src/publisher.rs` (add `bootstrap_stream`)
- Test: `rust/flow-collector/src/publisher.rs` (`#[cfg(test)] mod tests`)

**Interfaces:**
- Consumes: `Config::from_file`, `Publisher::new(Arc<Config>, mpsc::Receiver<OutboundFlow>, Arc<HostSliceMetricsRegistry>)`.
- Produces: `Publisher::bootstrap_stream(config: Arc<Config>) -> anyhow::Result<()>`; CLI flag `--bootstrap-stream`.

- [ ] **Step 1: Write the failing test**

In `rust/flow-collector/src/publisher.rs`, inside `mod tests`:

```rust
    #[test]
    fn bootstrap_mode_is_reachable_without_a_listener_channel() {
        // bootstrap_stream must not require the publish channel that run()
        // consumes: the Job has no listeners. This asserts the constructor
        // path a Job uses compiles and builds a Publisher.
        let cfg = std::sync::Arc::new(test_config());
        let (_tx, rx) = tokio::sync::mpsc::channel(1);
        let publisher = Publisher::new(
            cfg,
            rx,
            std::sync::Arc::new(crate::metrics::HostSliceMetricsRegistry::new(vec![])),
        );
        assert!(publisher.pending_rehome.is_empty());
    }
```

If `test_config()` does not already exist in this module, add it, mirroring the `Config` literal used by `listener.rs` tests (all fields, `template_store: None`, `rehome_state_path: None`, `ready_state_path: None`).

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p serviceradar-flow-collector bootstrap_mode_is_reachable -- --nocapture`
Expected: FAIL to compile, `cannot find function test_config` or `no method named pending_rehome`.

- [ ] **Step 3: Add `bootstrap_stream` to `publisher.rs`**

Add as an `impl Publisher` method, next to `run`:

```rust
    /// Connect, ensure the owned stream (including any pending cutover), then
    /// return. Used by the Helm bootstrap Job so collector pods never have to
    /// own the durable cutover markers.
    ///
    /// This deliberately reuses `connect_with_retry`, which performs the same
    /// rehome/ownership recovery `run()` does. A second implementation of that
    /// state machine would have to be kept in behavioural parity by hand.
    pub async fn bootstrap_stream(config: std::sync::Arc<Config>) -> Result<()> {
        // The Job has no listeners, so nothing will ever send on this channel.
        let (_tx, rx) = mpsc::channel(1);
        let mut publisher = Publisher::new(
            config,
            rx,
            std::sync::Arc::new(HostSliceMetricsRegistry::new(vec![])),
        );
        let (_client, _admin_js, _publish_js, window) = publisher.connect_with_retry().await?;
        info!(
            "Bootstrap complete: stream '{}' ensured (dup_window={:?})",
            publisher.config.stream_name, window
        );
        Ok(())
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p serviceradar-flow-collector bootstrap_mode_is_reachable`
Expected: PASS.

- [ ] **Step 5: Wire the CLI flag in `main.rs`**

Extend `Args`:

```rust
struct Args {
    /// Path to configuration file
    #[arg(short, long, default_value = "flow-collector.json")]
    config: String,

    /// Ensure the JetStream stream (including any pending events->flows
    /// cutover) and exit. Used by the Helm bootstrap Job; no listeners are
    /// started and no UDP ports are bound.
    #[arg(long, default_value_t = false)]
    bootstrap_stream: bool,
}
```

Immediately after `let config = Arc::new(Config::from_file(&args.config)?);` and its logging block, insert:

```rust
    if args.bootstrap_stream {
        log::info!("Running in bootstrap-stream mode (no listeners will start)");
        Publisher::bootstrap_stream(Arc::clone(&config)).await?;
        log::info!("Bootstrap finished; exiting");
        return Ok(());
    }
```

- [ ] **Step 6: Verify the flag parses and short-circuits**

Run: `cargo run -p serviceradar-flow-collector -- --help`
Expected: output lists `--bootstrap-stream`.

Run: `cargo clippy -p serviceradar-flow-collector --all-targets -- -D warnings`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add rust/flow-collector/src/main.rs rust/flow-collector/src/publisher.rs
git commit -m "feat(flow-collector): add --bootstrap-stream mode for the Helm hook Job"
```

---

### Task 2: Helm bootstrap hook Job; PVC moves off the pods

Gives the Job the durable markers and the pods an `emptyDir`. After this task the pods still ensure the stream, but from config alone -- which is what makes concurrent ensures converge (measured: 8 identical concurrent stream adds all succeed; 2 divergent ones conflict).

**Files:**
- Create: `helm/serviceradar/templates/flow-collector-bootstrap-job.yaml`
- Modify: `helm/serviceradar/templates/flow-collector.yaml` (PVC guard, volumes)
- Test: `helm/serviceradar/tests/flow_collector_bootstrap_test.yaml`

**Interfaces:**
- Consumes: `--bootstrap-stream` from Task 1; existing `serviceradar.imageRef`, `serviceradar.imagePullSecrets`, `serviceradar.podSecurityContext` helpers.
- Produces: Job `serviceradar-flow-collector-bootstrap`; the Deployment's `/var/lib/serviceradar` is an `emptyDir`.

- [ ] **Step 1: Write the failing chart test**

Create `helm/serviceradar/tests/flow_collector_bootstrap_test.yaml`:

```yaml
suite: flow collector bootstrap job
templates:
  - flow-collector-bootstrap-job.yaml
tests:
  - it: runs the collector in bootstrap-stream mode as a pre-upgrade hook
    set:
      flowCollector.enabled: true
    asserts:
      - isKind:
          of: Job
      - equal:
          path: metadata.annotations["helm.sh/hook"]
          value: pre-install,pre-upgrade
      - equal:
          path: metadata.annotations["helm.sh/hook-delete-policy"]
          value: before-hook-creation
      - contains:
          path: spec.template.spec.containers[0].args
          content: "--bootstrap-stream"
  - it: is absent when the collector is disabled
    set:
      flowCollector.enabled: false
    asserts:
      - hasDocuments:
          count: 0
```

- [ ] **Step 2: Run it to verify it fails**

Run: `helm unittest ./helm/serviceradar -f 'tests/flow_collector_bootstrap_test.yaml'`
Expected: FAIL -- template `flow-collector-bootstrap-job.yaml` does not exist.

- [ ] **Step 3: Create the Job template**

Create `helm/serviceradar/templates/flow-collector-bootstrap-job.yaml`:

```yaml
{{- if .Values.flowCollector.enabled }}
{{- $data := default (dict) .Values.flowCollector.data -}}
{{- $dataEnabled := true -}}
{{- if hasKey $data "enabled" -}}
{{- $dataEnabled = $data.enabled -}}
{{- end -}}
apiVersion: batch/v1
kind: Job
metadata:
  name: serviceradar-flow-collector-bootstrap
  labels:
    app.kubernetes.io/part-of: serviceradar
    app.kubernetes.io/component: flow-collector-bootstrap
  annotations:
    # Runs before the Deployment is updated so the stream (and any pending
    # events->flows cutover) is settled by exactly one writer before any
    # collector pod starts. This is what allows replicaCount > 1.
    "helm.sh/hook": pre-install,pre-upgrade
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": before-hook-creation
spec:
  backoffLimit: 3
  template:
    metadata:
      labels:
        app: serviceradar-flow-collector-bootstrap
    spec:
      restartPolicy: Never
      {{- include "serviceradar.podSecurityContext" . | nindent 6 }}
      serviceAccountName: {{ .Values.spire.flowCollectorServiceAccount | default "serviceradar-flow-collector" }}
      {{- include "serviceradar.imagePullSecrets" . | nindent 6 }}
      containers:
      - name: bootstrap
        image: {{ include "serviceradar.imageRef" (dict "Values" .Values "Chart" .Chart "name" "serviceradar-flow-collector" "service" "flowCollector") }}
        imagePullPolicy: {{ include "serviceradar.imagePullPolicy" . }}
        args:
        - "--config"
        - "/etc/serviceradar/flow-collector.json"
        - "--bootstrap-stream"
        env:
        - name: RUST_LOG
          value: "info"
        volumeMounts:
        - name: flow-collector-config
          mountPath: /etc/serviceradar
        - name: cert-data
          mountPath: /etc/serviceradar/certs
          readOnly: true
        - name: nats-creds
          mountPath: /etc/serviceradar/creds
          readOnly: true
        - name: flow-collector-data
          mountPath: /var/lib/serviceradar
      volumes:
      - name: flow-collector-config
        configMap:
          name: serviceradar-flow-collector-config
      - name: cert-data
        secret:
          secretName: serviceradar-runtime-certs
      - name: nats-creds
        secret:
          secretName: serviceradar-nats-creds
      - name: flow-collector-data
      {{- if $dataEnabled }}
        persistentVolumeClaim:
          claimName: {{ $data.existingClaim | default "serviceradar-flow-collector-data" }}
      {{- else }}
        emptyDir: {}
      {{- end }}
{{- end }}
```

Before writing, open `helm/serviceradar/templates/flow-collector.yaml` and copy the **exact** `volumes:` block names for `cert-data` and `nats-creds` -- if the secret names there differ from the above, use the ones in that file.

- [ ] **Step 4: Run the chart test to verify it passes**

Run: `helm unittest ./helm/serviceradar -f 'tests/flow_collector_bootstrap_test.yaml'`
Expected: PASS, 2 tests.

- [ ] **Step 5: Give the Deployment an emptyDir instead of the PVC**

In `helm/serviceradar/templates/flow-collector.yaml`, find the Deployment's `flow-collector-data` volume and replace its `persistentVolumeClaim` with:

```yaml
      - name: flow-collector-data
        # Pod-local scratch, deliberately NOT the PVC. The ready marker and the
        # ownership inventory are per-pod and disposable; the durable cutover
        # markers belong to the bootstrap Job, which is the single writer.
        # Keeping the PVC here would also cap the Deployment at one replica,
        # since it is ReadWriteOnce.
        emptyDir: {}
```

Leave the PVC resource itself defined -- the Job still claims it.

- [ ] **Step 6: Verify the Deployment no longer mounts the PVC**

Run:
```bash
helm template t ./helm/serviceradar --set flowCollector.enabled=true \
  | awk '/kind: Deployment/,/^---/' | grep -A3 'flow-collector-data'
```
Expected: shows `emptyDir: {}`, no `persistentVolumeClaim`.

Run: `helm unittest ./helm/serviceradar` and record the pass/fail counts.
Expected: no *new* failures versus `origin/staging`. Compare by running the same command against a clean checkout: `git archive origin/staging helm/serviceradar | tar -x -C /tmp/base && helm unittest /tmp/base/helm/serviceradar`. Pre-existing failures are tracked separately and are not this task's concern.

- [ ] **Step 7: Commit**

```bash
git add helm/serviceradar/templates/flow-collector-bootstrap-job.yaml \
        helm/serviceradar/templates/flow-collector.yaml \
        helm/serviceradar/tests/flow_collector_bootstrap_test.yaml
git commit -m "feat(helm): run the flow-collector stream bootstrap in a pre-upgrade hook Job"
```

---

### Task 3: HTTP readiness probe

The ready-file probe cannot see a deadlocked-but-running process, and it exists only because there was no HTTP endpoint. There is one now.

**Files:**
- Modify: `helm/serviceradar/templates/flow-collector.yaml` (probes)
- Test: `helm/serviceradar/tests/flow_collector_probe_test.yaml`

**Interfaces:**
- Consumes: `run_prometheus_server` on `flowCollector.config.metrics_addr` (already shipped).
- Produces: no code interface.

- [ ] **Step 1: Write the failing chart test**

Create `helm/serviceradar/tests/flow_collector_probe_test.yaml`:

```yaml
suite: flow collector probes
templates:
  - flow-collector.yaml
tests:
  - it: uses an HTTP readiness probe when metrics are enabled
    set:
      flowCollector.enabled: true
      flowCollector.config.metrics_addr: "0.0.0.0:50046"
    documentSelector:
      path: kind
      value: Deployment
    asserts:
      - equal:
          path: spec.template.spec.containers[0].readinessProbe.httpGet.path
          value: /metrics
      - equal:
          path: spec.template.spec.containers[0].readinessProbe.httpGet.port
          value: 50046
  - it: falls back to the ready-file probe when metrics are off
    set:
      flowCollector.enabled: true
      flowCollector.config.metrics_addr: null
    documentSelector:
      path: kind
      value: Deployment
    asserts:
      - isNotNull:
          path: spec.template.spec.containers[0].readinessProbe.exec
```

- [ ] **Step 2: Run it to verify it fails**

Run: `helm unittest ./helm/serviceradar -f 'tests/flow_collector_probe_test.yaml'`
Expected: FAIL -- readinessProbe currently has `exec`, not `httpGet`.

- [ ] **Step 3: Gate the probes on metrics_addr**

In `helm/serviceradar/templates/flow-collector.yaml`, replace the `readinessProbe:` block with:

```yaml
        readinessProbe:
        {{- if (.Values.flowCollector.config).metrics_addr }}
          # HTTP beats the ready-file check: it also fails a process that is
          # running but wedged, which `test -f` cannot detect.
          httpGet:
            path: /metrics
            port: {{ .Values.flowCollector.service.ports.metrics.targetPort | default 50046 }}
          initialDelaySeconds: 5
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 12
        {{- else }}
          exec:
            command:
            - /bin/sh
            - -c
            - "test -f {{ .Values.flowCollector.readyPath | default "/var/lib/serviceradar/flow-collector.ready" }}"
          initialDelaySeconds: 5
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 12
        {{- end }}
```

- [ ] **Step 4: Run the chart test to verify it passes**

Run: `helm unittest ./helm/serviceradar -f 'tests/flow_collector_probe_test.yaml'`
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add helm/serviceradar/templates/flow-collector.yaml \
        helm/serviceradar/tests/flow_collector_probe_test.yaml
git commit -m "feat(helm): probe flow-collector readiness over HTTP when metrics are on"
```

---

### Task 4: Expose `max_sources`

`netflow_parser` caps tracked exporters at `DEFAULT_MAX_SOURCES = 10_000` and evicts past it (LRU). The collector never raises it. `max_templates` is unrelated -- it sizes the per-source *template* cache.

**Files:**
- Modify: `rust/flow-collector/src/config.rs` (`ListenerConfig::Netflow`)
- Modify: `rust/flow-collector/src/listener.rs` (`build_handler`)
- Modify: `rust/flow-collector/src/netflow/mod.rs` (`NetflowHandler::new`)
- Modify: `helm/serviceradar/values.yaml`
- Modify: `docs/docs/flow-collector-scaling.md`

**Interfaces:**
- Consumes: `AutoScopedParser::with_max_sources(usize) -> Result<Self, ConfigError>` (consuming builder, chained after `try_with_builder`).
- Produces: `NetflowHandler::new(max_templates, pending_flows, default_sampling_rate, sampling_rate_overrides, max_sources: Option<usize>, template_store, metrics)`.

- [ ] **Step 1: Write the failing config test**

In `rust/flow-collector/src/config.rs`, inside `mod tests`:

```rust
    #[test]
    fn netflow_listener_accepts_max_sources() {
        let json = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "flows",
            "listeners": [{
                "protocol": "netflow",
                "listen_addr": "0.0.0.0:2055",
                "subject": "flows.raw.netflow",
                "max_sources": 25000
            }]
        }"#;
        let cfg: Config = serde_json::from_str(json).expect("config should parse");
        match &cfg.listeners[0] {
            ListenerConfig::Netflow { max_sources, .. } => {
                assert_eq!(*max_sources, Some(25_000));
            }
            other => panic!("expected netflow listener, got {other:?}"),
        }
    }

    #[test]
    fn netflow_max_sources_defaults_to_none() {
        let json = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "flows",
            "listeners": [{
                "protocol": "netflow",
                "listen_addr": "0.0.0.0:2055",
                "subject": "flows.raw.netflow"
            }]
        }"#;
        let cfg: Config = serde_json::from_str(json).expect("config should parse");
        match &cfg.listeners[0] {
            // None means "leave the library default of 10_000 alone".
            ListenerConfig::Netflow { max_sources, .. } => assert_eq!(*max_sources, None),
            other => panic!("expected netflow listener, got {other:?}"),
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p serviceradar-flow-collector max_sources`
Expected: FAIL to compile -- no field `max_sources`.

- [ ] **Step 3: Add the config field**

In `ListenerConfig::Netflow`, after `sampling_rate_overrides`:

```rust
        /// Maximum distinct exporters tracked by the parser for this listener.
        ///
        /// `netflow_parser` defaults to 10,000 and *evicts* past that (LRU),
        /// which silently degrades a fleet larger than the cap into constant
        /// eviction churn. Leaving this unset keeps the library default.
        /// Raising it costs memory proportional to the number of exporters.
        #[serde(default)]
        max_sources: Option<usize>,
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p serviceradar-flow-collector max_sources`
Expected: PASS, 2 tests.

- [ ] **Step 5: Plumb it to the parser**

In `rust/flow-collector/src/netflow/mod.rs`, add a `max_sources: Option<usize>` parameter to `NetflowHandler::new` (place it immediately before `template_store`), and after `AutoScopedParser::try_with_builder(builder)` succeeds:

```rust
        let parser = if let Some(max) = max_sources {
            parser
                .with_max_sources(max)
                .expect("max_sources must be non-zero")
        } else {
            parser
        };
```

In `rust/flow-collector/src/listener.rs`, destructure `max_sources` in the `ListenerConfig::Netflow` arm of `build_handler` and pass `*max_sources` in the matching position.

- [ ] **Step 6: Verify the whole crate builds and tests pass**

Run: `cargo test -p serviceradar-flow-collector`
Expected: PASS, no failures.

Run: `cargo clippy -p serviceradar-flow-collector --all-targets -- -D warnings`
Expected: clean.

- [ ] **Step 7: Document it**

In `helm/serviceradar/values.yaml`, in the netflow listener entry under `flowCollector.config.listeners`, add:

```yaml
        # Distinct exporters this listener tracks. netflow_parser defaults to
        # 10000 and evicts past it, so a larger fleet thrashes. Unset = library
        # default. Watch flow_collector_sources against this number.
        max_sources: 10000
```

In `docs/docs/flow-collector-scaling.md`, in the configuration table, add a row (ASCII only):

```
| `listeners[].max_sources` | library default `10000` | Distinct exporters tracked per listener; evicts (LRU) past the cap | Raise when `flow_collector_sources` approaches it |
```

- [ ] **Step 8: Commit**

```bash
git add rust/flow-collector/src/config.rs rust/flow-collector/src/listener.rs \
        rust/flow-collector/src/netflow/mod.rs helm/serviceradar/values.yaml \
        docs/docs/flow-collector-scaling.md
git commit -m "feat(flow-collector): make the parser's exporter ceiling configurable"
```

---

### Task 5: Allow replicas

**Files:**
- Modify: `helm/serviceradar/templates/flow-collector.yaml` (strategy, affinity)
- Modify: `docs/docs/flow-collector-scaling.md`
- Test: `helm/serviceradar/tests/flow_collector_replicas_test.yaml`

**Interfaces:**
- Consumes: Tasks 1-3 (bootstrap Job owns the markers; pods are stateless).
- Produces: no code interface.

- [ ] **Step 1: Write the failing chart test**

Create `helm/serviceradar/tests/flow_collector_replicas_test.yaml`:

```yaml
suite: flow collector replicas
templates:
  - flow-collector.yaml
tests:
  - it: rolls updates and spreads replicas once stateless
    set:
      flowCollector.enabled: true
      flowCollector.replicaCount: 3
    documentSelector:
      path: kind
      value: Deployment
    asserts:
      - equal:
          path: spec.replicas
          value: 3
      - equal:
          path: spec.strategy.type
          value: RollingUpdate
      - isNotNull:
          path: spec.template.spec.affinity.podAntiAffinity
```

- [ ] **Step 2: Run it to verify it fails**

Run: `helm unittest ./helm/serviceradar -f 'tests/flow_collector_replicas_test.yaml'`
Expected: FAIL -- strategy is `Recreate` and there is no `podAntiAffinity`.

- [ ] **Step 3: Switch the strategy and add anti-affinity**

Replace the `strategy:` block in the Deployment:

```yaml
  # RollingUpdate is safe now that the events->flows cutover runs in the
  # pre-upgrade bootstrap Job: no pod performs a subject rehome, and every pod
  # derives its subject list from config alone, so concurrent stream ensures
  # converge rather than race. (Measured: 8 concurrent identical stream adds
  # all succeed; 2 divergent ones conflict.)
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
```

Add to the pod spec, as a sibling of `serviceAccountName`:

```yaml
      affinity:
        podAntiAffinity:
          # Soft, not required: spreading replicas across nodes is what makes
          # BGP/ECMP hand different exporters to different pods. Left soft so a
          # small cluster can still schedule every replica.
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              topologyKey: kubernetes.io/hostname
              labelSelector:
                matchLabels:
                  app: serviceradar-flow-collector
```

- [ ] **Step 4: Run the chart test to verify it passes**

Run: `helm unittest ./helm/serviceradar -f 'tests/flow_collector_replicas_test.yaml'`
Expected: PASS.

- [ ] **Step 5: Document the capacity model**

In `docs/docs/flow-collector-scaling.md`, replace the "Why single-replica today" section with a "Capacity model" section stating (ASCII only): the bootstrap Job is the single writer of stream ownership; pods are stateless and may scale; exporters distribute by ECMP hash plus ClientIP affinity, which is uneven, so replicas are sized for headroom against imbalance rather than an exact per-pod source count; each pod is limited to one Tokio worker under a 0.5 CPU quota, so raising the CPU limit and raising replicas are different levers.

- [ ] **Step 6: Full gate**

Run: `make test`
Expected: exit 0. Record the reported test count.

- [ ] **Step 7: Commit**

```bash
git add helm/serviceradar/templates/flow-collector.yaml \
        helm/serviceradar/tests/flow_collector_replicas_test.yaml \
        docs/docs/flow-collector-scaling.md
git commit -m "feat(helm): allow flow-collector replicas with rolling updates"
```

---

### Task 6: Cluster verification on farm01

Chart tests cannot prove the cutover still works or that replicas coexist. This task is manual and must run against a cluster.

**Files:** none (verification only).

**Interfaces:** Consumes everything above.

- [ ] **Step 1: Record the pre-state**

The authenticated `nats` CLI lives in the tools pod, pre-configured from env (pass **no** `--server`/`--tls*` flags -- they are already set and will error as "cannot be repeated"):

```bash
export KUBECONFIG=~/.kube/farm01.yaml
POD=$(kubectl -n serviceradar get pod -l app=serviceradar-tools -o jsonpath='{.items[0].metadata.name}')
kubectl -n serviceradar exec $POD -c tools -- nats stream info flows -j > /tmp/flows-before.json
kubectl -n serviceradar exec $POD -c tools -- nats stream ls -n
```

Record the `flows` subject list. It must be identical afterwards.

- [ ] **Step 2: Deploy and confirm the Job ran exactly once**

Deploy per `~/src/gitops/clusters/farm01/serviceradar/values.yaml`. farm01 is **not** ArgoCD-managed; it is a manual `helm upgrade`, and the chart must be a published release containing the `$KV.flow_templates.>` grant.

```bash
kubectl -n serviceradar get jobs -l app.kubernetes.io/component=flow-collector-bootstrap
kubectl -n serviceradar logs job/serviceradar-flow-collector-bootstrap | tail -20
```
Expected: one Job, `Completions 1/1`, log line `Bootstrap complete: stream 'flows' ensured`.

- [ ] **Step 3: Confirm the stream is unchanged**

```bash
kubectl -n serviceradar exec $POD -c tools -- nats stream info flows -j > /tmp/flows-after.json
diff <(python3 -c "import json;print(sorted(json.load(open('/tmp/flows-before.json'))['config']['subjects']))") \
     <(python3 -c "import json;print(sorted(json.load(open('/tmp/flows-after.json'))['config']['subjects']))")
```
Expected: no output. **Any diff is a failure** -- stop and investigate before scaling.

- [ ] **Step 4: Scale to 3 and confirm no pod performs a stream write**

```bash
kubectl -n serviceradar scale deploy/serviceradar-flow-collector --replicas=3
kubectl -n serviceradar rollout status deploy/serviceradar-flow-collector --timeout=180s
kubectl -n serviceradar logs -l app=serviceradar-flow-collector --tail=200 | grep -ciE "rehome|detach|cutover"
```
Expected: `0`. A non-zero count means a pod is still performing cutover work and the Job split is incomplete.

- [ ] **Step 5: Confirm every pod is receiving traffic and none is starved**

```bash
for ip in $(kubectl -n serviceradar get pods -l app=serviceradar-flow-collector -o jsonpath='{.items[*].status.podIP}'); do
  echo "--- $ip ---"
  kubectl -n serviceradar exec deploy/serviceradar-tools -c tools -- \
    curl -s -m 10 http://$ip:50046/metrics | grep -E 'packets_received_total\{protocol="netflow"|_sources\{|backend_errors_total\{protocol="netflow"'
done
```
Expected: `packets_received` increasing on at least one pod, `template_store_backend_errors_total` **flat** across two samples 60s apart (the absolute value is a monotonic counter and reflects past outages, so compare samples rather than reading it once).

- [ ] **Step 6: Confirm no UDP loss**

```bash
POD1=$(kubectl -n serviceradar get pod -l app=serviceradar-flow-collector -o jsonpath='{.items[0].metadata.name}')
kubectl -n serviceradar exec $POD1 -- sh -c 'head -1 /proc/net/udp; grep -E ":0807|:18C7" /proc/net/udp'
```
Expected: `rx_queue` `00000000` and the final `drops` column `0` for both ports (`0807`=2055, `18C7`=6343).

- [ ] **Step 7: Restore replicas and record the result**

```bash
kubectl -n serviceradar scale deploy/serviceradar-flow-collector --replicas=1
```

Record the observed numbers in the PR description. Do not claim the scale test passed without pasting the per-pod metrics from Step 5.
