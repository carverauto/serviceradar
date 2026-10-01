defmodule ServiceRadar.ColdTier.WarehouseBackfillDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.ColdTier.Boundary
  alias ServiceRadar.ColdTier.Exporter
  alias ServiceRadar.ColdTier.Health
  alias ServiceRadar.ColdTier.RetentionFence
  alias ServiceRadar.Infrastructure.HealthPubSub
  alias ServiceRadar.Infrastructure.HealthTracker
  alias ServiceRadar.TestSupport.ColdTierRuntimeConfig

  @moduletag :integration

  setup do
    keys = [ServiceRadar.ColdTier, StarRocks, :repo_enabled]
    original = Map.new(keys, &{&1, Application.get_env(:serviceradar_core, &1)})

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> Application.delete_env(:serviceradar_core, key)
        {key, value} -> Application.put_env(:serviceradar_core, key, value)
      end)
    end)

    Application.put_env(:serviceradar_core, ServiceRadar.ColdTier,
      enabled: true,
      bucket_url: "s3://synthetic-cold",
      head_host: "head.example.com",
      primary_host: "primary.example.com"
    )

    Application.put_env(:serviceradar_core, StarRocks, enabled: false)
    Application.put_env(:serviceradar_core, :repo_enabled, true)
    :ok
  end

  test "backend metadata stays current without repeating health transitions" do
    full = %{
      "SERVICERADAR_COLD_TIER_ENABLED" => "true",
      "SERVICERADAR_COLD_TIER_BUCKET_URL" => "s3://synthetic-history",
      "SERVICERADAR_COLD_TIER_HEAD_HOST" => "archive.example.com",
      "SERVICERADAR_COLD_TIER_PRIMARY_HOST" => "database.example.com"
    }

    incomplete = Map.delete(full, "SERVICERADAR_COLD_TIER_HEAD_HOST")
    disabled = %{}
    runtime = ColdTierRuntimeConfig.read!(disabled)
    Application.put_env(:serviceradar_core, ServiceRadar.ColdTier, runtime[ServiceRadar.ColdTier])

    crontab =
      Enum.find_value(runtime[Oban][:plugins], fn
        {Oban.Plugins.Cron, options} -> Keyword.fetch!(options, :crontab)
        _other -> nil
      end)

    {_schedule, reporter, _options} = Enum.find(crontab, &(elem(&1, 1) == Exporter))
    assert :ok = reporter.perform(%Oban.Job{})
    assert {:ok, initial} = HealthTracker.current_status(:core, "cold-tier-backend")
    :ok = Phoenix.PubSub.subscribe(ServiceRadar.PubSub, HealthPubSub.topic())

    Enum.reduce(
      [
        {full, false, "enabled", true, :healthy, "enabled"},
        {incomplete, false, "misconfigured", false, :healthy, "misconfigured"},
        {incomplete, true, "misconfigured", false, :unhealthy, "unavailable_with_starrocks"},
        {full, true, "cnpg_backfill", true, :unhealthy, "unavailable_with_starrocks"},
        {incomplete, true, "misconfigured", false, :unhealthy, "unavailable_with_starrocks"},
        {disabled, true, "disabled", false, :healthy, "disabled"},
        {disabled, false, "disabled", false, :healthy, "disabled"},
        {full, false, "enabled", true, :healthy, "enabled"},
        {full, true, "cnpg_backfill", true, :unhealthy, "unavailable_with_starrocks"},
        {full, false, "enabled", true, :healthy, "enabled"}
      ],
      initial,
      fn {cfg, warehouse?, mode, export_enabled?, state, archival_status}, previous ->
        runtime =
          cfg
          |> Map.put("SERVICERADAR_STARROCKS_ENABLED", to_string(warehouse?))
          |> ColdTierRuntimeConfig.read!()

        Application.put_env(
          :serviceradar_core,
          ServiceRadar.ColdTier,
          runtime[ServiceRadar.ColdTier]
        )

        Application.put_env(:serviceradar_core, StarRocks, runtime[StarRocks])

        record_backend = fn ->
          if export_enabled?, do: Health.record_backend(), else: reporter.perform(%Oban.Job{})
        end

        assert :ok = record_backend.()
        assert {:ok, event} = HealthTracker.current_status(:core, "cold-tier-backend")
        refute event.id == previous.id
        assert event.new_state == state
        assert event.old_state == previous.new_state
        assert event.metadata["mode"] == mode

        assert event.metadata["telemetry_backend"] ==
                 if(warehouse?, do: "starrocks", else: "cnpg")

        assert event.metadata["cnpg_export_enabled"] == export_enabled?
        assert event.metadata["export_source"] == "cnpg"
        assert event.metadata["warehouse_export_enabled"] == false
        assert Enum.any?(event.metadata["datasets"], &(&1["table"] == "logs"))
        assert Enum.any?(event.metadata["datasets"], &(&1["table"] == "otel_traces"))
        assert Enum.all?(event.metadata["datasets"], &(&1["archival_status"] == archival_status))

        if previous.new_state == state do
          refute_receive {:health_event, %{entity_id: "cold-tier-backend"}}
        else
          assert_receive {:health_event, ^event}
        end

        assert :ok = record_backend.()
        assert {:ok, repeated} = HealthTracker.current_status(:core, "cold-tier-backend")
        assert repeated.id == event.id
        refute_receive {:health_event, %{entity_id: "cold-tier-backend"}}
        event
      end
    )
  end

  test "warehouse switch and disabled backfill cannot release unacknowledged CNPG history" do
    Boundary
    |> Ash.Changeset.for_create(:create, %{
      table_name: "logs",
      frontier: nil,
      query_boundary: nil,
      boundary_acked_at: nil
    })
    |> Ash.create!(actor: SystemActor.system(:cold_tier_test))

    assert RetentionFence.fenced?("logs")
    assert RetentionFence.safe_drop_point("logs", 30) == :hold

    Application.put_env(:serviceradar_core, StarRocks, enabled: true)

    assert RetentionFence.fenced?("logs")
    assert RetentionFence.safe_drop_point("logs", 30) == :hold

    Application.put_env(:serviceradar_core, ServiceRadar.ColdTier, enabled: false)

    assert RetentionFence.fenced?("logs")
    assert "logs" in RetentionFence.undrained_tables()
    assert RetentionFence.safe_drop_point("logs", 30) == :hold
  end
end
