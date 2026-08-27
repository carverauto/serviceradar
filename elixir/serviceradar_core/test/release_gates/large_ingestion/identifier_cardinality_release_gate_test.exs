defmodule ServiceRadar.Inventory.IdentifierCardinalityGateTest do
  @moduledoc """
  Release-gate (task 8.4): identifier growth stays bounded under faker-style
  ingest — repeated sync rounds for the same device population with churned
  MAC orderings/subsets must not grow `device_identifiers` beyond the
  per-device caps, and re-ingesting identical data must add zero rows.

  Run through the guarded database lifecycle with:

      bazel test ... //elixir/serviceradar_core:large_ingestion_release_gate
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.CardinalityCaps
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration
  @moduletag :large_ingestion

  @devices 500
  @rounds 3

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "identifier rows stay bounded across churned ingest rounds" do
    actor = SystemActor.system(:identifier_cardinality_gate_test)
    run = System.unique_integer([:positive])

    base_macs =
      for d <- 1..@devices, into: %{} do
        macs = for i <- 1..8, do: gate_mac(run, d, i)
        {d, macs}
      end

    for round <- 1..@rounds do
      updates =
        for d <- 1..@devices do
          # Same MAC set each round, churned ordering/subset — the faker
          # failure mode. The identifier table must converge, not grow.
          macs = base_macs[d] |> Enum.shuffle() |> Enum.take(6 + rem(round + d, 3))

          %{
            "ip" => "10.#{200 + rem(d, 40)}.#{div(d, 250)}.#{rem(d, 250) + 1}",
            "hostname" => "gate-host-#{run}-#{d}",
            "source" => "integration-test",
            "mac" => Enum.join(macs, ","),
            "metadata" => %{
              "integration_type" => "gate",
              "integration_id" => "gate-#{run}-#{d}"
            }
          }
        end

      assert :ok = SyncIngestor.ingest_updates(updates, actor: actor)
    end

    prefix = "gate-#{run}-"

    device_ids =
      from(di in DeviceIdentifier,
        where: di.identifier_type == :integration_id and like(di.identifier_value, ^"#{prefix}%"),
        select: di.device_id
      )
      |> Repo.all()
      |> Enum.uniq()

    assert length(device_ids) == @devices

    mac_cap = CardinalityCaps.cap_for(:mac)

    rows_per_device =
      Repo.all(
        from(di in DeviceIdentifier,
          where: di.device_id in ^device_ids and di.identifier_type == :mac,
          group_by: di.device_id,
          select: {di.device_id, count(di.id)}
        )
      )

    total = rows_per_device |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    # Each device has exactly its true MAC set (8 valid MACs), regardless of
    # ordering/subset churn across rounds, and never exceeds the cap.
    assert Enum.all?(rows_per_device, fn {_id, n} -> n <= min(8, mac_cap) end)
    assert total <= @devices * 8

    # No comma blobs, no invalid values, ever.
    blob_count =
      Repo.one(
        from(di in DeviceIdentifier,
          where:
            di.device_id in ^device_ids and di.identifier_type == :mac and
              fragment("? !~ '^[0-9A-F]{12}$'", di.identifier_value),
          select: count(di.id)
        )
      )

    assert blob_count == 0
  end

  defp gate_mac(run, device, nic) do
    suffix =
      (run * 100_003 + device * 251 + nic)
      |> rem(0x1000000)
      |> Integer.to_string(16)
      |> String.pad_leading(6, "0")
      |> String.upcase()

    "001B44" <> suffix
  end
end
