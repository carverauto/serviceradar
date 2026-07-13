defmodule ServiceRadar.Observability.ProductionScheduleTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.AnomalyAddonConfigProjector
  alias ServiceRadar.Observability.AnomalyAlertLivenessWorker
  alias ServiceRadar.Observability.AnomalyEpisodeStaleCloseWorker
  alias ServiceRadar.Observability.AnomalyIngestSilenceWorker
  alias ServiceRadar.Observability.ProductionSchedule
  alias ServiceRadar.Observability.ResolveStaleAnomaliesWorker
  alias ServiceRadar.Observability.SeasonalBaselineFreshnessWorker
  alias ServiceRadar.Observability.SeasonalDisposition

  defp fetch(env) when is_map(env) do
    fn name, default -> Map.get(env, name, default) end
  end

  defp crons_by_worker(entries) do
    Map.new(entries, fn
      {cron, worker} -> {worker, {cron, []}}
      {cron, worker, opts} -> {worker, {cron, opts}}
    end)
  end

  describe "cron_entries/1" do
    test "schedules every anomaly worker under default env" do
      entries = ProductionSchedule.cron_entries(fetch(%{}))
      by_worker = crons_by_worker(entries)

      assert {"47 * * * *", opts} = by_worker[SeasonalDisposition.Worker]
      assert opts[:args] == %{"trigger" => "cron"}
      assert opts[:queue] == :maintenance

      assert {"53 * * * *", opts} = by_worker[SeasonalDisposition.EdgeBaselineProducer]
      assert opts[:args] == %{"trigger" => "cron"}
      assert opts[:queue] == :maintenance

      assert {"*/5 * * * *", opts} = by_worker[AnomalyEpisodeStaleCloseWorker]
      assert opts[:queue] == :maintenance

      assert {"*/30 * * * *", opts} = by_worker[ResolveStaleAnomaliesWorker]
      assert opts[:queue] == :maintenance
    end

    test "schedules the liveness tripwires under default env" do
      by_worker = crons_by_worker(ProductionSchedule.cron_entries(fetch(%{})))

      assert {"23 */6 * * *", opts} = by_worker[AnomalyAlertLivenessWorker]
      assert opts[:queue] == :maintenance

      assert {"7 * * * *", opts} = by_worker[AnomalyIngestSilenceWorker]
      assert opts[:queue] == :maintenance

      assert {"37 * * * *", opts} = by_worker[SeasonalBaselineFreshnessWorker]
      assert opts[:queue] == :maintenance
    end

    test "honors tripwire cron override envs" do
      env = %{
        "SERVICERADAR_ANOMALY_LIVENESS_CRON" => "4 * * * *",
        "SERVICERADAR_ANOMALY_SILENCE_TRIPWIRE_CRON" => "5 * * * *",
        "SERVICERADAR_SEASONAL_BASELINE_TRIPWIRE_CRON" => "6 * * * *"
      }

      by_worker = crons_by_worker(ProductionSchedule.cron_entries(fetch(env)))

      assert {"4 * * * *", _} = by_worker[AnomalyAlertLivenessWorker]
      assert {"5 * * * *", _} = by_worker[AnomalyIngestSilenceWorker]
      assert {"6 * * * *", _} = by_worker[SeasonalBaselineFreshnessWorker]
    end

    test "each tripwire can be disabled independently" do
      env = %{
        "SERVICERADAR_ANOMALY_LIVENESS_ENABLED" => "false",
        "SERVICERADAR_ANOMALY_SILENCE_TRIPWIRE_ENABLED" => "0",
        "SERVICERADAR_SEASONAL_BASELINE_TRIPWIRE_ENABLED" => "no"
      }

      by_worker = crons_by_worker(ProductionSchedule.cron_entries(fetch(env)))

      refute Map.has_key?(by_worker, AnomalyAlertLivenessWorker)
      refute Map.has_key?(by_worker, AnomalyIngestSilenceWorker)
      refute Map.has_key?(by_worker, SeasonalBaselineFreshnessWorker)
      assert Map.has_key?(by_worker, AnomalyEpisodeStaleCloseWorker)
    end

    test "disabling the baseline producer also drops the freshness tripwire" do
      for env <- [
            %{"SERVICERADAR_SEASONAL_DISPOSITION_ENABLED" => "false"},
            %{"SERVICERADAR_SEASONAL_EDGE_BASELINE_ENABLED" => "false"}
          ] do
        by_worker = crons_by_worker(ProductionSchedule.cron_entries(fetch(env)))

        refute Map.has_key?(by_worker, SeasonalDisposition.EdgeBaselineProducer)
        refute Map.has_key?(by_worker, SeasonalBaselineFreshnessWorker)
        assert Map.has_key?(by_worker, AnomalyAlertLivenessWorker)
        assert Map.has_key?(by_worker, AnomalyIngestSilenceWorker)
      end
    end

    test "edge config projection defaults on" do
      by_worker = crons_by_worker(ProductionSchedule.cron_entries(fetch(%{})))

      assert {"57 * * * *", opts} = by_worker[AnomalyAddonConfigProjector]
      assert opts[:args] == %{"trigger" => "cron"}
      assert opts[:queue] == :maintenance
    end

    test "honors cron override envs" do
      env = %{
        "SERVICERADAR_SEASONAL_DISPOSITION_CRON" => "1 * * * *",
        "SERVICERADAR_SEASONAL_EDGE_BASELINE_CRON" => "2 * * * *",
        "SERVICERADAR_ANOMALY_EDGE_CONFIG_PROJECTION_CRON" => "3 * * * *"
      }

      by_worker = crons_by_worker(ProductionSchedule.cron_entries(fetch(env)))

      assert {"1 * * * *", _} = by_worker[SeasonalDisposition.Worker]
      assert {"2 * * * *", _} = by_worker[SeasonalDisposition.EdgeBaselineProducer]
      assert {"3 * * * *", _} = by_worker[AnomalyAddonConfigProjector]
    end

    test "disabling seasonal disposition also drops the edge baseline producer" do
      env = %{"SERVICERADAR_SEASONAL_DISPOSITION_ENABLED" => "false"}
      by_worker = crons_by_worker(ProductionSchedule.cron_entries(fetch(env)))

      refute Map.has_key?(by_worker, SeasonalDisposition.Worker)
      refute Map.has_key?(by_worker, SeasonalDisposition.EdgeBaselineProducer)
      assert Map.has_key?(by_worker, AnomalyAddonConfigProjector)
      assert Map.has_key?(by_worker, AnomalyEpisodeStaleCloseWorker)
      assert Map.has_key?(by_worker, ResolveStaleAnomaliesWorker)
    end

    test "edge baseline producer can be disabled independently" do
      env = %{"SERVICERADAR_SEASONAL_EDGE_BASELINE_ENABLED" => "0"}
      by_worker = crons_by_worker(ProductionSchedule.cron_entries(fetch(env)))

      assert Map.has_key?(by_worker, SeasonalDisposition.Worker)
      refute Map.has_key?(by_worker, SeasonalDisposition.EdgeBaselineProducer)
    end

    test "edge config projection can be disabled" do
      env = %{"SERVICERADAR_ANOMALY_EDGE_CONFIG_PROJECTION" => "false"}
      by_worker = crons_by_worker(ProductionSchedule.cron_entries(fetch(env)))

      refute Map.has_key?(by_worker, AnomalyAddonConfigProjector)
    end

    test "stale-close and resolve-stale entries are unconditional" do
      env = %{
        "SERVICERADAR_SEASONAL_DISPOSITION_ENABLED" => "false",
        "SERVICERADAR_ANOMALY_EDGE_CONFIG_PROJECTION" => "false"
      }

      by_worker = crons_by_worker(ProductionSchedule.cron_entries(fetch(env)))

      assert Map.has_key?(by_worker, AnomalyEpisodeStaleCloseWorker)
      assert Map.has_key?(by_worker, ResolveStaleAnomaliesWorker)
    end
  end

  describe "seasonal_disposition_worker_config/1" do
    test "defaults" do
      config = ProductionSchedule.seasonal_disposition_worker_config(fetch(%{}))

      assert config[:enabled] == true
      assert config[:emit_verdicts?] == true
      assert config[:seasonal_n_sigma] == 3.0
      assert config[:min_bucket_samples] == 4
      assert config[:confirm_slots] == 1
    end

    test "env overrides" do
      env = %{
        "SERVICERADAR_SEASONAL_DISPOSITION_ENABLED" => "false",
        "SERVICERADAR_SEASONAL_DISPOSITION_EMIT_VERDICTS" => "no",
        "SERVICERADAR_SEASONAL_DISPOSITION_N_SIGMA" => "2.5",
        "SERVICERADAR_SEASONAL_DISPOSITION_MIN_BUCKET_SAMPLES" => "6",
        "SERVICERADAR_SEASONAL_DISPOSITION_CONFIRM_SLOTS" => "2"
      }

      config = ProductionSchedule.seasonal_disposition_worker_config(fetch(env))

      assert config[:enabled] == false
      assert config[:emit_verdicts?] == false
      assert config[:seasonal_n_sigma] == 2.5
      assert config[:min_bucket_samples] == 6
      assert config[:confirm_slots] == 2
    end

    test "integer-formatted n_sigma parses as a float" do
      env = %{"SERVICERADAR_SEASONAL_DISPOSITION_N_SIGMA" => "3"}
      config = ProductionSchedule.seasonal_disposition_worker_config(fetch(env))

      assert config[:seasonal_n_sigma] == 3.0
    end

    test "fractional n_sigma parses" do
      env = %{"SERVICERADAR_SEASONAL_DISPOSITION_N_SIGMA" => "3.5"}
      config = ProductionSchedule.seasonal_disposition_worker_config(fetch(env))

      assert config[:seasonal_n_sigma] == 3.5
    end

    test "blank numeric envs fall back to the defaults" do
      env = %{
        "SERVICERADAR_SEASONAL_DISPOSITION_N_SIGMA" => "",
        "SERVICERADAR_SEASONAL_DISPOSITION_MIN_BUCKET_SAMPLES" => "",
        "SERVICERADAR_SEASONAL_DISPOSITION_CONFIRM_SLOTS" => ""
      }

      config = ProductionSchedule.seasonal_disposition_worker_config(fetch(env))

      assert config[:seasonal_n_sigma] == 3.0
      assert config[:min_bucket_samples] == 4
      assert config[:confirm_slots] == 1
    end

    test "raises a named ArgumentError on garbage numeric envs" do
      assert_raise ArgumentError, ~r/SERVICERADAR_SEASONAL_DISPOSITION_N_SIGMA.*"garbage"/, fn ->
        ProductionSchedule.seasonal_disposition_worker_config(
          fetch(%{"SERVICERADAR_SEASONAL_DISPOSITION_N_SIGMA" => "garbage"})
        )
      end

      assert_raise ArgumentError,
                   ~r/SERVICERADAR_SEASONAL_DISPOSITION_MIN_BUCKET_SAMPLES/,
                   fn ->
                     ProductionSchedule.seasonal_disposition_worker_config(
                       fetch(%{"SERVICERADAR_SEASONAL_DISPOSITION_MIN_BUCKET_SAMPLES" => "4.5"})
                     )
                   end

      assert_raise ArgumentError, ~r/SERVICERADAR_SEASONAL_DISPOSITION_CONFIRM_SLOTS/, fn ->
        ProductionSchedule.seasonal_disposition_worker_config(
          fetch(%{"SERVICERADAR_SEASONAL_DISPOSITION_CONFIRM_SLOTS" => "two"})
        )
      end
    end
  end

  describe "app_env/1" do
    test "returns nothing when the operator sets no env" do
      assert ProductionSchedule.app_env(fetch(%{})) == []
    end

    test "treats blank values as unset" do
      env = %{
        "SERVICERADAR_STALE_ANOMALY_RESOLVE_HOURS" => "",
        "SERVICERADAR_ANOMALY_EPISODE_STALE_AFTER_MINUTES" => ""
      }

      assert ProductionSchedule.app_env(fetch(env)) == []
    end

    test "returns operator-set stale thresholds" do
      env = %{
        "SERVICERADAR_STALE_ANOMALY_RESOLVE_HOURS" => "12",
        "SERVICERADAR_ANOMALY_EPISODE_STALE_AFTER_MINUTES" => "90"
      }

      config = ProductionSchedule.app_env(fetch(env))

      assert config[:stale_anomaly_resolve_hours] == 12
      assert config[:anomaly_episode_stale_after_minutes] == 90
    end

    test "returns operator-set tripwire thresholds" do
      env = %{
        "SERVICERADAR_ANOMALY_SILENCE_HOURS" => "3",
        "SERVICERADAR_SEASONAL_BASELINE_FRESHNESS_HOURS" => "50"
      }

      config = ProductionSchedule.app_env(fetch(env))

      assert config[:anomaly_silence_hours] == 3
      assert config[:seasonal_baseline_freshness_hours] == 50
    end

    test "returns operator-set episode liveness knobs" do
      env = %{
        "SERVICERADAR_STALE_ANOMALY_EPISODE_FRESHNESS_HOURS" => "8",
        "SERVICERADAR_STALE_ANOMALY_EPISODE_LIVENESS_CHECK" => "false"
      }

      config = ProductionSchedule.app_env(fetch(env))

      assert config[:stale_anomaly_episode_freshness_hours] == 8
      assert Keyword.fetch(config, :stale_anomaly_episode_liveness_check) == {:ok, false}
    end

    test "episode liveness check accepts truthy spellings" do
      for value <- ["1", "true", "yes", "on", "TRUE"] do
        env = %{"SERVICERADAR_STALE_ANOMALY_EPISODE_LIVENESS_CHECK" => value}

        assert ProductionSchedule.app_env(fetch(env)) ==
                 [stale_anomaly_episode_liveness_check: true]
      end
    end

    test "blank episode liveness knobs stay unset" do
      env = %{
        "SERVICERADAR_STALE_ANOMALY_EPISODE_FRESHNESS_HOURS" => "",
        "SERVICERADAR_STALE_ANOMALY_EPISODE_LIVENESS_CHECK" => ""
      }

      assert ProductionSchedule.app_env(fetch(env)) == []
    end

    test "raises on non-positive or malformed values" do
      for value <- ["0", "-3", "abc", "6h"] do
        env = %{"SERVICERADAR_STALE_ANOMALY_RESOLVE_HOURS" => value}

        assert_raise ArgumentError, fn -> ProductionSchedule.app_env(fetch(env)) end
      end

      for value <- ["0", "-8", "abc"] do
        env = %{"SERVICERADAR_STALE_ANOMALY_EPISODE_FRESHNESS_HOURS" => value}

        assert_raise ArgumentError, fn -> ProductionSchedule.app_env(fetch(env)) end
      end

      assert_raise ArgumentError,
                   ~r/SERVICERADAR_STALE_ANOMALY_EPISODE_LIVENESS_CHECK.*"maybe"/,
                   fn ->
                     ProductionSchedule.app_env(
                       fetch(%{"SERVICERADAR_STALE_ANOMALY_EPISODE_LIVENESS_CHECK" => "maybe"})
                     )
                   end
    end
  end

  describe "capacity_source_opt_ins/1" do
    test "parses the comma-separated env value, trimming blanks" do
      env = %{
        "SERVICERADAR_CAPACITY_FORECASTING_SOURCE_OPT_INS" => " cpu_usage, interface_rate ,,"
      }

      assert ProductionSchedule.capacity_source_opt_ins(fetch(env)) ==
               ["cpu_usage", "interface_rate"]
    end

    test "defaults to an empty list when unset or blank" do
      assert ProductionSchedule.capacity_source_opt_ins(fetch(%{})) == []

      env = %{"SERVICERADAR_CAPACITY_FORECASTING_SOURCE_OPT_INS" => ""}
      assert ProductionSchedule.capacity_source_opt_ins(fetch(env)) == []
    end

    test "passes unknown names through for the worker's run-time validation" do
      env = %{"SERVICERADAR_CAPACITY_FORECASTING_SOURCE_OPT_INS" => "bogus_source"}

      assert ProductionSchedule.capacity_source_opt_ins(fetch(env)) == ["bogus_source"]
    end
  end
end
