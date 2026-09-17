defmodule ServiceRadar.EventWriter.Processors.FlowAttributionUpdatesTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.Attribution
  alias ServiceRadar.EventWriter.Processors.FlowAttributionUpdates

  @moduletag :db_free

  test "parses versioned attribution payloads and drops stale versions" do
    body = Jason.encode!(%{"id" => "flow-alpha-0001", "attribution_version" => 2, "pid" => 9})

    assert %{"id" => "flow-alpha-0001", "attribution_version" => 2} =
             FlowAttributionUpdates.parse_message(%{data: body})

    stale = Jason.encode!(%{"id" => "flow-alpha-0001", "attribution_version" => 0})
    assert FlowAttributionUpdates.parse_message(%{data: stale}) == nil
  end

  test "process_batch propagates warehouse lookup failures" do
    body = Jason.encode!(%{"id" => "flow-alpha-0001", "attribution_version" => 1})

    assert {:error, :timeout} =
             FlowAttributionUpdates.process_batch([%{data: body}],
               version_lookup: fn _ -> {:error, :timeout} end
             )
  end

  test "process_batch shadows attribution columns only and ignores stored-or-equal versions" do
    persist = fn table, rows, opts ->
      send(self(), {:persist, table, rows, opts})
      {:ok, %{loaded: length(rows)}}
    end

    newer =
      Jason.encode!(%{
        "id" => "flow-alpha-0001",
        "attribution_version" => 4,
        "pid" => 9,
        "comm" => "sshd",
        "bytes_in" => 1200,
        "time" => "1999-06-15 12:00:00"
      })

    stale =
      Jason.encode!(%{
        "id" => "flow-alpha-0001",
        "attribution_version" => 2,
        "pid" => 8,
        "bytes_in" => 99
      })

    assert {:ok, 2} =
             FlowAttributionUpdates.process_batch(
               [%{data: stale}, %{data: newer}],
               enabled: true,
               persist: persist,
               version_lookup: fn ids ->
                 assert "flow-alpha-0001" in ids
                 %{"flow-alpha-0001" => 3}
               end
             )

    assert_received {:persist, "ocsf_network_activity", [row], opts}
    assert opts[:partial_update] == true
    assert opts[:merge_condition] == "attribution_version"
    assert opts[:columns] == Attribution.load_columns()
    assert row["id"] == "flow-alpha-0001"
    assert row["attribution_version"] == 4
    assert row["pid"] == 9
    refute Map.has_key?(row, "bytes_in")
    refute Map.has_key?(row, "time")
    assert Map.get(row, "bytes_in", :absent)
    refute_received {:persist, _, _, _}
  end

  test "process_batch does not persist incoming_version <= stored version" do
    persist = fn table, rows, opts ->
      send(self(), {:persist, table, rows, opts})
      {:ok, %{loaded: length(rows)}}
    end

    body =
      Jason.encode!(%{
        "id" => "flow-alpha-0001",
        "attribution_version" => 3,
        "pid" => 9,
        "bytes_in" => 1200
      })

    assert {:ok, 1} =
             FlowAttributionUpdates.process_batch([%{data: body}],
               enabled: true,
               persist: persist,
               version_lookup: fn _ids -> %{"flow-alpha-0001" => 3} end
             )

    refute_received {:persist, _, _, _}
  end

  test "failed and filtered loads are not acknowledged" do
    body = Jason.encode!(%{"id" => "flow-alpha-0001", "attribution_version" => 4, "pid" => 9})

    for result <- [{:error, :timeout}, {:quarantine, :filtered_rows}] do
      assert {:error, {:missing_destinations, %{missing: [:starrocks]}}} =
               FlowAttributionUpdates.process_batch([%{data: body}],
                 version_lookup: fn _ -> %{} end,
                 persist: fn _, _, _ -> result end
               )
    end
  end
end
