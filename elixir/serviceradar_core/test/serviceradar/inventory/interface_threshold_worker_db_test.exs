defmodule ServiceRadar.Inventory.InterfaceThresholdWorkerDBTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Inventory.InterfaceThresholdWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  @if_index 7
  @metric "ifInOctets"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    device_id = "test-threshold-device-#{System.unique_integer([:positive])}"
    {:ok, device_id: device_id}
  end

  test "a violated threshold emits an event on the first evaluation", %{device_id: device_id} do
    insert_setting!(device_id, %{"comparison" => "gt", "value" => 500})
    insert_metric!(device_id, 900.0)

    assert :ok = InterfaceThresholdWorker.perform(%Oban.Job{args: %{}})

    assert event_count(device_id) == 1
  end

  test "a repeat inside the cooldown is suppressed and fires again once it elapses", %{
    device_id: device_id
  } do
    insert_setting!(device_id, %{"comparison" => "gt", "value" => 500})
    insert_metric!(device_id, 900.0)
    t0 = DateTime.utc_now()

    assert :ok = InterfaceThresholdWorker.run(now: t0)
    assert event_count(device_id) == 1

    assert :ok = InterfaceThresholdWorker.run(now: DateTime.shift(t0, minute: 1))
    assert :ok = InterfaceThresholdWorker.run(now: DateTime.shift(t0, second: 299))
    assert event_count(device_id) == 1

    assert :ok = InterfaceThresholdWorker.run(now: DateTime.shift(t0, second: 301))
    assert event_count(device_id) == 2
  end

  test "a threshold with a duration fires only after the violation has lasted that long", %{
    device_id: device_id
  } do
    insert_setting!(device_id, %{"comparison" => "gt", "value" => 500, "duration_seconds" => 120})
    insert_metric!(device_id, 900.0)
    t0 = DateTime.utc_now()

    assert :ok = InterfaceThresholdWorker.run(now: t0)
    assert :ok = InterfaceThresholdWorker.run(now: DateTime.shift(t0, minute: 1))
    assert event_count(device_id) == 0

    assert :ok = InterfaceThresholdWorker.run(now: DateTime.shift(t0, second: 121))
    assert event_count(device_id) == 1
  end

  test "a violation that clears before its duration restarts the duration", %{
    device_id: device_id
  } do
    insert_setting!(device_id, %{"comparison" => "gt", "value" => 500, "duration_seconds" => 120})
    insert_metric!(device_id, 900.0, -2)
    t0 = DateTime.utc_now()

    assert :ok = InterfaceThresholdWorker.run(now: t0)

    insert_metric!(device_id, 100.0, -1)
    assert :ok = InterfaceThresholdWorker.run(now: DateTime.shift(t0, minute: 1))

    insert_metric!(device_id, 900.0, 0)
    assert :ok = InterfaceThresholdWorker.run(now: DateTime.shift(t0, second: 121))
    assert event_count(device_id) == 0

    assert :ok = InterfaceThresholdWorker.run(now: DateTime.shift(t0, second: 241))
    assert event_count(device_id) == 1
  end

  test "run/1 returns {:error, _} when the state persist fails", %{device_id: device_id} do
    insert_setting!(device_id, %{"comparison" => "gt", "value" => 500})
    insert_metric!(device_id, 900.0)

    Repo.query!(
      "ALTER TABLE platform.interface_threshold_states ADD CONSTRAINT force_fail_test CHECK (false)"
    )

    assert {:error, _} = InterfaceThresholdWorker.run(now: DateTime.utc_now())
  end

  test "a warehouse sample emits a threshold event when CNPG has none", %{device_id: device_id} do
    insert_setting!(device_id, %{"comparison" => "gt", "value" => 500})
    enable_metrics_warehouse!()

    query = fn _sql ->
      {:ok, %{rows: [[device_id, @if_index, @metric, 900.0]]}}
    end

    assert :ok = InterfaceThresholdWorker.run(now: DateTime.utc_now(), metric_query: query)
    assert event_count(device_id) == 1
  end

  test "a CNPG sample does not emit when the warehouse is the metrics store", %{
    device_id: device_id
  } do
    insert_setting!(device_id, %{"comparison" => "gt", "value" => 500})
    insert_metric!(device_id, 900.0)
    enable_metrics_warehouse!()

    query = fn _sql -> {:ok, %{rows: []}} end

    assert :ok = InterfaceThresholdWorker.run(now: DateTime.utc_now(), metric_query: query)
    assert event_count(device_id) == 0
  end

  test "evaluation state is kept only while a metric is violating or cooling down", %{
    device_id: device_id
  } do
    setting_id = insert_setting!(device_id, %{"comparison" => "gt", "value" => 500})
    insert_metric!(device_id, 900.0, -1)
    t0 = DateTime.utc_now()

    assert :ok = InterfaceThresholdWorker.run(now: t0)
    assert state_count(setting_id) == 1

    insert_metric!(device_id, 100.0, 0)
    assert :ok = InterfaceThresholdWorker.run(now: DateTime.shift(t0, second: 400))
    assert state_count(setting_id) == 0
    assert event_count(device_id) == 1
  end

  defp enable_metrics_warehouse! do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev |> Keyword.put(:enabled, true) |> Keyword.put(:cutover_datasets, [])
    )

    on_exit(fn ->
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end)
  end

  defp insert_setting!(device_id, threshold) do
    config = Map.put(threshold, "enabled", true)

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO platform.interface_settings
          (device_id, interface_uid, metrics_selected, metric_thresholds)
        VALUES ($1, $2, $3, $4)
        RETURNING id
        """,
        [device_id, "#{device_id}:#{@if_index}", [@metric], %{@metric => config}]
      )

    Ecto.UUID.load!(id)
  end

  # `offset_seconds` orders samples relative to one another; every sample stays
  # inside the worker's five-minute lookback.
  defp insert_metric!(device_id, value, offset_seconds \\ 0) do
    Repo.query!(
      """
      INSERT INTO platform.timeseries_metrics
        ("timestamp", gateway_id, metric_name, metric_type, device_id, value, if_index, series_key)
      VALUES (now() + make_interval(secs => $1), 'test-gateway', $2, 'counter', $3, $4, $5, $6)
      """,
      [offset_seconds, @metric, device_id, value, @if_index, "#{device_id}:#{@metric}"]
    )
  end

  defp event_count(device_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.ocsf_events WHERE device->>'uid' = $1",
        [device_id]
      )

    count
  end

  defp state_count(setting_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.interface_threshold_states WHERE interface_settings_id = $1",
        [Ecto.UUID.dump!(setting_id)]
      )

    count
  end
end
