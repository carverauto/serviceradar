defmodule ServiceRadarCoreElx.ProductionRuntimeConfigTest do
  # Guard against config drift between serviceradar_core and this release
  # wrapper: the deployed image only evaluates THIS tree's runtime.exs, so a
  # worker scheduled solely in serviceradar_core/config/runtime.exs never runs
  # in production. Evaluates the release runtime config the way a prod boot
  # would (required env stubbed) and asserts the Oban crontab is complete.
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.CapacityForecasting.Worker

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)

  @required_production_workers [
    ServiceRadar.Jobs.AlertsRetentionWorker,
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
    assert predictions == ServiceRadar.EventWriter.Config.analytics_predictions_stream()

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
end
