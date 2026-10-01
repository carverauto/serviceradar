defmodule ServiceRadar.ColdTier.WarehouseBackfillDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.ColdTier.Boundary
  alias ServiceRadar.ColdTier.RetentionFence

  @moduletag :integration

  setup do
    keys = [ServiceRadar.ColdTier, ServiceRadar.Analytics.StarRocks]
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
    :ok
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
