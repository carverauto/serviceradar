defmodule ServiceRadar.ColdTier.StateTest do
  @moduledoc """
  The single cold-tier activation state (review F09). The load-bearing
  invariant: the retention fence and the exporter must agree, so a partial
  config can never fence retention while the exporter is unable to run.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.ColdTier.Config
  alias ServiceRadar.ColdTier.Exporter
  alias ServiceRadar.ColdTier.Pruner
  alias ServiceRadar.ColdTier.RetentionFence
  alias ServiceRadar.TestSupport.ColdTierRuntimeConfig

  @full_env %{
    "SERVICERADAR_COLD_TIER_ENABLED" => "true",
    "SERVICERADAR_COLD_TIER_BUCKET_URL" => "s3://synthetic-cold",
    "SERVICERADAR_COLD_TIER_HEAD_HOST" => "head.example.com",
    "SERVICERADAR_COLD_TIER_PRIMARY_HOST" => "primary.example.com"
  }

  @full [
    enabled: true,
    bucket_url: "s3://tenant-cold",
    s3_endpoint: "obj.example",
    s3_region: "us-east-1",
    s3_access_key_id: "k",
    s3_secret_access_key: "s",
    head_host: "cnpg-analytics",
    head_database: "serviceradar",
    head_username: "serviceradar",
    head_password: "p",
    primary_host: "cnpg",
    primary_database: "serviceradar",
    primary_fdw_username: "cold_reader",
    primary_fdw_password: "p"
  ]

  setup do
    original = Application.get_env(:serviceradar_core, ServiceRadar.ColdTier)
    starrocks = Application.get_env(:serviceradar_core, StarRocks)
    Application.put_env(:serviceradar_core, StarRocks, enabled: false)

    on_exit(fn ->
      restore(original)

      if is_nil(starrocks) do
        Application.delete_env(:serviceradar_core, StarRocks)
      else
        Application.put_env(:serviceradar_core, StarRocks, starrocks)
      end
    end)

    :ok
  end

  defp put(cfg), do: Application.put_env(:serviceradar_core, ServiceRadar.ColdTier, cfg)
  defp restore(nil), do: Application.delete_env(:serviceradar_core, ServiceRadar.ColdTier)
  defp restore(cfg), do: Application.put_env(:serviceradar_core, ServiceRadar.ColdTier, cfg)

  test "shipped runtime activates CNPG archival and schedules its guarded workers" do
    for {environment, state, enabled?} <- [
          {%{}, :disabled, false},
          {@full_env, :enabled, true},
          {Map.put(@full_env, "SERVICERADAR_COLD_TIER_HEAD_HOST", nil), :misconfigured, false},
          {Map.put(@full_env, "SERVICERADAR_COLD_TIER_BUCKET_URL", ""), :disabled, false},
          {Map.put(@full_env, "SERVICERADAR_STARROCKS_ENABLED", "true"), :cnpg_backfill, true}
        ] do
      runtime = ColdTierRuntimeConfig.read!(environment)
      put(runtime[ServiceRadar.ColdTier])

      Application.put_env(
        :serviceradar_core,
        StarRocks,
        runtime[StarRocks]
      )

      assert Config.state() == state
      assert Config.enabled?() == enabled?
      assert runtime[ServiceRadar.ColdTier][:cold_windows] == []

      crontab =
        Enum.find_value(runtime[Oban][:plugins], fn
          {Oban.Plugins.Cron, options} -> Keyword.fetch!(options, :crontab)
          _other -> nil
        end)

      assert {"47 * * * *", Exporter, [queue: :maintenance]} in crontab
      assert {"23 4 * * *", Pruner, [queue: :maintenance]} in crontab
      assert Enum.count(crontab, &(elem(&1, 1) == Exporter)) == 1
      assert Enum.count(crontab, &(elem(&1, 1) == Pruner)) == 1
      assert runtime[Oban][:queues][:maintenance] > 0
    end
  end

  @tag :tmp_dir
  test "both runtime paths preserve cold settings and mounted secrets", %{tmp_dir: tmp_dir} do
    secrets = %{
      "SERVICERADAR_COLD_TIER_S3_ACCESS_KEY_ID" => "synthetic-key",
      "SERVICERADAR_COLD_TIER_S3_SECRET_ACCESS_KEY" => "synthetic-secret",
      "SERVICERADAR_COLD_TIER_HEAD_PASSWORD" => "synthetic-head-password",
      "SERVICERADAR_COLD_TIER_PRIMARY_FDW_PASSWORD" => "synthetic-primary-password"
    }

    files =
      Map.new(secrets, fn {name, value} ->
        path = Path.join(tmp_dir, name)
        File.write!(path, value <> "\n")
        {name <> "_FILE", path}
      end)

    environment =
      @full_env
      |> Map.merge(files)
      |> Map.merge(%{
        "SERVICERADAR_COLD_TIER_S3_ACCESS_KEY_ID" => "superseded-key",
        "SERVICERADAR_COLD_TIER_S3_ENDPOINT" => "https://objects.example.com",
        "SERVICERADAR_COLD_TIER_S3_ENDPOINT_RUNTIME" => "https://runtime-objects.example.com",
        "SERVICERADAR_COLD_TIER_S3_REGION" => "synthetic-region",
        "SERVICERADAR_COLD_TIER_S3_URL_STYLE" => "path",
        "SERVICERADAR_COLD_TIER_S3_USE_SSL" => "false",
        "SERVICERADAR_COLD_TIER_HEAD_PORT" => "15432",
        "SERVICERADAR_COLD_TIER_HEAD_DATABASE" => "archive",
        "SERVICERADAR_COLD_TIER_HEAD_USERNAME" => "archive_reader",
        "SERVICERADAR_COLD_TIER_PRIMARY_PORT" => "15433",
        "SERVICERADAR_COLD_TIER_PRIMARY_DATABASE" => "telemetry",
        "SERVICERADAR_COLD_TIER_PRIMARY_FDW_USERNAME" => "telemetry_reader",
        "SERVICERADAR_COLD_EXPORT_LAG_HOURS" => "72",
        "SERVICERADAR_COLD_QUARANTINE_ATTEMPTS" => "7",
        "SERVICERADAR_COLD_RUN_CHUNK_BUDGET" => "32",
        "SERVICERADAR_COLD_WINDOW_LOGS_DAYS" => "180",
        "SERVICERADAR_COLD_WINDOW_TIMESERIES_DAYS" => "365"
      })

    for runtime <- [:core, :release] do
      cold = ColdTierRuntimeConfig.read!(environment, runtime)[ServiceRadar.ColdTier]
      put(cold)
      assert Config.state() == :enabled
      assert Config.export_lag_hours() == 72
      assert Config.quarantine_attempts() == 7
      assert Config.run_chunk_budget() == 32
      assert Config.runtime_s3_endpoint() == "https://runtime-objects.example.com"
      assert cold[:cold_windows] == [logs: 180, timeseries: 365]
      assert {:ok, s3} = Config.s3()
      assert s3.endpoint == "https://objects.example.com"
      assert s3.region == "synthetic-region"
      assert s3.url_style == "path"
      refute s3.use_ssl
      assert s3.access_key_id == "synthetic-key"
      assert s3.secret_access_key == "synthetic-secret"
      assert {:ok, head} = Config.head_opts()
      assert head[:port] == 15_432
      assert head[:database] == "archive"
      assert head[:username] == "archive_reader"
      assert head[:password] == "synthetic-head-password"
      assert {:ok, primary} = Config.primary_fdw()
      assert primary.port == 15_433
      assert primary.dbname == "telemetry"
      assert primary.username == "telemetry_reader"
      assert primary.password == "synthetic-primary-password"
    end
  end

  test "no intent is :disabled" do
    put(enabled: false, bucket_url: "s3://x")
    assert Config.state() == :disabled
    refute Config.enabled?()
    refute Config.intended?()

    put(enabled: true, bucket_url: "")
    assert Config.state() == :disabled
  end

  test "full config is :enabled" do
    put(@full)
    assert Config.state() == :enabled
    assert Config.enabled?()
    assert Config.intended?()
    assert Config.misconfiguration_reasons() == []
  end

  test "intended but incomplete is :misconfigured, and names what is missing" do
    put(Keyword.drop(@full, [:head_host, :primary_host]))

    assert Config.state() == :misconfigured
    # Misconfigured is NOT enabled — the fence and exporter both stand down,
    # so retention proceeds normally and the primary cannot fill (F09).
    refute Config.enabled?()
    # But intent is still true, so the deployment believes offload is on.
    assert Config.intended?()

    reasons = Config.misconfiguration_reasons()
    assert :analytics_head in reasons
    assert :primary_fdw in reasons
    refute :object_store in reasons
  end

  test "StarRocks preserves configured CNPG backfill and its retention fence" do
    put(@full)
    Application.put_env(:serviceradar_core, StarRocks, enabled: true)

    assert Config.state() == :cnpg_backfill
    assert Config.enabled?()
    assert RetentionFence.fenced?("logs")
    assert RetentionFence.undrained_tables() == []
    refute RetentionFence.fenced?("devices")
  end
end
