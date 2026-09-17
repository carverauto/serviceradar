defmodule ServiceRadar.Analytics.StarRocks.AttributionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.Attribution
  alias ServiceRadar.Analytics.StarRocks.Rows

  @moduletag :db_free

  test "attribution updates omit traffic totals and are monotonic" do
    event =
      Attribution.update_event(%{id: "flow-alpha-0001", bytes_in: 1200, pid: 42, comm: "sshd"}, 3)

    assert event["id"] == "flow-alpha-0001"
    assert event["attribution_version"] == 3
    assert event["pid"] == 42
    refute Map.has_key?(event, "bytes_in")
    refute Map.has_key?(event, "bytes_out")
    assert Attribution.apply_monotonic(3, 2) == :ignore
    assert Attribution.apply_monotonic(3, 3) == :ignore
    assert Attribution.apply_monotonic(3, 4) == :apply
  end

  test "flow_attribution encoder emits only attribution columns and drops traffic" do
    [row] =
      Rows.encode(:flow_attribution, [
        %{
          "id" => "flow-alpha-0001",
          "attribution_version" => 3,
          "pid" => 9,
          "comm" => "sshd",
          "bytes_in" => 1200,
          "bytes_out" => 80,
          "time" => "1999-06-15 12:00:00",
          "device_uid" => "sr:host-alpha"
        }
      ])

    assert Map.keys(row) -- Attribution.load_columns() == []
    assert row["id"] == "flow-alpha-0001"
    assert row["attribution_version"] == 3
    assert row["pid"] == 9
    refute Map.has_key?(row, "bytes_in")
    refute Map.has_key?(row, "bytes_out")
    refute Map.has_key?(row, "time")
    refute Map.has_key?(row, "device_uid")
  end

  test "default publisher uses NATS.Connection rather than a no-op" do
    assert {:error, :not_connected} =
             Attribution.publish_updates([
               %{id: "flow-alpha-0001", pid: 9, attribution_version: 1}
             ])
  end

  test "publish_updates emit JetStream payloads without clobbering traffic totals" do
    parent = self()
    row = %{id: "flow-alpha-0001", pid: 9, comm: "nginx", bytes_in: 1200, attribution_version: 41}

    assert :ok =
             Attribution.publish_updates([row],
               publish: fn message ->
                 send(parent, {:published, message})
                 :ok
               end
             )

    assert_received {:published, %{subject: "events.flow.attribution", payload: payload}}
    assert payload["id"] == "flow-alpha-0001"
    assert payload["attribution_version"] == 41
    refute Map.has_key?(payload, "bytes_in")
  end

  test "unresolved events cannot become flow updates" do
    assert {:error, :unresolved_flow_attribution} =
             Attribution.publish_updates([%{observed_at: ~U[1999-06-15 12:00:00Z], pid: 9}],
               publish: fn _ -> flunk("unresolved event published") end
             )
  end

  test "publish failure is returned to the caller" do
    assert {:error, :timeout} =
             Attribution.publish_updates(
               [%{id: "flow-alpha-0001", pid: 9, attribution_version: 42}],
               publish: fn _ -> {:error, :timeout} end
             )
  end

  test "load labels distinguish versions and remain stable on retry" do
    alias ServiceRadar.Analytics.StarRocks.StreamLoad
    first = %{"id" => "flow-alpha-0001", "attribution_version" => 41}
    second = %{first | "attribution_version" => 42}

    assert StreamLoad.load_label("ocsf_network_activity", [first]) ==
             StreamLoad.load_label("ocsf_network_activity", [first])

    refute StreamLoad.load_label("ocsf_network_activity", [first]) ==
             StreamLoad.load_label("ocsf_network_activity", [second])
  end

  test "workload maps survive publication and attribution row encoding" do
    identity = %{
      "namespace" => "example",
      "pod_name" => "worker-example",
      "labels" => %{"app" => "example"}
    }

    event =
      Attribution.update_event(
        %{id: "flow-alpha-0001", pid: 42, workload_identity: identity},
        7
      )

    decoded = event |> Jason.encode!() |> Jason.decode!()
    [row] = Rows.encode(:flow_attribution, [decoded])
    assert Jason.decode!(row["workload_identity"]) == identity
    assert row["pid"] == 42

    for value <- [nil, Jason.encode!(identity)] do
      [row] = Rows.encode(:flow_attribution, [%{decoded | "workload_identity" => value}])
      assert row["workload_identity"] == value
    end
  end
end
