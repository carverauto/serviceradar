defmodule ServiceRadar.Plugins.AddonConfigContractFixtures do
  @moduledoc """
  Renders the committed add-on config contract fixtures (fj#4383, OpenSpec
  `refactor-addon-lifecycle-operability` task 4.3).

  For every bundled native add-on this module builds a representative
  `AddonAssignment.params` map (including documented compatibility forms such
  as scalar string -> string list and string -> integer), runs it through the
  REAL delivery path (`AgentConfigGenerator.to_proto_addons/2` via
  `to_proto_response/1`, i.e. schema coercion + post-coercion validation +
  `config_json` encoding against the add-on's actual
  `addons/<id>/config.schema.json`), and emits the resulting `config_json`
  bytes to `go/pkg/agent/testdata/addonconfig_contract/<id>.json`.

  Those committed fixtures are then decoded by the real agent/add-on decoders
  in CI:

    * Go: `go/pkg/agent/addon_config_contract_test.go` (netprobe via
      `netprobe.ApplyAddonConfigJSON`, bumblebee-scan via
      `bumblebee.LoadConfig`, scalibr-endpoint-inventory via
      `scalibrinventory.LoadConfig`, each merged over the staged base config
      with the agent's real merge).
    * Rust: in-crate tests in `rust/anomaly-addon`, `rust/otel-addon` and
      `rust/workload-identity` decode the fixtures with their real serde
      config structs.
    * rdp-adapter has NO config decoder (its schema declares zero properties
      and the binary speaks a stdio wire protocol, not a config file); its
      fixture asserts core emits exactly `{}` for it.

  ## Regenerating

  After changing an add-on `config.schema.json`, the representative params
  below, or the delivery-path coercion rules:

      cd elixir/serviceradar_core
      mix serviceradar.gen.addon_contract_fixtures

  and commit the updated files under
  `go/pkg/agent/testdata/addonconfig_contract/`. The ExUnit drift test
  (`test/serviceradar/edge/addon_config_contract_fixtures_test.exs`) fails
  until the committed fixtures match what the delivery path emits.

  This module is repo tooling: paths are resolved relative to this source
  file's checkout and it is only meant to run from a source tree (mix task /
  ExUnit), never from a release.
  """

  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Plugins.ConfigSchema

  @repo_root Path.expand("../../../../..", __DIR__)
  @fixture_dir Path.join(@repo_root, "go/pkg/agent/testdata/addonconfig_contract")

  # Representative assignment params per bundled add-on. Deliberately include
  # the documented compatibility forms (see
  # docs/docs/addon-config-contracts.md): scalar CSV string where the schema
  # declares an array of strings, and string-typed integers/booleans. The
  # fixture captures what delivery ships AFTER coercion, so the committed
  # bytes always carry the schema-typed shapes.
  @representative_params %{
    "netprobe" => %{
      "enabled" => true,
      # compat: scalar CSV string -> ["ens18", "ens19"]
      "capture_interfaces" => "ens18, ens19",
      # compat: string -> integer
      "default_sample_interval_ms" => "500",
      "flow_table_max_entries" => 65_536,
      "process_snapshot_interval_s" => 30,
      "external_flow_match_window_ms" => 1_500,
      "flow_attribution_ipc_batch" => true,
      "emit_raw_flow_attribution_events" => false,
      # Declared by config.schema.json since the manifest was written, but never
      # represented here -- so the delivery path was never exercised for them,
      # and the agent's decoder silently ignored both until they were added to
      # addonConfig. Present now so the fixture proves core emits them.
      "dpi" => %{"enabled" => true, "protocols" => ["tls", "http"]},
      "device_bindings" => [
        %{
          "ip" => "192.168.1.10",
          "profile_id" => "camera-profile",
          "profile_name" => "Camera",
          "sample_interval_ms" => 500,
          "fingerprint" => %{"tcp" => true, "tls" => true, "http" => false},
          "dpi" => %{"enabled" => true, "protocols" => ["dns"]}
        }
      ]
    },
    "otel-collector" => %{
      "output" => %{"backend" => "jetstream"},
      # compat: string -> integer inside a nested object
      "nats" => %{
        "url" => "tls://nats.demo.internal:4222",
        "stream" => "events",
        "timeout_secs" => "15",
        # Required, not decorative. config.schema.json carries an allOf that fires when
        # output.backend is "jetstream": nats then requires url AND tls, tls requires all three
        # paths, and creds_file must be absent. Without this block delivery refuses the params --
        #   Expected all of the schemata to match, but the schemata at the following
        #   indexes did not: 0.
        # -- and AddonConfigContractFixturesTest fails before it can compare anything.
        #
        # The condition arrived in 91ce839f3e ("remove agent NATS credential dependency"), which
        # moved this add-on from creds-file auth to mTLS. That commit updated the schema and the
        # committed fixture but not these params, so the two have disagreed since. The paths below
        # are the ones already in go/pkg/agent/testdata/addonconfig_contract/otel-collector.json.
        #
        # These stay file PATHS. For a ready direct assignment the control plane injects
        # cert_pem/key_pem/ca_pem at delivery time; the base onboarding bundle never carries them.
        "tls" => %{
          "cert_file" => "/etc/serviceradar/edge/nats-client.pem",
          "key_file" => "/etc/serviceradar/edge/nats-client-key.pem",
          "ca_file" => "/etc/serviceradar/edge/nats-ca.pem"
        }
      },
      "server" => %{"bind_address" => "0.0.0.0", "port" => 4_317},
      "agent_forward" => %{"spool_dir" => "/var/lib/serviceradar/otel-spool"}
    },
    "anomaly-addon" => %{
      "window_size" => 300,
      # compat: string -> integer
      "min_samples" => "30",
      "n_sigma" => 3.5,
      "confirm_slots" => 5,
      "max_series" => 50_000,
      "cusum_k" => 0.5,
      "cusum_h" => 5.0,
      "metric_feed" => %{"sources" => ["sysmon", "snmp"]},
      "checkpoint_path" => "/var/lib/serviceradar/anomaly/checkpoint.bin",
      "checkpoint_max_age_secs" => 21_600
    },
    "bumblebee-scan" => %{
      "enabled" => true,
      "agent_id" => "agent-demo-01",
      "catalog_snapshot_ref" => "snapshot-42",
      "scan_timeout" => "10m",
      "include_home_roots" => true,
      "include_root" => false,
      # compat: scalar CSV string -> ["/opt/apps", "/srv/data"]
      "explicit_roots" => "/opt/apps, /srv/data",
      "exclude_roots" => ["/proc", "/sys"],
      "ecosystems" => ["npm", "pypi"],
      # compat: string -> integer
      "max_findings" => "500",
      "max_output_bytes" => 33_554_432
    },
    "scalibr-endpoint-inventory" => %{
      "enabled" => true,
      # scalibrinventory.LoadConfig validation requires an agent id
      "agent_id" => "agent-demo-01",
      # compat: scalar CSV string -> list (a schema-required field)
      "scalibr_plugins" => "os/dpkg, os/rpm, os/apk",
      "scan_roots" => ["/"],
      "cadence" => "12h",
      "collect_paths" => true,
      "collect_file_hashes" => false,
      # compat: string -> integer
      "max_packages" => "100000",
      "network_online" => false
    },
    "workload-identity" => %{
      "enabled" => true,
      "root" => "/",
      "runtime" => %{
        "type" => "containerd",
        "socket" => "/run/containerd/containerd.sock"
      },
      # compat: string -> integer
      "refresh_interval_s" => "120",
      "cluster_name" => "demo-cluster",
      "max_identities" => 50_000
    },
    # rdp-adapter's schema declares zero properties (additionalProperties:
    # false): the only deliverable config is the empty object, and any
    # non-empty params refuse delivery.
    "rdp-adapter" => %{}
  }

  @base_config %{
    config_version: "v-contract-fixture",
    config_timestamp: 1_700_000_000,
    heartbeat_interval_sec: 30,
    config_poll_interval_sec: 300,
    checks: [],
    plugins: [],
    plugin_engine_limits: %{},
    config_json: <<>>,
    sysmon_config: nil,
    snmp_config: nil,
    visibility_config: nil
  }

  @spec addon_ids() :: [String.t()]
  def addon_ids, do: @representative_params |> Map.keys() |> Enum.sort()

  @doc """
  Repository root, resolved at RUNTIME rather than pinned at compile time.

  `@repo_root` is `Path.expand("../../../../..", __DIR__)`, which is correct under plain
  `mix` -- the checkout compiles in place. Under Bazel it is not: `mix_app` compiles in its
  own build tree, so the constant bakes in a path under `bazel-bin/.../erlang_app_mix/`, and
  the test then runs in a sandbox where only declared runfiles exist. The baked path resolves
  to a directory that is real on the host and absent in the sandbox, so `File.read!` fails
  with a path that looks plausible and points nowhere useful.

  Candidates in order, first one that actually contains the tree wins:

    1. `SERVICERADAR_REPO_ROOT`, for a caller that knows better;
    2. the compile-time root, which is right for `mix`;
    3. two levels up from the working directory, which is where a Bazel test's runfiles put
       the workspace (the test runs from `elixir/serviceradar_core`).

  Repo tooling either way -- this module is not meant to run from a release.
  """
  @spec repo_root() :: Path.t()
  def repo_root do
    [
      System.get_env("SERVICERADAR_REPO_ROOT"),
      @repo_root,
      Path.expand("../..", File.cwd!())
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.find(@repo_root, fn root ->
      File.dir?(Path.join(root, "go/pkg/agent/testdata/addonconfig_contract"))
    end)
  end

  @spec fixture_dir() :: Path.t()
  def fixture_dir, do: Path.join(repo_root(), "go/pkg/agent/testdata/addonconfig_contract")

  @spec fixture_path(String.t()) :: Path.t()
  def fixture_path(addon_id), do: Path.join(fixture_dir(), addon_id <> ".json")

  @spec representative_params(String.t()) :: map()
  def representative_params(addon_id), do: Map.fetch!(@representative_params, addon_id)

  @spec schema(String.t()) :: map()
  def schema(addon_id) do
    [repo_root(), "addons", addon_id, "config.schema.json"]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
  end

  @doc """
  Renders the `config_json` bytes the delivery path emits for the add-on's
  representative params, via the real proto conversion (coercion + validation
  included). Raises if delivery would refuse the params — the representative
  params must always be deliverable.
  """
  @spec rendered_config_json(String.t()) :: binary()
  def rendered_config_json(addon_id) do
    schema = schema(addon_id)
    params = representative_params(addon_id)

    response =
      AgentConfigGenerator.to_proto_response(
        Map.merge(@base_config, %{
          agent_id: "contract-fixture-agent",
          addons: [
            %{
              addon_id: addon_id,
              version: "0.0.0-contract",
              enabled: true,
              binary_path: "/usr/local/lib/serviceradar/bin/#{addon_id}",
              args: [],
              params: params,
              config_schema: schema
            }
          ]
        })
      )

    case response.addons do
      [%Monitoring.AddonAssignmentConfig{config_json: config_json}] ->
        config_json

      [] ->
        coerced = ConfigSchema.coerce_params(schema, params)

        raise "delivery refused the representative params for #{addon_id}: " <>
                inspect(ConfigSchema.validate_params(schema, coerced))
    end
  end

  @doc """
  Writes every fixture file. Returns the written paths.
  """
  @spec write_all!() :: [Path.t()]
  def write_all! do
    File.mkdir_p!(@fixture_dir)

    Enum.map(addon_ids(), fn addon_id ->
      path = fixture_path(addon_id)
      File.write!(path, rendered_config_json(addon_id))
      path
    end)
  end
end
