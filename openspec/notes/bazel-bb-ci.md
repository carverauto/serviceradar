Reality

Bazel builds and tests 
- Go source tree
- Rust source tree 
- JS source tree
- Proto source tree
- The elixir source tree
- The bulk of OCI images

Known gaps 
- CI is a total mess

Step 1 of the vision below is green as of 2026-08-03: `bazel build -c opt //... --config=remote`
builds all 1,971 targets clean. Getting there needed no -c opt work at all -- every failure
was mode-independent and had been latent. See "Test tags" below for the two repo-level
causes (a scratch tree missing from .bazelignore, and `local` tags on targets whose exec
platform is Linux).

One environment-level cause is NOT a repo fix: a stale ghcr.io entry in the macOS keychain
makes rules_oci send a dead credential, and ghcr answers 403 where anonymous returns 200.
`docker logout ghcr.io` restores it. Large ghcr blob fetches (arc-runner) are also just
flaky over a slow link -- two attempts failed two different ways, a third succeeded.

Step 2 is green. One test is tagged `manual` and therefore out of the sweep:

  //scripts:release_publish_contracts_test        (RED when run explicitly)

It does not belong in a unit sweep in the first place. It is 665 lines of bash driving
embedded Python that makes literal substring assertions over CI configuration -- 5 .forgejo
workflow YAMLs, 9 release shell scripts, the image inventory, the ArgoCD app -- and
exercises no shipped code path. It was in the sweep only because it was untagged, which
under the exclusion convention below means "included by default".

Run it deliberately:

  bazel test //scripts:release_publish_contracts_test --test_tag_filters=

It is not stale and it is not flaky -- it is reporting real drift between the two release
workers. fa88629ca ("pin forgejo-ci digest for Wasm plugin publish") also loosened the
release-tag source gate in .forgejo/workflows/wasm-plugins.yml to let workflow_dispatch run
from a non-tag ref, and did not make the same change to native-addons.yml:

    native-addons.yml:97   if [[ "${GITHUB_REF}" != "${expected_ref}" ]]
    wasm-plugins.yml:97    if [[ "${GITHUB_EVENT_NAME}" != "workflow_dispatch" && ... ]]

The test asserts both gates stay identical (test-release-publish-contracts.sh:593); the
fragment loop just trips first. The bypass is bounded -- the dispatch path still requires
validate-release-tag.sh, a VERSION match, and the tag commit being an ancestor of staging;
only the run's ref may differ from the tag ref.

Deliberately NOT fixed: .forgejo/workflows/ is being replaced by BB workflows.


Step 3 has one target tagged `manual` pending a product decision:

  //go/pkg/scan/banner_grab:banner_grab_integration_test        (RED when run explicitly)

TO BE SOLVED LATER. assertIntegrationMatches requires an `ntp` product match:

    for _, product := range []string{"openssh", "httpd", "postfix", "samba", "ntp"} {

The recog corpus cannot produce one. There is no recog-corpus/xml/ntp*.xml, and
serviceradar-recog-additions.xml has ZERO ntp entries. The only ntp.xml lives under
satori-corpus/, which feeds OS-fingerprint signals (SatoriTcp/Dhcp/Http/Ssh), not banner
product matching. The other four products all match, from recog: corpora.

This was undetectable until 2026-08-03. The test launches a netprobe sidecar, and netprobe
refuses to serve IPC as root -- which every RBE executor is. It died waiting for a socket
that never bound (5.03s timeout), so the assertions never ran. Adding `--allow-root` to the
sidecar launch (safe: that sidecar is configured {"enabled":false}, so it probes nothing and
only answers Ping) got the socket to bind in 0.70s and surfaced the real gap.

Resolution is a product call, not a build one: either add an NTP entry to the recog corpus,
or drop "ntp" from the expected product list. Remove the `manual` tag when that lands.


Vision

Build all of the repo via a Bazel and migrate CI to BuildBuddy (BB) Workflow  

A BuildBuddy Workflow would look like this:

# Setup Docker Authenticate
bazel run -c opt //:buildbuddy_setup_docker_auth --verbose_failures

# 1 Build
bazel build -c opt //... --config=remote

# 2 Unit tests 
bazel test -c opt //... --config=remote --test_tag_filters=-integration_test,-acceptance_test

# 3 Integration / acceptance tests -- ONE workflow step, see "Fixture credentials" below.
#   The env must be established in the SAME step: a process cannot set its parent's
#   environment, so a separate step would lose it. Provisioning is manual+external+
#   no-remote-exec, so //... never reaches it, and the shards connect to
#   sr_core_test_local_<shard> databases that must exist first.
#
#   --//build:enable_integration_tests goes on EVERY line, not just the sweep. The four
#   lifecycle targets carry requires_shared_fixture() too, so without the flag each one is
#   @platforms//:incompatible; naming it then leaves zero targets and Bazel reports
#   "No test targets were found, yet testing was requested" -- which reads like a typo in
#   the label rather than a missing flag.

bazel run -c opt //:buildbuddy_setup_fixture_env
set -a; . "${SERVICERADAR_FIXTURE_ENV_FILE:-${TMPDIR:-/tmp}/serviceradar-fixture-env}"; set +a

bazel test -c opt //elixir/serviceradar_core:migrate_template --config=remote --test_tag_filters= --//build:enable_integration_tests

bazel test -c opt //rust/integration-db:provision_db          --config=remote --test_tag_filters= --//build:enable_integration_tests

bazel test -c opt //... --config=remote --test_tag_filters=integration_test,-acceptance_test --//build:enable_integration_tests

bazel test -c opt //rust/integration-db:teardown_db           --config=remote --test_tag_filters= --//build:enable_integration_tests

# 4 Build images
bazel build -c opt //:images --config=remote

# 5 Push images to registry 
bazel run -c opt //:push --config=remote


Side effects
- BB remote build is leveraged throughout
- BB remote cache is used consistently
- CI can replicate these steps and gain speedup from BB remote cache and build
- Most existing CI GH actions will be replaced with a single BB CI workflow

What must be true for the vision to become the new reality?

- The remaining Elixir targets must build and test via Bazel
- ALl Service Radar OCI images must use internal Bazel targets only
- zero scripts should be used unless explicistly permitted for hard corner cases. e.g. Docker Authentication.


Fixture credentials in a BB workflow (verified 2026-08-03)

Step 3 needs a live CNPG fixture. The plumbing to carry credentials into a remote test action
ALREADY EXISTS -- nothing to build, only values to configure.

  BuildBuddy org secret -> env var on the workflow runner -> --test_env pass-through
                        -> test action env on the executor

`--test_env=NAME` with NO `=value` reads from the BAZEL CLIENT's environment and copies the
value into each test action. In a workflow the client is the `bazel` process on the runner,
whose environment carries the configured BB secrets. .bazelrc already declares all three
(lines 116 and 147):

    test --test_env=SRQL_TEST_DATABASE_URL
    test --test_env=SRQL_TEST_ADMIN_URL
    test --test_env=SRQL_TEST_DATABASE_CA_CERT

//:buildbuddy_setup_fixture_env establishes them, with two sources and a hard failure if
neither is present:

  1. KUBERNETES, preferred. If kubectl is on PATH and can `get secrets -n srql-fixtures`,
     it reads srql-test-db-credentials, srql-test-admin-credentials and srql-fixture-ca and
     assembles the DSNs itself. srql-fixtures stays the single source of truth and the
     90-day CNPG CA rotation is picked up automatically instead of needing a re-copy.
  2. PRE-SET ENVIRONMENT, fallback. Trusts SRQL_TEST_DATABASE_URL / _ADMIN_URL /
     _DATABASE_CA_CERT if already exported -- BuildBuddy workflow secrets, or a developer's
     own shell. Not an error: a runner without cluster RBAC, or a workstation pointed at a
     NodePort, is a legitimate caller.

Host/port/database are NOT secret, so they are defaults in the target rather than secrets;
override with SRQL_FIXTURE_{NAMESPACE,HOST,PORT,DATABASE,SSLMODE}.

It is a script, under the same credential carve-out as buildbuddy_setup_docker_auth.sh and
for the same reason: a test action cannot fetch these itself (remote executor, no
kubeconfig, sandboxed), and a `kubectl get secret` inside a test would be an undeclared
network dependency. The values have to reach the bazel CLIENT's environment before
`bazel test` starts. It writes 0600 to a file OUTSIDE the workspace and prints only source
and shape -- never a value -- because `bazel run` stdout becomes a build log.

Note the name: config/test.exs PREFERS SERVICERADAR_TEST_DATABASE_CA_CERT, but only the
SRQL_ spelling is in the --test_env list, so the SERVICERADAR_ one silently never arrives.

There is NO component-parts path. config/test.exs takes the DSN only from
SERVICERADAR_TEST_DATABASE_URL / SRQL_TEST_DATABASE_URL (or their _FILE forms); the CNPG_*
variables .bazelrc also passes supply TLS material and sslmode only, never host/user/pass.
A URL is mandatory, which is why the target assembles one.

THE VALUES ALREADY EXIST. The outgoing Forgejo workflows carry the same three under the
same names (.forgejo/workflows/rust-tests.yml, armis-dire-e2e.yml, elixir-quality.yml):

    SRQL_TEST_DATABASE_URL:      ${{ secrets.SRQL_TEST_DATABASE_URL }}
    SRQL_TEST_ADMIN_URL:         ${{ secrets.SRQL_TEST_ADMIN_URL }}
    SRQL_TEST_DATABASE_CA_CERT:  ${{ secrets.SRQL_TEST_DATABASE_CA_CERT }}

So this is a COPY from Forgejo repo settings into BuildBuddy secrets, not a redesign. The
names already match what .bazelrc expects and the DB is the same CNPG cluster those jobs
have been using. `printf '%s' "${SRQL_TEST_DATABASE_CA_CERT}" > "${ca_file}"` in
rust-tests.yml confirms the CA secret is already PEM CONTENT; that materialise-to-file step
existed because the Rust path wanted _CA_CERT_FILE, and the Elixir shards no longer need it.

The CA must be PEM CONTENT, not a path -- that is the whole reason f14be4eba could drop
`no-remote-exec`. A path names a file on the machine that launched the build; an executor
has no such file. Get it with:

    kubectl get secret srql-fixture-ca -n srql-fixtures -o jsonpath='{.data.ca\.crt}' | base64 -d

WHICH ENDPOINT. Only the executors are self-hosted (3 pods in the `buildbuddy` namespace);
the BB app is cloud. A workflow runner is itself an action, so it lands on those same
in-cluster executors -- which means runner and test actions share one network view and ONE
DSN serves both the no-remote-exec provisioning targets and the remote shards:

    postgres://<user>:<pass>@srql-fixture-rw.srql-fixtures.svc.cluster.local:5432/srql_fixture?sslmode=verify-full

Measured reachability, 2026-08-03 (bash /dev/tcp from a workstation and from an executor pod
-- note `sh` in the executor image is not bash, so /dev/tcp silently fails there; use bash):

                                                       workstation   executor
    srql-fixture-rw.srql-fixtures.svc.cluster.local:5432    no          OPEN
    10.43.106.83:5432 (ClusterIP)                           no          OPEN
    192.168.10.31:30818 (LAN NodePort)                      OPEN        no
    23.138.124.18:5432 (MetalLB LB)                         no          OPEN

The workstation is the odd one out, not CI. A developer running step 3 by hand needs TWO
DSNs -- NodePort for the local provisioning leg, cluster DNS for the remote sweep -- because
those two sets are disjoint. CI does not.

sslmode: the server cert (secret srql-fixture-server) carries DNS SANs only --
srql-fixture-{r,ro,rw}[.srql-fixtures[.svc[.cluster.local]]] and
srql-fixture.serviceradar.cloud. No IP SANs, so `verify-full` works against either DNS name
but NOT against a NodePort IP; that leg needs `sslmode=require`.

Fixing workstation routing to srql-fixture.serviceradar.cloud (in the SAN, already OPEN from
executors, currently unreachable from a workstation -- same MetalLB VIP problem AGENTS.md
notes for 192.168.6.82) would collapse the developer path to one DSN as well.

CAVEAT: a test action's environment is part of its action key, so the DSN -- password
included -- is visible in BuildBuddy's action details for the 8 cacheable shards. Org-private
and ordinary practice, but know it before pasting a production credential. The provisioning
targets are `external`, which disables their caching, so they do not persist one.


Test tags: what actually exists (re-verified 2026-08-03)

The convention is EXCLUSION, not inclusion: tag only what must be run separately, and let
everything else fall into the default sweep. 

150 test targets outside //docker/images. Tags in use:

  integration_test          10   core integration_tests_s0..s7, banner_grab_integration_test,
                                 and the dgraph acceptance target
  manual                     9   the DB-backed tier that cannot self-provision:
                                 migrate_template, the 3 //rust/integration-db lifecycle
                                 targets, the 2 //integration_tests/srql tests, 2 js :ci,
                                 plus //scripts:release_publish_contracts_test (a CI-config
                                 linter, not a unit test -- see above)
  no-remote                  8   (same shape)
  no-remote-exec             6   migrate_template, the 3 integration-db targets, the 2 srql
                                 tests; cannot run on RBE
  external                   4   migrate_template + the 3 integration-db targets (disables
                                 test caching; a cached "pass" would provision nothing)
  no-sandbox                 3
  acceptance_test            1   //rust/dgraph-client/tests:acceptance_tests_dgraph_container_test_test
  dgraph_acceptance_test     1   (same target)
  restrict_acceptance_tests  1

=> The remaining targets are untagged and become the default sweep for free. Zero new
   tagging is required to adopt the scheme above.

=> The default sweep is fully RBE-safe: every `no-remote-exec` target is also `manual`, so
   none of them reach the remote sweep.

The previous census (2026-08-02) predates commit f14be4eba, which moved core
integration_tests_s0..s7 off `manual` and onto `integration_test`. That is why `manual`
went 13 -> 8 while `integration_test` went 1 -> 10; nothing was untagged.

`local` is now used by ZERO test targets, and must stay that way.

If a test genuinely cannot run on RBE, tag it `manual` + `no-remote-exec` like the rest
  of the DB-backed tier. Never `local`.

Do not point //... at a tree Bazel should not own. `ctx/` is a local scratch dir (a
DeepCausality checkout and assorted logs); it is in .gitignore, which does NOT imply
.bazelignore. Until it was added there it contributed 1,185 analysis errors to
`bazel build //...` on a workstation while CI, which checks out clean, saw none.

Note `manual` already excludes targets from `//...` wildcard expansion, so `-manual` in the
filter is redundant-but-explicit. The inverse matters more: any step that WANTS a manual
target must name it AND pass an empty `--test_tag_filters=`, or it resolves to nothing.
- no action in the image graph reaches the network; all deps are declared inputs.