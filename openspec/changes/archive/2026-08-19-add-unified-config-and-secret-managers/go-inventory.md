# Go environment inventory, substitution plan and migration plan

Companion to `elixir-inventory.md`, produced with the same method so the two are
comparable. Scope: every `.go` file in the repository outside `vendor/` -- 1044 files,
which includes `go/`, `build/`, `tools/` and the Go test files under `docker/` and
`rust/`.

## 1. Method, and what is different about Go

Four read forms are counted:

| form | note |
|---|---|
| `os.Getenv("NAME")` / `os.LookupEnv("NAME")` | -- |
| `os.Getenv(nameConst)` where `nameConst = "NAME"` | resolved through a per-package constant map |
| `helper("NAME", default)` for 20 verified wrappers | `getEnvOrDefault`, `envInt`, `parseBoolEnv`, `requiredEnv`, ... |
| `os.Getenv(v)` with a non-constant `v` | unresolvable; counted separately |

Go differs from Elixir in three ways that matter more than the totals.

**Constant indirection is resolvable, so the blind spot is small.** Go names the
variable in a `const` and passes the constant, which a scan can follow. Of the 23
unresolvable reads, 21 are the bodies of the wrapper helpers themselves -- they take
the name as a parameter, and every caller passes a literal that is already counted.
Only two are genuinely opaque: [go/pkg/config/env_loader.go:159](go/pkg/config/env_loader.go#L159)
and [go/pkg/agent/remoteaccess/enhanced_recording_platform_linux.go:78](go/pkg/agent/remoteaccess/enhanced_recording_platform_linux.go#L78).
Elixir had 91 such reads across 40 files.

**`os.Getenv` cannot distinguish unset from empty, and nothing here uses the form that
can.** `os.Getenv` returns `""` for both. `os.LookupEnv` returns `(value, ok)` and is
the only way to tell the difference. Across all 169 names read with a literal, the
count of `os.LookupEnv` call sites is:

| form | call sites |
|---|---|
| `os.Getenv` | 145 |
| helper wrapper (which itself calls `os.Getenv`) | 78 |
| `os.LookupEnv` | **0** |

There are exactly two `os.LookupEnv` calls in the tree. One is in a `.env` file loader
deciding whether to override an already-set variable
([go/cmd/tools/armis-api-probe/main.go:633](go/cmd/tools/armis-api-probe/main.go#L633)).
The other is [config/manager_config/go/selector.go:135](config/manager_config/go/selector.go#L135),
reading `SERVICERADAR_ENV` -- the variable this change introduced. The one name added
by the new design is the only one in the Go tree read in a way that can tell an unset
variable from an empty one.

**There is a second, reflection-driven configuration path.**
[go/pkg/config/env_loader.go](go/pkg/config/env_loader.go) builds environment variable
names at runtime from JSON struct tags (`buildEnvName` upper-cases the tag and prefixes
it, default prefix `SERVICERADAR_`), and also accepts an entire configuration document
through `SERVICERADAR_CONFIG_JSON`. No name appears in the source, so no scan can
enumerate what it reads. It activates only when `CONFIG_SOURCE=env`, and every chart
that sets `CONFIG_SOURCE` sets it to `file`
([helm/serviceradar/templates/_helpers.tpl:196](helm/serviceradar/templates/_helpers.tpl#L196),
[helm/serviceradar/templates/dev/faker.yaml:79](helm/serviceradar/templates/dev/faker.yaml#L79)).
It is dead in deployment and live in code: one variable turns every JSON tag of every
config struct into an environment override. Task 8 should delete it rather than migrate
it -- an unbounded, unnameable surface cannot be brought under a schema.

## 2. Totals

| measure | Go | Elixir, for comparison |
|---|---|---|
| read sites | **246** | 1173 |
| ... resolvable to a literal name | 223 | 1082 |
| ... name computed at runtime | 23 | 91 |
| write sites (`Setenv` / `Unsetenv`) | 31 | 131 |
| distinct names | **173** | 676 |

**The Go surface is roughly a quarter the size of the Elixir one.**

| category | names | read sites |
|---|---|---|
| secret | 20 | 26 |
| material | 11 | 17 |
| schema | 8 | 10 |
| config | 130 | 156 |
| platform | 4 | 14 |

### 2.1 Most of it is not in a shipped service

| tree | read sites | distinct names |
|---|---|---|
| service libraries | 94 | 74 |
| tests | 79 | 54 |
| build tooling | 50 | 31 |
| service binaries | 22 | 18 |
| new ConfigManager | 1 | 1 |

**91 names are read by a shipped service. 77 are read only by build
tooling or tests**, and those do not belong under ConfigManager at all -- a release
script reading `GITHUB_TOKEN` and a live-integration test reading
`UNIFI_PROTECT_LIVE_HOST` are not deployment configuration. Scoping the Go work to the
service trees makes it 91 names, not 173.

Of those 91, 11 are credentials:

- `ARMIS_SECRET_KEY`
- `CORE_CA_FILE`
- `CORE_CERT_DIR`
- `CORE_CERT_FILE`
- `CORE_KEY_FILE`
- `NATS_CACERTFILE`
- `NATS_CERTFILE`
- `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY`
- `SERVICERADAR_ARMIS_API_SECRET`
- `SERVICERADAR_ONBOARDING_TOKEN_PRIVATE_KEY`
- `SERVICERADAR_ONBOARDING_TOKEN_PUBLIC_KEY`

## 3. Where these values come from

| mechanism | names it actually sets |
|---|---|
| helm | 41 |
| scripts | 19 |
| docker | 4 |
| ci-legacy | 1 |
| bazel-ci | 1 |
| **nothing in this repository** | **107** |

Same rule as the Elixir pass: only real assignments count. Helm again dominates, and
Bazel sets one.

### 3.1 What happens when a never-set variable is absent

Measured at every read site of the 104 never-set names that have one:

| behaviour when absent | names |
|---|---|
| the process exits or the test skips | 13 |
| an error is returned | 7 |
| a literal default in the source is used | 19 |
| an emptiness check turns the feature off | 32 |
| the empty string flows on unchecked | 33 |

**20 of 104 fail loudly** -- better than Elixir, where 6 of 346 did. The
difference is that Go's tooling and integration tests deliberately refuse to run
unconfigured (`requiredEnv` in
[go/cmd/tools/armis-northbound-smoke/main.go:87](go/cmd/tools/armis-northbound-smoke/main.go#L87),
`t.Skip` in the live tests), and the signing tools check their key before using it
([build/native_addons/addon_artifact_signature_tool.go:195](build/native_addons/addon_artifact_signature_tool.go#L195)).

The remaining 84 do not. `33` names let the empty string through with no check
at all, which in Go is indistinguishable from an operator deliberately setting the
variable to empty.

## 4. Similarity

### 4.1 Inside Go: proven by usage

Same test as the Elixir pass -- a value read as `Getenv(A)`, then `if == ""` and
`Getenv(B)`, or passed together to `firstEnv(A, B, ...)`, is one value with two
spellings. Six groups, all of them a vendor rename or a scope prefix:

| group | spellings | evidence |
|---|---|---|
| OpenBao/Vault address | `BAO_ADDR`, `OPENBAO_ADDR`, `VAULT_ADDR` | [build/wasm_plugins/upload_signature_tool.go:559](build/wasm_plugins/upload_signature_tool.go#L559) |
| OpenBao/Vault token | `BAO_TOKEN`, `VAULT_TOKEN` | [build/wasm_plugins/upload_signature_tool.go:558](build/wasm_plugins/upload_signature_tool.go#L558) |
| OpenBao/Vault CA | `BAO_CACERT`, `OPENBAO_CACERT`, `VAULT_CACERT` | [build/wasm_plugins/upload_signature_tool.go:596](build/wasm_plugins/upload_signature_tool.go#L596) |
| Armis endpoint | `ARMIS_API_URL`, `ARMIS_ENDPOINT`, `SERVICERADAR_ARMIS_API_URL` | [go/cmd/tools/armis-api-probe/main.go:279](go/cmd/tools/armis-api-probe/main.go#L279) |
| Armis secret | `ARMIS_API_SECRET`, `ARMIS_SECRET_KEY`, `SERVICERADAR_ARMIS_API_SECRET` | [go/cmd/tools/armis-api-probe/main.go:300](go/cmd/tools/armis-api-probe/main.go#L300) |
| Bazel test root | `TEST_SRCDIR`, `TEST_WORKSPACE` | [go/pkg/agent/addon/manager_test.go:69](go/pkg/agent/addon/manager_test.go#L69) |

Three names for one Armis secret and three for one OpenBao address is the same disease
as the Elixir `SERVICERADAR_TEST_DATABASE_*` / `SRQL_TEST_DATABASE_*` split, at smaller
scale.

### 4.2 Across Go and Elixir: the more interesting comparison

**18 names are read by both languages.** Those are the ones a schema field would
obviously unify:

| name | Go reads | Elixir reads |
|---|---|---|
| `CORE_ADDRESS` | 1 | 1 |
| `GH_TOKEN` | 1 | 2 |
| `GITHUB_TOKEN` | 1 | 3 |
| `NATS_SERVER_NAME` | 2 | 3 |
| `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY` | 3 | 2 |
| `SERVICERADAR_ARMIS_API_SECRET` | 1 | 1 |
| `SERVICERADAR_ARMIS_API_URL` | 1 | 1 |
| `SERVICERADAR_ARMIS_CUSTOM_FIELD` | 1 | 1 |
| `SERVICERADAR_ARMIS_DEVICE_IP` | 1 | 1 |
| `SERVICERADAR_ARMIS_NORTHBOUND_VALUE` | 1 | 1 |
| `SERVICERADAR_ARMIS_SEARCH_AQL` | 1 | 1 |
| `SERVICERADAR_ARMIS_SEARCH_MAX_PAGES` | 1 | 1 |
| `SERVICERADAR_LARGE_INGESTION_DEVICE_COUNT` | 1 | 1 |
| `SERVICERADAR_ONBOARDING_TOKEN_PRIVATE_KEY` | 1 | 1 |
| `SERVICERADAR_ONBOARDING_TOKEN_PUBLIC_KEY` | 2 | 1 |
| `SERVICERADAR_PROXMOX_API_TOKEN` | 1 | 1 |
| `SERVICERADAR_PROXMOX_TIMEOUT_MS` | 1 | 1 |
| `VAULT_TOKEN` | 2 | 2 |

**Then there are the values both languages read under different names.** This is the
failure the schema was written to end, and it is worth reading the NATS family in full,
because it is not a near-miss -- the two trees genuinely do not share a vocabulary:

| concept | Go reads | Elixir reads | Helm sets |
|---|---|---|---|
| NATS endpoint | `NATS_HOSTPORT` | `NATS_URL`, `SERVICERADAR_NATS_URL`, `AGENT_GATEWAY_NATS_URL`, `EVENT_WRITER_NATS_URL` | both `NATS_HOSTPORT` and `NATS_URL` |
| NATS CA bundle | `NATS_CACERTFILE` | -- (uses a cert directory) | `NATS_CACERTFILE` |
| NATS client cert | `NATS_CERTFILE` | `NATS_CERT_NAME` (a name, not a path) | `NATS_CERTFILE`, `NATS_CERT_NAME` |
| NATS credentials file | `NATS_CREDSFILE` | `NATS_CREDS_FILE` | `NATS_CREDS_FILE` |
| log level | `LOG_LEVEL` | `SERVICERADAR_LOG_LEVEL` | both |
| security mode | `CORE_SEC_MODE` | `SERVICERADAR_SECURITY_MODE` | both |

`NATS_CREDSFILE` deserves a sentence of its own. Two shipped services read it --
[go/pkg/k8sinventory/config.go:81](go/pkg/k8sinventory/config.go#L81) and
[go/pkg/trivysidecar/config.go:63](go/pkg/trivysidecar/config.go#L63) -- and **nothing in
this repository sets that spelling**. Helm sets `NATS_CREDS_FILE`, with the underscore,
which is what Elixir reads. This is not currently an outage: both charts configure those
two workloads with mTLS (`NATS_CACERTFILE` / `NATS_CERTFILE` / `NATS_KEYFILE`) and set no
credentials file under either spelling
([helm/serviceradar/templates/k8s-inventory.yaml:112-123](helm/serviceradar/templates/k8s-inventory.yaml#L112-L123)).
It is a trap rather than a fault: an operator who needed credentials auth there would set
the spelling the rest of the system uses, and nothing would happen, silently, because
`os.Getenv` returns `""` and the code treats that as "no credentials configured".

## 5. Partitioning

The same measurement as the Elixir document, and the answer is stronger here:

| consumer file reads N partitions | files |
|---|---|
| 1 | 45 |
| 2 | 7 |
| 3 | 6 |
| 4 | 2 |
| 5 | 2 |

**45 of 62 consumer files read exactly one partition**, and the widest reader
touches five. Go has no equivalent of the four `runtime.exs` hubs, because Go services
already read their configuration from a JSON file through
[go/pkg/config](go/pkg/config) and use the environment only for the handful of values
that must be set before the file is located. Per-partition managers fit this tree with
no restructuring.

| partition | names | credentials | read sites | consumer files | set somewhere | covers |
|---|---|---|---|---|---|---|
| `integrations` | 42 | 10 | 45 | 8 | 1 | Armis, OTX, UniFi, Proxmox, GitHub/Forgejo, SNMP |
| `edge` | 36 | 8 | 43 | 21 | 14 | agent, gateway, sweep, remote access, camera, add-on binaries |
| `observability` | 27 | 0 | 27 | 7 | 18 | log level, OTel, metrics addresses, Trivy, k8s inventory |
| `messaging` | 13 | 2 | 21 | 6 | 8 | NATS endpoints, TLS material, stream and subject names |
| `platform` | 8 | 0 | 19 | 13 | 2 | toolchain and OS -- NOT ServiceRadar configuration |
| `plugins` | 11 | 5 | 18 | 5 | 3 | WASM plugin paths, upload signing |
| `identity` | 14 | 4 | 15 | 6 | 7 | SPIFFE, core/KV endpoints and transport security, gRPC limits |
| `testing` | 4 | 0 | 12 | 10 | 2 | fixture selection and live-test gating |
| `release` | 5 | 0 | 6 | 5 | 1 | publish mode, commit SHA, multiarch index checks |
| `secrets_infra` | 4 | 2 | 6 | 2 | 4 | OpenBao/Vault address, token, CA |
| `config_system` | 4 | 0 | 4 | 3 | 2 | the loader's own switches -- see 1 |
| `kubernetes` | 2 | 0 | 4 | 4 | 0 | in-cluster detection, kubeconfig |
| `database` | 3 | 0 | 3 | 5 | 1 | migration toggle, e2e DSN, cluster id |

The partition names are deliberately the same as the Elixir document's where the concept
is the same (`database`, `messaging`, `identity`, `edge`, `plugins`, `integrations`,
`observability`, `secrets_infra`, `testing`). A partition is a schema message shared by
all three languages; two languages needing different fields of it is normal, two
languages needing different partitions for one concept is a modelling error.

## 6. Full inventory and substitution plan

Every distinct name. Columns as in `elixir-inventory.md`, plus **tree** (where it is
read: a shipped service, build tooling, or a test) and **absent** (what happens when it
is not set -- blank when something in the repository does set it).


### 6.1 `integrations` -- 42 names, 10 credentials, 45 read sites

| variable | R/W | kind | tree | destination | set by | absent |
|---|---|---|---|---|---|---|
| `ARMIS_ENDPOINT` <br> _alias of `SERVICERADAR_ARMIS_API_URL`_ | 1/0 | config | service | `integrations.api_url` | - | empty string |
| `ARMIS_MANAGED_AQL` | 1/0 | config | service | `integrations.managed_aql` | - | empty string |
| `ARMIS_SECRET_KEY` <br> _alias of `SERVICERADAR_ARMIS_API_SECRET`_ | 1/0 | secret | service | secret: `integrations.api_secret` | - | empty string |
| `ARMIS_UNMANAGED_AQL` | 1/0 | config | service | `integrations.unmanaged_aql` | - | empty string |
| `ARMIS_VENDOR_ID` | 1/0 | config | service | `integrations.vendor_id` | - | empty string |
| `FORGEJO_TOKEN` | 1/0 | secret | build | secret: `integrations.forgejo_token` | scripts | - |
| `FORGEJO_URL` | 1/0 | config | build | `integrations.forgejo_url` | - | empty string |
| `GH_TOKEN` | 1/0 | secret | build | secret: `integrations.gh_token` | - | empty string |
| `GITEA_TOKEN` | 1/0 | secret | build | secret: `integrations.gitea_token` | - | empty string |
| `GITHUB_API_URL` | 1/0 | config | build | `integrations.github_api_url` | - | empty string |
| `GITHUB_SHA` | 1/0 | config | build | `integrations.github_sha` | - | empty string |
| `GITHUB_TOKEN` | 1/0 | secret | build | secret: `integrations.github_token` | - | empty string |
| `OTX_RESPONSE_FIXTURE` | 3/0 | config | test | `integrations.response_fixture` | - | exits |
| `OTX_WASM_PATH` | 1/0 | config | test | `integrations.wasm_path` | - | exits |
| `SERVICERADAR_ARMIS_API_SECRET` | 1/0 | secret | service | secret: `integrations.api_secret` | - | exits |
| `SERVICERADAR_ARMIS_API_URL` | 1/0 | config | service | `integrations.api_url` | - | exits |
| `SERVICERADAR_ARMIS_CUSTOM_FIELD` | 1/0 | config | service | `integrations.custom_field` | - | exits |
| `SERVICERADAR_ARMIS_DEVICE_IP` | 1/0 | config | service | `integrations.device_ip` | - | exits |
| `SERVICERADAR_ARMIS_NORTHBOUND_VALUE` | 1/0 | config | service | `integrations.northbound_value` | - | empty string |
| `SERVICERADAR_ARMIS_SEARCH_AQL` | 1/0 | config | service | `integrations.search_aql` | - | default |
| `SERVICERADAR_ARMIS_SEARCH_MAX_PAGES` | 1/0 | config | service | `integrations.search_max_pages` | - | default |
| `SERVICERADAR_PROXMOX_API_TOKEN` | 1/0 | secret | test | secret: `integrations.api_token` | - | feature off |
| `SERVICERADAR_PROXMOX_TIMEOUT_MS` | 1/0 | config | test | `integrations.timeout_ms` | - | default |
| `SERVICERADAR_PROXMOX_TOKEN_ID` | 1/0 | config | test | `integrations.token_id` | - | feature off |
| `SERVICERADAR_PROXMOX_TOKEN_SECRET` | 1/0 | secret | test | secret: `integrations.token_secret` | - | feature off |
| `SERVICERADAR_PROXMOX_URL` | 1/0 | config | test | `integrations.url` | - | feature off |
| `SERVICERADAR_TEST_SNMP_TARGET` | 1/0 | config | test | `integrations.test_snmp_target` | - | exits |
| `UNIFI_PROTECT_LIVE_API_KEY` | 1/0 | secret | test | secret: `integrations.live_api_key` | - | empty string |
| `UNIFI_PROTECT_LIVE_BOOTSTRAP_PATH` | 1/0 | config | test | `integrations.live_bootstrap_path` | - | default |
| `UNIFI_PROTECT_LIVE_CAMERA_SOURCE_ID` | 1/0 | config | test | `integrations.live_camera_source_id` | - | feature off |
| `UNIFI_PROTECT_LIVE_COLLECT_EVENTS` | 1/0 | config | test | `integrations.live_collect_events` | - | empty string |
| `UNIFI_PROTECT_LIVE_COOKIE` | 1/0 | config | test | `integrations.live_cookie` | - | empty string |
| `UNIFI_PROTECT_LIVE_EVENT_SOURCES` | 1/0 | config | test | `integrations.live_event_sources` | - | default |
| `UNIFI_PROTECT_LIVE_HOST` | 1/0 | config | test | `integrations.live_host` | - | exits |
| `UNIFI_PROTECT_LIVE_INSECURE` | 2/0 | config | test | `integrations.live_insecure` | - | empty string |
| `UNIFI_PROTECT_LIVE_LOGIN_PATH` | 1/0 | config | test | `integrations.live_login_path` | - | default |
| `UNIFI_PROTECT_LIVE_PASSWORD` | 1/0 | secret | test | secret: `integrations.live_password` | - | empty string |
| `UNIFI_PROTECT_LIVE_RTSP_PORT` | 1/0 | config | test | `integrations.live_rtsp_port` | - | default |
| `UNIFI_PROTECT_LIVE_SCHEME` | 1/0 | config | test | `integrations.live_scheme` | - | default |
| `UNIFI_PROTECT_LIVE_STREAM_PROFILE_ID` | 1/0 | config | test | `integrations.live_stream_profile_id` | - | feature off |
| `UNIFI_PROTECT_LIVE_TIMEOUT` | 1/0 | config | test | `integrations.live_timeout` | - | default |
| `UNIFI_PROTECT_LIVE_USERNAME` | 1/0 | config | test | `integrations.live_username` | - | empty string |

### 6.2 `edge` -- 36 names, 8 credentials, 43 read sites

| variable | R/W | kind | tree | destination | set by | absent |
|---|---|---|---|---|---|---|
| `ADDON_TEST_CGROUP_PARENT` | 1/0 | config | test | `edge.addon_test_cgroup_parent` | - | exits |
| `SENDMMSG_BATCH_SIZE` | 1/0 | config | service | `edge.sendmmsg_batch_size` | - | feature off |
| `SERVICERADAR_AGENT_EBPF_ALLOW_MISSING_BTF` | 1/0 | config | test | `edge.ebpf_allow_missing_btf` | - | feature off |
| `SERVICERADAR_AGENT_EBPF_ALLOW_MISSING_CGROUP` | 1/0 | config | test | `edge.ebpf_allow_missing_cgroup` | - | feature off |
| `SERVICERADAR_AGENT_EBPF_BPFFS_PATH` | 2/0 | config | service+test | `edge.ebpf_bpffs_path` | helm | - |
| `SERVICERADAR_AGENT_EBPF_BTF_PATH` | 2/0 | config | service+test | `edge.ebpf_btf_path` | helm | - |
| `SERVICERADAR_AGENT_EBPF_CGROUP_PATH` | 2/0 | config | service+test | `edge.ebpf_cgroup_path` | helm | - |
| `SERVICERADAR_AGENT_EBPF_INTEGRATION` | 1/0 | config | test | `edge.ebpf_integration` | scripts | - |
| `SERVICERADAR_AGENT_PPROF_ADDR` | 1/0 | config | service | `edge.pprof_addr` | - | feature off |
| `SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY` | 3/0 | secret | build | secret: `edge.release_private_key` | - | errors |
| `SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY_FILE` | 2/0 | secret | build | secret: `edge.release_private_key_file` | - | feature off |
| `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY` | 3/2 | material | build+service+test | secret: `edge.release_public_key` | ci-legacy,helm | - |
| `SERVICERADAR_AGENT_RUNTIME_ROOT` | 0/1 | config | test | `edge.runtime_root` | helm | - |
| `SERVICERADAR_AGENT_SEED_BINARY` | 0/1 | secret | test | secret: `edge.seed_binary` | - | - |
| `SERVICERADAR_AGENT_UPDATER` | 0/1 | config | test | `edge.updater` | - | - |
| `SERVICERADAR_BUILD_RUST_ADDON` | 1/0 | config | test | `edge.build_rust_addon` | - | feature off |
| `SERVICERADAR_CAMERA_GATEWAY_ADDR` | 1/0 | config | test | `edge.camera_gateway_addr` | - | exits |
| `SERVICERADAR_CAMERA_GATEWAY_CERT_DIR` | 1/0 | material | test | secret: `edge.camera_gateway_cert_dir` | - | exits |
| `SERVICERADAR_NETPROBE_BIN` | 1/0 | config | test | `edge.netprobe_bin` | - | feature off |
| `SERVICERADAR_ONBOARDING_TOKEN_PRIVATE_KEY` | 1/0 | secret | service | secret: `edge.onboarding_token_private_key` | helm | - |
| `SERVICERADAR_ONBOARDING_TOKEN_PUBLIC_KEY` | 2/0 | material | service | secret: `edge.onboarding_token_public_key` | - | errors |
| `SERVICERADAR_REMOTE_ACCESS_AGENT_ID` | 1/0 | config | test | `edge.agent_id` | scripts | - |
| `SERVICERADAR_REMOTE_ACCESS_KNOWN_HOSTS` | 1/0 | config | service | `edge.known_hosts` | - | feature off |
| `SERVICERADAR_REMOTE_ACCESS_SESSION_ID` | 1/0 | config | test | `edge.session_id` | scripts | - |
| `SERVICERADAR_REMOTE_ACCESS_SSH_CA_KEY_FILE` | 1/0 | secret | test | secret: `edge.ssh_ca_key_file` | scripts | - |
| `SERVICERADAR_REMOTE_ACCESS_SSH_PRINCIPAL` | 1/0 | config | test | `edge.ssh_principal` | scripts | - |
| `SERVICERADAR_REMOTE_ACCESS_SSH_TARGET_HOST` | 1/0 | config | test | `edge.ssh_target_host` | scripts | - |
| `SERVICERADAR_REMOTE_ACCESS_SSH_TARGET_PORT` | 2/0 | config | test | `edge.ssh_target_port` | scripts | - |
| `SERVICERADAR_REMOTE_ACCESS_SSH_TEST_DIR` | 1/0 | config | test | `edge.ssh_test_dir` | - | empty string |
| `SERVICERADAR_REMOTE_ACCESS_SSH_USERNAME` | 1/0 | config | test | `edge.ssh_username` | scripts | - |
| `SR_ALLOW_EMBEDDED_DEFAULT_CONFIG` | 1/0 | config | service | `edge.allow_embedded_default_config` | - | feature off |
| `SR_ALLOW_INSECURE` | 1/0 | config | service | `edge.allow_insecure` | - | feature off |
| `SR_SYN_USE_EVENTFD` | 1/0 | config | service | `edge.syn_use_eventfd` | - | feature off |
| `SWEEP_RESULTS_MAX_CHUNK_BYTES` | 1/0 | config | service | `edge.sweep_results_max_chunk_bytes` | - | default |
| `SWEEP_RESULTS_MAX_HOSTS_PER_CHUNK` | 1/0 | config | service | `edge.sweep_results_max_hosts_per_chunk` | - | default |
| `TPACKET_RETIRE_TOV_MS` | 1/0 | config | service | `edge.tpacket_retire_tov_ms` | - | feature off |

### 6.3 `observability` -- 27 names, 0 credentials, 27 read sites

| variable | R/W | kind | tree | destination | set by | absent |
|---|---|---|---|---|---|---|
| `K8S_INVENTORY_DEBOUNCE` | 1/0 | config | service | `observability.debounce` | helm | - |
| `K8S_INVENTORY_GATEWAY_API` | 1/0 | config | service | `observability.gateway_api` | helm | - |
| `K8S_INVENTORY_METRICS_ADDR` | 1/0 | config | service | `observability.metrics_addr` | helm | - |
| `K8S_INVENTORY_NAMESPACES` | 1/0 | config | service | `observability.namespaces` | helm | - |
| `K8S_INVENTORY_PUBLISH_MAX_RETRIES` | 1/0 | config | service | `observability.publish_max_retries` | helm | - |
| `K8S_INVENTORY_PUBLISH_RETRY_DELAY` | 1/0 | config | service | `observability.publish_retry_delay` | helm | - |
| `K8S_INVENTORY_PUBLISH_TIMEOUT` | 1/0 | config | service | `observability.publish_timeout` | helm | - |
| `K8S_INVENTORY_RESYNC` | 1/0 | config | service | `observability.resync` | helm | - |
| `K8S_INVENTORY_SPOOL_DIR` | 1/1 | config | service+test | `observability.spool_dir` | helm | - |
| `K8S_INVENTORY_SUBJECT` | 1/0 | config | service | `observability.subject` | helm | - |
| `LOG_LEVEL` | 1/0 | config | service | `observability.log_level` | helm | - |
| `LOG_OUTPUT` | 1/0 | config | service | `observability.log_output` | - | default |
| `LOG_TIME_FORMAT` | 1/0 | config | service | `observability.log_time_format` | - | default |
| `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` | 1/1 | config | service+test | `observability.exporter_otlp_logs_endpoint` | - | default |
| `OTEL_EXPORTER_OTLP_LOGS_HEADERS` | 1/1 | config | service+test | `observability.exporter_otlp_logs_headers` | - | feature off |
| `OTEL_EXPORTER_OTLP_LOGS_INSECURE` | 1/1 | config | service+test | `observability.exporter_otlp_logs_insecure` | - | default |
| `OTEL_EXPORTER_OTLP_LOGS_TIMEOUT` | 1/0 | config | service | `observability.exporter_otlp_logs_timeout` | - | feature off |
| `OTEL_LOGS_ENABLED` | 1/1 | config | service+test | `observability.logs_enabled` | - | default |
| `OTEL_SERVICE_NAME` | 1/1 | config | service+test | `observability.service_name` | helm | - |
| `SERVICERADAR_TELEMETRY_DISABLED` | 1/1 | config | service+test | `observability.telemetry_disabled` | - | empty string |
| `TRIVY_INFORMER_RESYNC` | 1/0 | config | service | `observability.informer_resync` | helm | - |
| `TRIVY_METRICS_ADDR` | 1/0 | config | service | `observability.metrics_addr` | helm | - |
| `TRIVY_PUBLISH_MAX_RETRIES` | 1/0 | config | service | `observability.publish_max_retries` | helm | - |
| `TRIVY_PUBLISH_MAX_RETRY_DELAY` | 1/0 | config | service | `observability.publish_max_retry_delay` | - | empty string |
| `TRIVY_PUBLISH_RETRY_DELAY` | 1/0 | config | service | `observability.publish_retry_delay` | helm | - |
| `TRIVY_PUBLISH_TIMEOUT` | 1/0 | config | service | `observability.publish_timeout` | helm | - |
| `TRIVY_REPORT_GROUP_VERSION` | 1/0 | config | service | `observability.report_group_version` | helm | - |

### 6.4 `messaging` -- 13 names, 2 credentials, 21 read sites

| variable | R/W | kind | tree | destination | set by | absent |
|---|---|---|---|---|---|---|
| `NATS_CACERTFILE` | 2/0 | material | service | secret: `messaging.cacertfile` | helm | - |
| `NATS_CERTFILE` | 2/0 | material | service | secret: `messaging.certfile` | helm | - |
| `NATS_CREDSFILE` <br> _alias of `NATS_CREDS_FILE`_ | 2/0 | config | service | `messaging.creds_file` | - | empty string |
| `NATS_HOSTPORT` | 2/3 | config | service+test | nats.url | helm | - |
| `NATS_KEYFILE` | 2/0 | config | service | `messaging.keyfile` | helm | - |
| `NATS_OPERATOR_CONFIG_PATH` | 1/0 | config | service | `messaging.operator_config_path` | - | feature off |
| `NATS_RESOLVER_PATH` | 1/0 | config | service | `messaging.resolver_path` | - | feature off |
| `NATS_SERVER_NAME` | 2/0 | config | service | nats.server_name | helm | - |
| `NATS_SKIP_TLS_VERIFY` | 2/0 | config | service | `messaging.skip_tls_verify` | - | default |
| `NATS_STREAM` | 2/0 | config | service | `messaging.stream` | helm | - |
| `NATS_SUBJECT_PREFIX` | 1/0 | config | service | `messaging.subject_prefix` | helm | - |
| `NATS_SYSTEM_ACCOUNT_CREDS_FILE` | 1/0 | config | service | `messaging.system_account_creds_file` | helm | - |
| `SERVICERADAR_SYNC_RUNTIME_STATE_PATH` | 1/0 | config | service | `messaging.sync_runtime_state_path` | - | feature off |

### 6.5 `platform` -- 8 names, 0 credentials, 19 read sites

| variable | R/W | kind | tree | destination | set by | absent |
|---|---|---|---|---|---|---|
| `BAZEL_WORKSPACE` | 2/0 | config | build | `platform.bazel_workspace` | - | empty string |
| `BUILD_WORKSPACE_DIRECTORY` | 2/0 | platform | build+test | (stays an env read) | - | - |
| `DEBUG` | 1/0 | config | service | `platform.debug` | - | default |
| `RUNFILES_DIR` | 1/0 | platform | build | (stays an env read) | scripts | - |
| `RUNFILES_MANIFEST_FILE` | 3/0 | platform | build+test | (stays an env read) | - | - |
| `SR_PORT_ALLOCATOR` | 1/0 | config | service | `platform.sr_port_allocator` | - | empty string |
| `TEST_SRCDIR` | 8/0 | platform | build+test | (stays an env read) | - | - |
| `container` | 1/0 | config | service | `platform.container` | docker | - |

### 6.6 `plugins` -- 11 names, 5 credentials, 18 read sites

| variable | R/W | kind | tree | destination | set by | absent |
|---|---|---|---|---|---|---|
| `PLUGIN_UPLOAD_SIGNING_KEY_ID` | 2/0 | config | build | `plugins.signing_key_id` | scripts | - |
| `PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY` | 2/0 | secret | build | secret: `plugins.signing_private_key` | - | errors |
| `PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY_FILE` | 2/0 | secret | build | secret: `plugins.signing_private_key_file` | - | feature off |
| `PLUGIN_UPLOAD_SIGNING_PUBLIC_KEY` | 1/0 | material | build | secret: `plugins.signing_public_key` | - | errors |
| `PLUGIN_UPLOAD_SIGNING_PUBLIC_KEY_FILE` | 1/0 | material | build | secret: `plugins.signing_public_key_file` | - | feature off |
| `PLUGIN_UPLOAD_SIGNING_SIGNER` | 1/0 | config | build | `plugins.signing_signer` | scripts | - |
| `PLUGIN_UPLOAD_SIGNING_TRANSIT_KEY` | 2/0 | secret | build | secret: `plugins.signing_transit_key` | scripts | - |
| `SERVICERADAR_ACTION_WASM_PATH` | 1/0 | config | test | `plugins.action_wasm_path` | - | feature off |
| `SERVICERADAR_RUST_ADDON_BIN` | 1/0 | config | test | `plugins.rust_addon_bin` | - | empty string |
| `SERVICERADAR_SAMPLE_ADDON_BIN` | 1/0 | config | test | `plugins.sample_addon_bin` | - | empty string |
| `WASM_PATH` | 4/0 | config | test | `plugins.wasm_path` | - | exits |

### 6.7 `identity` -- 14 names, 4 credentials, 15 read sites

| variable | R/W | kind | tree | destination | set by | absent |
|---|---|---|---|---|---|---|
| `CORE_ADDRESS` | 1/0 | config | service | core.address | helm | - |
| `CORE_API_URL` | 1/0 | config | service | core.api_url | - | empty string |
| `CORE_CA_FILE` | 1/1 | material | service+test | secret: `identity.ca_file` | - | errors |
| `CORE_CERT_DIR` | 2/0 | material | service | secret: `identity.cert_dir` | helm | - |
| `CORE_CERT_FILE` | 1/1 | material | service+test | secret: `identity.cert_file` | - | errors |
| `CORE_KEY_FILE` | 1/1 | secret | service+test | secret: `identity.key_file` | - | errors |
| `CORE_SEC_MODE` | 1/3 | config | service+test | core.security_mode | helm | - |
| `CORE_SERVER_NAME` | 1/0 | config | service | core.server_name | docker | - |
| `CORE_SERVER_SPIFFE_ID` | 1/0 | config | service | core.server_spiffe_id | helm | - |
| `CORE_TRUST_DOMAIN` | 1/0 | config | service | core.trust_domain | docker,helm | - |
| `CORE_WORKLOAD_SOCKET` | 1/0 | config | service | `identity.workload_socket` | docker,helm | - |
| `GRPC_MAX_RECV_MSG_SIZE` | 1/0 | config | service | `identity.grpc_max_recv_msg_size` | - | feature off |
| `GRPC_MAX_SEND_MSG_SIZE` | 1/0 | config | service | `identity.grpc_max_send_msg_size` | - | feature off |
| `SPIFFE_ID` | 1/0 | config | service | `identity.id` | - | feature off |

### 6.8 `testing` -- 4 names, 0 credentials, 12 read sites

| variable | R/W | kind | tree | destination | set by | absent |
|---|---|---|---|---|---|---|
| `SERVICERADAR_LARGE_BANNER_GRAB_TEST` | 1/0 | config | test | `testing.large_banner_grab_test` | - | feature off |
| `SERVICERADAR_LARGE_INGESTION_DEVICE_COUNT` | 1/0 | config | test | `testing.large_ingestion_device_count` | scripts | - |
| `SERVICERADAR_LARGE_INGESTION_TEST` | 1/0 | config | test | `testing.large_ingestion_test` | scripts | - |
| `TEST_WORKSPACE` | 9/0 | config | build+test | `testing.workspace` | - | empty string |

### 6.9 `release` -- 5 names, 0 credentials, 6 read sites

| variable | R/W | kind | tree | destination | set by | absent |
|---|---|---|---|---|---|---|
| `BUILD_WORKSPACE_NAME` | 2/0 | config | build | `release.build_workspace_name` | - | empty string |
| `COMMIT_SHA` | 1/0 | config | build | `release.commit_sha` | - | empty string |
| `MULTIARCH_INDEXES` | 1/0 | config | build | `release.multiarch_indexes` | - | empty string |
| `PUBLISH_MODE` | 1/3 | config | service+test | `release.publish_mode` | helm | - |
| `STABLE_COMMIT_SHA` | 1/0 | config | build | `release.stable_commit_sha` | - | empty string |

### 6.10 `secrets_infra` -- 4 names, 2 credentials, 6 read sites

| variable | R/W | kind | tree | destination | set by | absent |
|---|---|---|---|---|---|---|
| `VAULT_ADDR` | 2/1 | config | build | `secrets_infra.addr` | scripts | - |
| `VAULT_CACERT` | 1/0 | material | build | secret: `secrets_infra.cacert` | scripts | - |
| `VAULT_SKIP_VERIFY` | 1/1 | config | build | `secrets_infra.skip_verify` | scripts | - |
| `VAULT_TOKEN` | 2/1 | secret | build | secret: `secrets_infra.token` | scripts | - |

### 6.11 `config_system` -- 4 names, 0 credentials, 4 read sites

| variable | R/W | kind | tree | destination | set by | absent |
|---|---|---|---|---|---|---|
| `CONFIG_ENV_PREFIX` | 1/0 | config | service | `config_system.config_env_prefix` | - | default |
| `CONFIG_SOURCE` | 1/0 | config | service | `config_system.config_source` | helm | - |
| `PINNED_CONFIG_PATH` | 1/0 | config | service | `config_system.pinned_config_path` | - | empty string |
| `SERVICERADAR_ENV` | 1/0 | config | manager | `config_system.serviceradar_env` | bazel-ci | - |

### 6.12 `kubernetes` -- 2 names, 0 credentials, 4 read sites

| variable | R/W | kind | tree | destination | set by | absent |
|---|---|---|---|---|---|---|
| `KUBECONFIG` | 3/0 | config | service | `kubernetes.kubeconfig` | - | feature off |
| `KUBERNETES_SERVICE_HOST` | 1/0 | config | service | `kubernetes.kubernetes_service_host` | - | feature off |

### 6.13 `database` -- 3 names, 0 credentials, 3 read sites

| variable | R/W | kind | tree | destination | set by | absent |
|---|---|---|---|---|---|---|
| `CLUSTER_ID` | 2/3 | config | service+test | `database.cluster_id` | helm | - |
| `ENABLE_DB_MIGRATIONS` | 0/1 | config | test | `database.enable_db_migrations` | - | - |
| `SR_E2E_DB_DSN` | 1/0 | config | test | `database.sr_e2e_db_dsn` | - | exits |
## 7. Migration plan

Go is the cheap half of this change. The ordering below reflects that, and the first two
steps are deletions rather than conversions.

### 7.1 Delete the reflection loader

[go/pkg/config/env_loader.go](go/pkg/config/env_loader.go) turns every JSON tag of every
config struct into an environment override, plus a whole-document override through
`SERVICERADAR_CONFIG_JSON`. It cannot be inventoried, cannot be validated, and every chart
already selects `CONFIG_SOURCE=file`.

Delete `EnvConfigLoader`, the `configSourceEnv` branch in
[go/pkg/config/config.go:243-250](go/pkg/config/config.go#L243-L250), and the
`CONFIG_ENV_PREFIX` read. Keep `CONFIG_SOURCE` only if something still needs to choose
between file and a future manager; otherwise it goes too.

This is the single highest-value edit in the Go tree, and it is a deletion.

### 7.2 Take the 77 tooling-and-test names out of scope, explicitly

77 names are read only by `build/`, `tools/` and `_test.go` files. `GITHUB_TOKEN`,
`PUBLISH_MODE`, `UNIFI_PROTECT_LIVE_HOST`, `TEST_SRCDIR` are not deployment configuration
and must not acquire schema fields. Write that exclusion down as a list in the gate, not as
a path pattern -- a path pattern silently exempts a service file that moves.

What remains is **91 names read by a shipped service**, of which 11 are credentials.

### 7.3 Collapse the six alias groups

Two vendor renames (`BAO_*` / `OPENBAO_*` / `VAULT_*`), two Armis spellings, one Bazel pair,
and the cross-language `NATS_CREDSFILE` / `NATS_CREDS_FILE` split. All are pure Go edits.

`NATS_CREDSFILE` is the one to fix first and it does not need the schema: two shipped
services read a spelling nothing sets. Rename it to `NATS_CREDS_FILE` now, as a standalone
change, so the trap is gone whatever happens to the rest of the plan.

### 7.4 Convert per partition, sharing the Elixir partitions

`messaging`, `identity` and `database` already have schema fields, and Go already has a
ConfigManager at [config/manager_config/go](config/manager_config/go). Those three go first
and they are small: 30 names between them, 39 read sites.

Where Go and Elixir read the same value under different names (section 4.2), the schema
field is the decision point -- one field, and both languages stop naming a variable at all.
That is the case the whole change exists for, and it is worth landing one of them
end-to-end early as proof: `NATS_HOSTPORT` / `NATS_URL` into `nats.url` touches both trees,
both managers, and the Helm template, and is small enough to review in one sitting.

### 7.5 Gate

Same shape as the Elixir gate, with one Go-specific rule worth encoding: **fail any new
`os.Getenv` outright and require `os.LookupEnv`** for whatever remains. Reading a variable
without being able to tell unset from empty is the defect underneath most of section 3.1,
and it costs one line to make it impossible.

The allowlist starts at 169 names and shrinks per partition. It excludes the 77 tooling and
test names by name, and the eight platform names -- `BUILD_WORKSPACE_DIRECTORY`,
`RUNFILES_DIR`, `RUNFILES_MANIFEST_FILE`, `TEST_SRCDIR`, `BAZEL_WORKSPACE`,
`SR_PORT_ALLOCATOR`, `DEBUG` and `container` (the systemd container marker).

### 7.6 What this is worth relative to Elixir

| | Go | Elixir |
|---|---|---|
| distinct names | 173 | 676 |
| read sites | 246 | 1173 |
| names read by non-test code | 91 | 588 |
| never set anywhere | 107 | 350 |
| ... of which fail loudly | 20 | 6 |
| unresolvable reads | 2 | 91 |
| consumer files reading one partition | 45 of 62 | 88 of 108 |

Go is smaller, better guarded, and structurally readier: services already load JSON
configuration through a loader interface, so ConfigManager slots in where `FileLoader`
already sits. The Elixir tree has no such seam -- four `runtime.exs` files are the seam.

If the schedule forces a choice, do Go first for the proof and Elixir for the value.
