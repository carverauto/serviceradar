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
    insert_rate!(device_id, 900.0)

    assert :ok = InterfaceThresholdWorker.perform(%Oban.Job{args: %{}})

    assert event_count(device_id) == 1
  end

  test "a repeat inside the cooldown is suppressed and fires again once it elapses", %{
    device_id: device_id
  } do
    insert_setting!(device_id, %{"comparison" => "gt", "value" => 500})
    insert_rate!(device_id, 900.0)
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
    insert_rate!(device_id, 900.0)
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
    insert_sample!(device_id, 0.0, -3)
    insert_sample!(device_id, 900.0, -2)
    t0 = DateTime.utc_now()

    assert :ok = InterfaceThresholdWorker.run(now: t0)

    insert_sample!(device_id, 1_000.0, -1)
    assert :ok = InterfaceThresholdWorker.run(now: DateTime.shift(t0, minute: 1))

    insert_sample!(device_id, 1_900.0, 0)
    assert :ok = InterfaceThresholdWorker.run(now: DateTime.shift(t0, second: 121))
    assert event_count(device_id) == 0

    assert :ok = InterfaceThresholdWorker.run(now: DateTime.shift(t0, second: 241))
    assert event_count(device_id) == 1
  end

  test "run/1 returns {:error, _} when the state persist fails", %{device_id: device_id} do
    insert_setting!(device_id, %{"comparison" => "gt", "value" => 500})
    insert_rate!(device_id, 900.0)

    Repo.query!(
      "ALTER TABLE platform.interface_threshold_states ADD CONSTRAINT force_fail_test CHECK (false)"
    )

    assert {:error, _} = InterfaceThresholdWorker.run(now: DateTime.utc_now())
  end

  test "a warehouse sample emits a threshold event when CNPG has none", %{device_id: device_id} do
    insert_setting!(device_id, %{"comparison" => "gt", "value" => 500})
    enable_metrics_warehouse!()

    query = fn sql ->
      assert rate_sql?(sql)
      {:ok, %{rows: [[device_id, @if_index, @metric, 900.0]]}}
    end

    assert :ok = InterfaceThresholdWorker.run(now: DateTime.utc_now(), metric_query: query)
    assert event_count(device_id) == 1
  end

  test "a CNPG sample does not emit when the warehouse is the metrics store", %{
    device_id: device_id
  } do
    insert_setting!(device_id, %{"comparison" => "gt", "value" => 500})
    insert_rate!(device_id, 900.0)
    enable_metrics_warehouse!()

    query = fn _sql -> {:ok, %{rows: []}} end

    assert :ok = InterfaceThresholdWorker.run(now: DateTime.utc_now(), metric_query: query)
    assert event_count(device_id) == 0
  end

  test "evaluation state is kept only while a metric is violating or cooling down", %{
    device_id: device_id
  } do
    setting_id = insert_setting!(device_id, %{"comparison" => "gt", "value" => 500})
    insert_sample!(device_id, 0.0, -2)
    insert_sample!(device_id, 900.0, -1)
    t0 = DateTime.utc_now()

    assert :ok = InterfaceThresholdWorker.run(now: t0)
    assert state_count(setting_id) == 1

    insert_sample!(device_id, 1_000.0, 0)
    assert :ok = InterfaceThresholdWorker.run(now: DateTime.shift(t0, second: 400))
    assert state_count(setting_id) == 0
    assert event_count(device_id) == 1
  end

  test "a 32-bit counter wrap fires from the wrapped rate", %{device_id: device_id} do
    insert_setting!(device_id, %{"comparison" => "gt", "value" => 100})
    insert_sample!(device_id, 4_294_967_200.0, -1, 32)
    insert_sample!(device_id, 50.0, 0, 32)

    assert :ok = InterfaceThresholdWorker.perform(%Oban.Job{args: %{}})

    assert event_count(device_id) == 1
  end

  test "a 64-bit counter reset skips the sample and keeps an open violation", %{
    device_id: device_id
  } do
    setting_id =
      insert_setting!(device_id, %{
        "comparison" => "gt",
        "value" => 500,
        "duration_seconds" => 120
      })

    insert_rate!(device_id, 900.0)
    t0 = DateTime.utc_now()

    assert :ok = InterfaceThresholdWorker.run(now: t0)
    assert event_count(device_id) == 0
    assert state_count(setting_id) == 1

    insert_sample!(device_id, 10.0, 1, 64)

    assert :ok = InterfaceThresholdWorker.run(now: DateTime.shift(t0, second: 30))
    assert event_count(device_id) == 0
    assert state_count(setting_id) == 1
  end

  test "a percentage threshold ignores a high counter whose rate is under the link share", %{
    device_id: device_id
  } do
    insert_setting!(device_id, %{
      "comparison" => "gt",
      "value" => 50,
      "threshold_type" => "percentage"
    })

    insert_speed!(device_id, 8_000)
    insert_sample!(device_id, 10_000.0, -1)
    insert_sample!(device_id, 10_200.0, 0)

    assert :ok = InterfaceThresholdWorker.perform(%Oban.Job{args: %{}})

    assert event_count(device_id) == 0
  end

  test "a percentage threshold fires when the rate exceeds the link share", %{
    device_id: device_id
  } do
    insert_setting!(device_id, %{
      "comparison" => "gt",
      "value" => 50,
      "threshold_type" => "percentage"
    })

    insert_speed!(device_id, 8_000)
    insert_sample!(device_id, 10_000.0, -1)
    insert_sample!(device_id, 10_900.0, 0)

    assert :ok = InterfaceThresholdWorker.perform(%Oban.Job{args: %{}})

    assert event_count(device_id) == 1
  end

  test "a warehouse wrapped rate emits a threshold event", %{device_id: device_id} do
    insert_setting!(device_id, %{"comparison" => "gt", "value" => 100})
    enable_metrics_warehouse!()

    query = fn sql ->
      assert rate_sql?(sql)
      {:ok, %{rows: [[device_id, @if_index, @metric, 146.0]]}}
    end

    assert :ok = InterfaceThresholdWorker.run(now: DateTime.utc_now(), metric_query: query)
    assert event_count(device_id) == 1
  end

  test "a warehouse reset leaves an open violation in place", %{device_id: device_id} do
    setting_id =
      insert_setting!(device_id, %{
        "comparison" => "gt",
        "value" => 500,
        "duration_seconds" => 120
      })

    enable_metrics_warehouse!()
    query = sequenced_query(device_id, [900.0, :empty])
    t0 = DateTime.utc_now()

    assert :ok = InterfaceThresholdWorker.run(now: t0, metric_query: query)
    assert event_count(device_id) == 0
    assert state_count(setting_id) == 1

    assert :ok =
             InterfaceThresholdWorker.run(
               now: DateTime.shift(t0, second: 30),
               metric_query: query
             )

    assert event_count(device_id) == 0
    assert state_count(setting_id) == 1
  end

  test "a warehouse rate under the threshold clears a fired alert", %{device_id: device_id} do
    setting_id = insert_setting!(device_id, %{"comparison" => "gt", "value" => 500})
    enable_metrics_warehouse!()
    query = sequenced_query(device_id, [900.0, 100.0])
    t0 = DateTime.utc_now()

    assert :ok = InterfaceThresholdWorker.run(now: t0, metric_query: query)
    assert event_count(device_id) == 1
    assert state_count(setting_id) == 1

    assert :ok =
             InterfaceThresholdWorker.run(
               now: DateTime.shift(t0, second: 400),
               metric_query: query
             )

    assert event_count(device_id) == 1
    assert state_count(setting_id) == 0
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

  # One second between a zero baseline and `rate` makes the per-second rate
  # equal to `rate`. `offset_seconds` only orders samples; each one stays inside
  # the worker's five-minute lookback.
  defp insert_rate!(device_id, rate) do
    insert_sample!(device_id, 0.0, -1)
    insert_sample!(device_id, rate, 0)
  end

  defp insert_sample!(device_id, value, offset_seconds, width \\ nil) do
    Repo.query!(
      """
      INSERT INTO platform.timeseries_metrics
        ("timestamp", gateway_id, metric_name, metric_type, device_id, value,
         if_index, series_key, counter_width)
      VALUES (now() + make_interval(secs => $1), 'test-gateway', $2, 'counter', $3, $4, $5, $6, $7)
      """,
      [offset_seconds, @metric, device_id, value, @if_index, "#{device_id}:#{@metric}", width]
    )
  end

  defp insert_speed!(device_id, speed_bps) do
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
    octet = :erlang.phash2(device_id, 254) + 1

    Repo.query!(
      """
      INSERT INTO platform.ocsf_devices
        (uid, ip, type_id, first_seen_time, last_seen_time)
      VALUES ($1, $2, 0, $3, $3)
      ON CONFLICT (uid) DO NOTHING
      """,
      [device_id, "203.0.113.#{octet}", now]
    )

    Repo.query!(
      """
      INSERT INTO platform.discovered_interfaces
        ("timestamp", device_id, if_index, interface_uid, speed_bps)
      VALUES (now(), $1, $2, $3, $4)
      """,
      [device_id, @if_index, "#{device_id}:#{@if_index}", speed_bps]
    )
  end

  defp sequenced_query(device_id, rates) do
    {:ok, calls} = Agent.start_link(fn -> rates end)

    fn sql ->
      assert rate_sql?(sql)
      {:ok, %{rows: rate_rows(device_id, Agent.get_and_update(calls, &pop_rate/1))}}
    end
  end

  defp pop_rate([rate | rest]), do: {rate, rest}
  defp pop_rate([]), do: {:empty, []}

  defp rate_rows(_device_id, :empty), do: []
  defp rate_rows(device_id, rate), do: [[device_id, @if_index, @metric, rate]]

  defp rate_sql?(sql) do
    compact = String.replace(sql, ~r/\s+/, " ")

    String.contains?(compact, "previous_value") and
      String.contains?(compact, "4294967296") and
      String.contains?(compact, "18446744073709551616")
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
