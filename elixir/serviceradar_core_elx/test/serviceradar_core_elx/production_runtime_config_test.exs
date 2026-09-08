defmodule ServiceRadarCoreElx.ProductionRuntimeConfigTest do
  # Guard against config drift between serviceradar_core and this release
  # wrapper: the deployed image only evaluates THIS tree's runtime.exs, so a
  # worker scheduled solely in serviceradar_core/config/runtime.exs never runs
  # in production. Evaluates the release runtime config the way a prod boot
  # would (required env stubbed) and asserts the Oban crontab is complete.
  use ExUnit.Case, async: false

  alias ServiceRadar.Automation.Ansible.FileCallbackResponsePolicyProvider
  alias ServiceRadar.Edge.AgentCommandCleanupWorker
  alias ServiceRadar.EventWriter.Config, as: EventWriterConfig
  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.Observability.CapacityForecasting.Worker

  @prod_config Path.expand("../../config/prod.exs", __DIR__)
  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)

  @required_production_workers [
    ServiceRadar.Jobs.AlertsRetentionWorker,
    ServiceRadar.Jobs.RefreshLogsSeverityStatsWorker,
    ServiceRadar.Observability.AnomalyAddonConfigProjector,
    ServiceRadar.Observability.AnomalyAlertLivenessWorker,
    ServiceRadar.Observability.AnomalyEpisodeStaleCloseWorker,
    ServiceRadar.Observability.AnomalyIngestSilenceWorker,
    Worker,
    ServiceRadar.Observability.DataRetentionWorker,
    ServiceRadar.Observability.ResolveStaleAnomaliesWorker,
    ServiceRadar.Observability.SeasonalBaselineFreshnessWorker,
    ServiceRadar.Observability.SeasonalDisposition.EdgeBaselineProducer,
    ServiceRadar.Observability.SeasonalDisposition.Worker
  ]

  # The minimum env a prod evaluation requires; AshOban scheduler expansion is
  # skipped because it walks every Ash domain, while the workers under test are
  # scheduled through the explicit cron entries.
  @stub_env %{
    "CLOAK_KEY" => Base.encode64(:crypto.strong_rand_bytes(32)),
    "DATABASE_URL" => "ecto://user:pass@localhost/serviceradar_config_guard_test",
    "SERVICERADAR_ASH_OBAN_SCHEDULER_ENABLED" => "false"
  }

  setup do
    previous = Map.new(@stub_env, fn {name, _value} -> {name, System.get_env(name)} end)
    Enum.each(@stub_env, fn {name, value} -> System.put_env(name, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "prod Oban crontab schedules every required production worker" do
    oban_config = read_prod_config()[:serviceradar_core][Oban]
    assert Keyword.keyword?(oban_config)

    crontab =
      oban_config
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value([], fn
        {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab, [])
        _other -> nil
      end)

    scheduled = Enum.map(crontab, &elem(&1, 1))

    for worker <- @required_production_workers do
      assert worker in scheduled, "missing production cron entry for #{inspect(worker)}"
    end
  end

  test "prod config uses the shipped Req client for Swoosh API adapters" do
    swoosh_config = Config.Reader.read!(@prod_config, env: :prod)[:swoosh]

    assert swoosh_config[:api_client] == Swoosh.ApiClient.Req
    assert Code.ensure_loaded?(Req)
    refute Code.ensure_loaded?(:hackney)
  end

  test "local mailer runtime retains the production Req API client" do
    with_env("SERVICERADAR_LOCAL_MAILER", "true")

    swoosh_config =
      @prod_config
      |> Config.Reader.read!(env: :prod)
      |> Config.Reader.merge(read_prod_config())
      |> Keyword.fetch!(:swoosh)

    assert swoosh_config[:api_client] == Swoosh.ApiClient.Req
    assert swoosh_config[:local] == true
  end

  # The deployed image evaluates only this tree's runtime.exs, so the Helm
  # mailer environment reaching serviceradar_core's runtime.exs proves nothing
  # about production. These three assert the whole chain: Helm sets
  # SMTP_RELAY_*, this runtime.exs turns it into a mailer, and an unconfigured
  # deployment is left in the state OutboundMail.diagnose/0 refuses rather than
  # one that reports every send as successful.
  test "prod config builds an SMTP mailer from the Helm relay environment" do
    with_env("SMTP_RELAY_HOST", "smtp.example.com")
    with_env("SMTP_RELAY_PORT", "2525")
    with_env("SMTP_RELAY_USERNAME", "serviceradar")
    with_env("SMTP_RELAY_PASSWORD", "relay-password")

    mailer = read_prod_config()[:serviceradar_core][ServiceRadar.Mailer]

    assert mailer[:adapter] == Swoosh.Adapters.SMTP
    assert mailer[:relay] == "smtp.example.com"
    assert mailer[:port] == 2525
    assert mailer[:username] == "serviceradar"
    assert :ok = ServiceRadar.OutboundMail.diagnose(mailer)
  end

  test "prod config leaves an unconfigured deployment in a state that fails validation" do
    with_env("SMTP_RELAY_HOST", nil)
    with_env("SERVICERADAR_MAILER_ADAPTER", nil)
    with_env("SERVICERADAR_LOCAL_MAILER", nil)

    mailer = read_prod_config()[:serviceradar_core][ServiceRadar.Mailer]

    assert mailer[:adapter] == Swoosh.Adapters.Test

    assert {:error, {:non_delivering_adapter, message}} =
             ServiceRadar.OutboundMail.diagnose(mailer)

    assert message =~ "SMTP_RELAY_HOST"
  end

  test "prod config selects the local mailbox when SERVICERADAR_LOCAL_MAILER is set" do
    with_env("SERVICERADAR_LOCAL_MAILER", "true")

    mailer = read_prod_config()[:serviceradar_core][ServiceRadar.Mailer]

    assert mailer[:adapter] == Swoosh.Adapters.Local
  end

  test "prod config carries the seasonal disposition worker options" do
    opts =
      read_prod_config()[:serviceradar_core][
        ServiceRadar.Observability.SeasonalDisposition.Worker
      ]

    assert opts[:enabled] == true
    assert opts[:emit_verdicts?] == true
    assert opts[:seasonal_n_sigma] == 3.0
    assert opts[:min_bucket_samples] == 4
    assert opts[:confirm_slots] == 1
  end

  test "prod config parses capacity forecasting source opt-ins from env" do
    with_env("SERVICERADAR_CAPACITY_FORECASTING_SOURCE_OPT_INS", " cpu_usage, interface_rate ,")

    opts =
      read_prod_config()[:serviceradar_core][Worker]

    assert opts[:default_source_opt_ins] == ["cpu_usage", "interface_rate"]
  end

  test "prod config defaults capacity forecasting source opt-ins to empty" do
    with_env("SERVICERADAR_CAPACITY_FORECASTING_SOURCE_OPT_INS", nil)

    opts =
      read_prod_config()[:serviceradar_core][Worker]

    assert opts[:default_source_opt_ins] == []
  end

  test "prod EventWriter consumes analytics verdicts from the dedicated retention stream" do
    predictions = Enum.find(read_prod_event_writer_streams(), &(&1.name == "ANALYTICS_PREDICTIONS"))

    assert predictions, "missing ANALYTICS_PREDICTIONS EventWriter stream entry"

    # The release runtime.exs must splice the shared definition verbatim.
    assert predictions == EventWriterConfig.analytics_predictions_stream()

    assert predictions.stream_name == "analytics_predictions"
    assert predictions.subject == "signals.analytics.predictions.>"

    # Verdicts must survive core outages >30m: the shared events stream's
    # MaxAge is pinned to 30m by the otel collector, so the dedicated stream
    # carries its own bounded discard-old retention (1 GiB / 24h in ns).
    assert predictions.stream_retention == "limits"
    assert predictions.stream_storage == "file"
    assert predictions.stream_discard == "old"
    assert predictions.stream_max_bytes == 1_073_741_824
    assert predictions.stream_max_age == 86_400_000_000_000
  end

  test "prod EventWriter Falco consumer targets the provisioned events stream" do
    falco = Enum.find(read_prod_event_writer_streams(), &(&1.name == "FALCO"))

    assert falco, "missing FALCO EventWriter stream entry"

    # `falco_events`/`falco.>` never exists on deployments (constant 404
    # polls on demo); the working definition in serviceradar_core and
    # Config.default_streams/0 rides the shared events stream.
    assert falco.stream_name == "events"
    assert falco.subject == "falco.logs"
  end

  test "prod config exposes internal callback recovery without the bearer keyring" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "serviceradar-core-elx-callback-runtime-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    envelope_key = :crypto.strong_rand_bytes(32)
    keyring_path = Path.join(tmp_dir, "keyring.json")
    envelope_path = Path.join(tmp_dir, "envelope-key")

    File.write!(
      keyring_path,
      Jason.encode!(%{
        "active_key_id" => "callback-test",
        "keys" => %{"callback-test" => Base.encode64(:crypto.strong_rand_bytes(32))}
      })
    )

    File.write!(envelope_path, Base.encode64(envelope_key))
    File.chmod!(keyring_path, 0o600)
    File.chmod!(envelope_path, 0o600)

    with_env("SERVICERADAR_AUTOMATION_CALLBACK_HMAC_KEYRING_FILE", keyring_path)
    with_env("SERVICERADAR_AUTOMATION_CALLBACK_ENVELOPE_KEY_FILE", envelope_path)
    with_env("SERVICERADAR_AUTOMATION_CALLBACK_ENVELOPE_KEY_ID", "envelope-test")
    with_env("SERVICERADAR_AUTOMATION_CALLBACK_ORIGIN", "https://callbacks.example.test")
    with_env("SERVICERADAR_AUTOMATION_CALLBACKS_ENABLED", "false")

    core_config = read_prod_config()[:serviceradar_core]

    assert core_config[:automation_callback_grants] == []
    refute Keyword.has_key?(core_config, :automation_launch_envelope_key)
    refute Keyword.has_key?(core_config, :automation_launch_envelope_key_id)
    refute Keyword.has_key?(core_config, :automation_callback_origin)
  end

  test "prod config loads envelope custody and the non-secret continuation contract when enabled" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "serviceradar-core-elx-callback-policy-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    envelope_key = :crypto.strong_rand_bytes(32)
    envelope_path = Path.join(tmp_dir, "envelope-key")
    policy_path = Path.join(tmp_dir, "response-policy.json")
    File.write!(envelope_path, Base.encode64(envelope_key))
    File.write!(policy_path, Jason.encode!(response_policy_document()))
    File.chmod!(envelope_path, 0o600)
    File.chmod!(policy_path, 0o600)

    with_env("SERVICERADAR_AUTOMATION_CALLBACKS_ENABLED", "true")
    with_env("SERVICERADAR_AUTOMATION_CALLBACK_ENVELOPE_KEY_FILE", envelope_path)
    with_env("SERVICERADAR_AUTOMATION_CALLBACK_ENVELOPE_KEY_ID", "envelope-test")
    with_env("SERVICERADAR_AUTOMATION_CALLBACK_AWX_CREDENTIAL_TYPE_ID", "68")
    with_env("SERVICERADAR_AUTOMATION_CALLBACK_AWX_ORGANIZATION_ID", "3")

    with_env(
      "SERVICERADAR_AUTOMATION_CALLBACK_AWX_INJECTOR_DIGEST",
      String.duplicate("a", 64)
    )

    with_env("SERVICERADAR_AUTOMATION_CALLBACK_RESPONSE_POLICY_FILE", policy_path)

    core_config = read_prod_config()[:serviceradar_core]

    assert core_config[:automation_callback_grants] == []
    assert core_config[:automation_launch_envelope_key] == envelope_key
    assert core_config[:automation_launch_envelope_key_id] == "envelope-test"
    refute Keyword.has_key?(core_config, :automation_callback_origin)

    assert core_config[:automation_callback_awx_credential_contract] == [
             credential_type_id: 68,
             organization_id: 3,
             injector_digest: String.duplicate("a", 64)
           ]

    assert core_config[:automation_callback_response_policy_provider] ==
             FileCallbackResponsePolicyProvider

    assert core_config[FileCallbackResponsePolicyProvider] == [path: policy_path]
  end

  # Module-scoped blocks are the drift this file was written to catch, but the
  # original guard only covered the Oban crontab. These four are defined in
  # elixir/serviceradar_core/config/runtime.exs; a release evaluates ONLY its own
  # runtime.exs, so each has to be mirrored in this tree or its env vars are
  # silently inert in production -- Application.get_env/3 falls through to the
  # compiled default and nothing logs. Confirmed 2026-08-27 by RPC against the
  # deployed demo node, where the TopologyGraph block read back nil.
  #
  # Blocks deliberately absent because nothing in this release reaches them:
  # RemoteAccessSSHCACommandSigner, ServiceRadar.Edge.RemoteAccessSSHCertificates
  # and RootSpanRatioWorker.
  @mirrored_core_config_blocks [
    AgentCommandCleanupWorker,
    TopologyGraph,
    ServiceRadar.Observability.ThreatIntelRawPayloadStore,
    ServiceRadar.WorkloadIdentity
  ]

  @topology_graph TopologyGraph

  test "prod config mirrors every serviceradar_core module block the release reads" do
    config = read_prod_config()[:serviceradar_core]

    for module <- @mirrored_core_config_blocks do
      assert Keyword.keyword?(config[module]),
             "config :serviceradar_core, #{inspect(module)} is missing from this release's " <>
               "runtime.exs, so its env vars are inert in production"
    end
  end

  test "prod config wires the egress CONNECT proxy for external downloads" do
    with_env("SERVICERADAR_EGRESS_PROXY", "http://proxy.example.com:8080")

    assert read_prod_config()[:serviceradar_core][:egress_proxy] == %{
             scheme: :http,
             host: "proxy.example.com",
             port: 8080
           }
  end

  test "prod config leaves the egress proxy unset when the deployment has none" do
    with_env("SERVICERADAR_EGRESS_PROXY", nil)

    assert read_prod_config()[:serviceradar_core][:egress_proxy] == nil
  end

  test "canonical prune guard override is reachable from the environment" do
    refute read_prod_config()[:serviceradar_core][@topology_graph][:canonical_prune_guard_override]

    with_env("SERVICERADAR_TOPOLOGY_CANONICAL_PRUNE_GUARD_OVERRIDE", "true")

    assert read_prod_config()[:serviceradar_core][@topology_graph][:canonical_prune_guard_override]
  end

  test "canonical prune max fraction is reachable from the environment" do
    topology = read_prod_config()[:serviceradar_core][@topology_graph]
    assert topology[:canonical_prune_max_fraction] == 0.5

    with_env("SERVICERADAR_TOPOLOGY_CANONICAL_PRUNE_MAX_PERCENT", "80")

    assert read_prod_config()[:serviceradar_core][@topology_graph][:canonical_prune_max_fraction] ==
             0.8
  end

  test "agent command retention is reachable from the environment" do
    block = AgentCommandCleanupWorker
    assert read_prod_config()[:serviceradar_core][block][:retention_days] == 2

    with_env("AGENT_COMMAND_RETENTION_DAYS", "9")

    assert read_prod_config()[:serviceradar_core][block][:retention_days] == 9
  end

  defp read_prod_event_writer_streams do
    with_env("EVENT_WRITER_ENABLED", "true")

    read_prod_config()[:serviceradar_core][ServiceRadar.EventWriter][:streams] || []
  end

  defp with_env(name, value) do
    previous = System.get_env(name)

    case value do
      nil -> System.delete_env(name)
      _ -> System.put_env(name, value)
    end

    on_exit(fn ->
      case previous do
        nil -> System.delete_env(name)
        _ -> System.put_env(name, previous)
      end
    end)
  end

  defp read_prod_config do
    Config.Reader.read!(@runtime_config, env: :prod)
  end

  defp response_policy_document do
    %{
      "schema" => "serviceradar.automation.callback_response_policy/v1",
      "policies" => [
        %{
          "enabled" => true,
          "action" => "remote_access.ssh_ca.bundle.read",
          "action_version" => "1.0.0",
          "policy_version" => "ssh-policy-v1",
          "scope" => %{
            "tenant_id" => "platform",
            "controller_id" => "controller-farm01",
            "inventory_id" => 34,
            "job_template_id" => 42,
            "binding_id" => "binding-7",
            "binding_version" => 7,
            "approval_id" => "approval-8",
            "scm_revision" => String.duplicate("b", 40),
            "content_sha256" => String.duplicate("c", 64)
          },
          "review" => %{
            "state" => "approved",
            "reviewed_by_principal_type" => "human",
            "reviewed_by_principal_id" => "reviewer-1",
            "reviewed_at" => "2026-07-13T01:00:00.000000Z",
            "expires_at" => "2026-07-13T03:00:00.000000Z"
          },
          "signer_key_id" => "ca-main",
          "ca_keys" => [ca_key()],
          "targets" => [
            %{
              "state" => "ready",
              "target_identity" => %{
                "controller_id" => "controller-farm01",
                "inventory_id" => 34,
                "awx_host_id" => 100,
                "canonical_device_uid" => "device:linux-01"
              },
              "ca_key_ids" => ["ca-main"],
              "accounts" => [
                %{
                  "name" => "mfreeman",
                  "principals" => ["srp_v1_0123456789abcdefghijklmnop"]
                }
              ],
              "transaction" => %{}
            }
          ]
        }
      ]
    }
  end

  defp ca_key do
    type = "ssh-ed25519"
    key_bytes = :binary.copy(<<7>>, 32)
    blob = <<byte_size(type)::32, type::binary, byte_size(key_bytes)::32, key_bytes::binary>>

    %{
      "id" => "ca-main",
      "public_key" => type <> " " <> Base.encode64(blob),
      "fingerprint" => "SHA256:" <> Base.encode64(:crypto.hash(:sha256, blob), padding: false)
    }
  end
end
