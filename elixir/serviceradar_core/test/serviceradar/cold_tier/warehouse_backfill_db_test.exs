defmodule ServiceRadar.ColdTier.WarehouseBackfillDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.ColdTier.Boundary
  alias ServiceRadar.ColdTier.Health
  alias ServiceRadar.ColdTier.RetentionFence
  alias ServiceRadar.Infrastructure.HealthPubSub
  alias ServiceRadar.Infrastructure.HealthTracker

  @moduletag :integration

  setup do
    keys = [ServiceRadar.ColdTier, ServiceRadar.Analytics.StarRocks, :repo_enabled]
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

    Application.put_env(:serviceradar_core, ServiceRadar.Analytics.StarRocks, enabled: false)
    Application.put_env(:serviceradar_core, :repo_enabled, true)
    :ok
  end

  test "backend metadata stays current without repeating health transitions" do
    full = Application.fetch_env!(:serviceradar_core, ServiceRadar.ColdTier)
    incomplete = Keyword.delete(full, :head_host)
    disabled = [enabled: false]

    Application.put_env(:serviceradar_core, ServiceRadar.ColdTier, disabled)
    assert :ok = Health.record_backend()
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
        Application.put_env(:serviceradar_core, ServiceRadar.ColdTier, cfg)

        Application.put_env(:serviceradar_core, ServiceRadar.Analytics.StarRocks,
          enabled: warehouse?
        )

        assert :ok = Health.record_backend()
        assert {:ok, event} = HealthTracker.current_status(:core, "cold-tier-backend")
        refute event.id == previous.id
        assert event.new_state == state
        assert event.old_state == previous.new_state
        assert event.metadata["mode"] == mode
        assert event.metadata["telemetry_backend"] == if(warehouse?, do: "starrocks", else: "cnpg")
        assert event.metadata["cnpg_export_enabled"] == export_enabled?
        assert event.metadata["export_source"] == "cnpg"
        assert event.metadata["warehouse_export_enabled"] == false
        assert event.metadata["datasets"] != []
        assert Enum.all?(event.metadata["datasets"], &(&1["archival_status"] == archival_status))

        if previous.new_state == state do
          refute_receive {:health_event, %{entity_id: "cold-tier-backend"}}
        else
          assert_receive {:health_event, ^event}
        end

        assert :ok = Health.record_backend()
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

    Application.put_env(:serviceradar_core, ServiceRadar.Analytics.StarRocks, enabled: true)

    assert RetentionFence.fenced?("logs")
    assert RetentionFence.safe_drop_point("logs", 30) == :hold

    Application.put_env(:serviceradar_core, ServiceRadar.ColdTier, enabled: false)

    assert RetentionFence.fenced?("logs")
    assert "logs" in RetentionFence.undrained_tables()
    assert RetentionFence.safe_drop_point("logs", 30) == :hold
  end
end
