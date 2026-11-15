defmodule ServiceRadar.EventWriter.Processors.AvailabilityTransitionsTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.Processors.AvailabilityTransitions
  alias ServiceRadar.Inventory.DevicePubSub

  @record %{
    "device_uid" => "sr:00000000-0000-4000-8000-000000000001",
    "from_state" => "available",
    "from_since" => "2026-01-01T00:00:00Z",
    "to_state" => "unavailable",
    "changed_at" => "2026-01-01T06:00:00Z",
    "authority_class" => "managing_controller",
    "source_kind" => "camera",
    "reporter_agent_id" => "agent-test01",
    "rule" => "highest_class",
    "conflict" => false
  }

  setup do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    if is_nil(Process.whereis(ServiceRadar.PubSub)) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    :ok
  end

  defp message(record), do: %{data: Jason.encode!(record), metadata: %{}}

  # A reader that refreshed before the batch landed reads the stored rows only when told
  # again, so the devices are announced after the store succeeds and never before.
  test "devices are announced once their records are stored, and not when the store fails" do
    Phoenix.PubSub.subscribe(ServiceRadar.PubSub, DevicePubSub.invalidation_topic())
    uid = @record["device_uid"]
    later = %{@record | "changed_at" => "2026-01-01T07:00:00Z", "to_state" => "available"}

    assert {:error, :warehouse_down} =
             AvailabilityTransitions.process_batch([message(@record)],
               starrocks_enabled: true,
               load: fn _dataset, _rows -> {:error, :warehouse_down} end
             )

    refute_received {:devices_invalidated, [^uid]}

    parent = self()

    load = fn _dataset, rows ->
      send(parent, :stored)
      {:ok, %{loaded: length(rows)}}
    end

    assert {:ok, 2} =
             AvailabilityTransitions.process_batch([message(@record), message(later)],
               starrocks_enabled: true,
               load: load
             )

    assert_received :stored
    assert_receive {:devices_invalidated, [^uid]}
  end

  test "with StarRocks enabled a batch loads the warehouse dataset only" do
    parent = self()

    load = fn dataset, rows ->
      send(parent, {:load, dataset, rows})
      {:ok, %{loaded: length(rows)}}
    end

    first_known = %{@record | "from_since" => nil, "from_state" => "unknown"}

    assert {:ok, 2} =
             AvailabilityTransitions.process_batch([message(@record), message(first_known)],
               starrocks_enabled: true,
               load: load
             )

    assert_received {:load, :device_availability_transitions, [row, first]}
    assert row.device_uid == @record["device_uid"]
    assert row.changed_at == ~U[2026-01-01 06:00:00Z]
    assert row.from_since == ~U[2026-01-01 00:00:00Z]

    assert {row.from_state, row.to_state, row.source_kind} ==
             {"available", "unavailable", "camera"}

    assert is_nil(first.from_since)
  end

  # A record that cannot be decoded fails the same way on every redelivery, so it is
  # dropped rather than retried; a failed load is retried.
  test "undecodable records are dropped, and a failed warehouse load fails the batch" do
    invalid = [
      %{data: "not json", metadata: %{}},
      message(%{@record | "to_state" => "sideways"}),
      message(%{@record | "changed_at" => "yesterday"}),
      message(Map.delete(@record, "device_uid"))
    ]

    assert {:ok, 0} =
             AvailabilityTransitions.process_batch(invalid,
               starrocks_enabled: true,
               load: fn _dataset, _rows -> flunk("nothing decodable to load") end
             )

    assert {:error, :warehouse_down} =
             AvailabilityTransitions.process_batch([message(@record)],
               starrocks_enabled: true,
               load: fn _dataset, _rows -> {:error, :warehouse_down} end
             )
  end
end
