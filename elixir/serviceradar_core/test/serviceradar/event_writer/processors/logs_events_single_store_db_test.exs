defmodule ServiceRadar.EventWriter.Processors.LogsEventsSingleStoreDBTest do
  @moduledoc """
  Logs and events are written to exactly one store: the one they are read from.

  Cut over on an enabled warehouse, a batch is Stream Loaded there, carrying
  every field CNPG would have stored, and nothing is written to CNPG. Not cut over, it is written to CNPG and nothing is loaded
  into the warehouse, whether the warehouse is enabled or not: there is no
  shadow copy.
  """
  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.EventWriter.Processors.Events
  alias ServiceRadar.EventWriter.Processors.Logs
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.ScriptedStatefulAlertEngine
  alias ServiceRadar.TestSupport.StreamLoadFE

  @moduletag :integration

  # The CNPG ocsf_events fields the warehouse row did not carry before
  # priv/starrocks/0036. Documents load as JSON text.
  @event_fields %{
    "actor" => %{"user" => %{"name" => "operator-example"}},
    "src_endpoint" => %{"ip" => "192.0.2.10", "port" => 51_000},
    "dst_endpoint" => %{"ip" => "198.51.100.20", "port" => 443},
    "status_code" => "E-EXAMPLE-01",
    "status_detail" => "synthetic status detail",
    "log_version" => "1.7.0",
    "raw_data" => "synthetic raw payload"
  }

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    previous = Application.get_env(:serviceradar_core, StarRocks)
    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, previous || []) end)

    reset_engine()
    on_exit(&reset_engine/0)
    # These tests are about where rows are stored, so evaluation succeeds
    # without loading or firing real rules.
    ScriptedStatefulAlertEngine.use_in_test()

    {:ok, fe_http: StreamLoadFE.start!()}
  end

  for dataset <- [:logs, :events] do
    @dataset dataset

    test "#{dataset} cut over on an enabled warehouse are loaded there and not written to CNPG",
         %{fe_http: fe_http} do
      put_starrocks(enabled: true, cutover_datasets: [@dataset], fe_http: fe_http)
      marker = marker()

      assert {:ok, 1} = process(@dataset, marker)

      assert_receive {:wire_request, [row]}, 5_000
      assert loaded_marker(@dataset, row) == marker
      assert_carries_cnpg_fields(@dataset, row)
      assert cnpg_count(@dataset, marker) == 0
    end

    test "#{dataset} not cut over are written to CNPG only, with the warehouse on or off",
         %{fe_http: fe_http} do
      for enabled <- [true, false] do
        put_starrocks(enabled: enabled, cutover_datasets: [], fe_http: fe_http)
        marker = marker()

        assert {:ok, 1} = process(@dataset, marker)

        assert cnpg_count(@dataset, marker) == 1
        # The load is synchronous, so a shadow copy would already be here.
        refute_received {:wire_request, _rows}
      end
    end
  end

  defp put_starrocks(overrides) do
    previous = Application.get_env(:serviceradar_core, StarRocks) || []
    Application.put_env(:serviceradar_core, StarRocks, Keyword.merge(previous, overrides))
  end

  defp marker, do: "single-store-#{System.unique_integer([:positive])}"

  defp process(:logs, marker) do
    payload = %{
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
      "severity_text" => "INFO",
      "service_name" => "synthetic-service",
      "body" => marker
    }

    Logs.process_batch([%{data: Jason.encode!(payload), metadata: %{subject: "logs.app"}}])
  end

  defp process(:events, marker) do
    payload = %{
      "id" => Ecto.UUID.generate(),
      "time" => DateTime.to_iso8601(DateTime.utc_now()),
      "class_uid" => 1008,
      "category_uid" => 1,
      "type_uid" => 100_801,
      "activity_id" => 1,
      "severity_id" => 1,
      "message" => marker
    }

    Events.process_batch([
      %{
        data: Jason.encode!(Map.merge(payload, @event_fields)),
        metadata: %{subject: "events.ocsf.processed"}
      }
    ])
  end

  defp assert_carries_cnpg_fields(:logs, _row), do: :ok

  defp assert_carries_cnpg_fields(:events, row) do
    for {field, expected} <- @event_fields do
      loaded = if is_map(expected), do: Jason.decode!(row[field] || "null"), else: row[field]
      assert loaded == expected, "#{field} was not carried: #{inspect(row[field])}"
    end

    assert is_binary(row["created_at"])
  end

  defp loaded_marker(:logs, row), do: row["body"]
  defp loaded_marker(:events, row), do: row["message"]

  defp cnpg_count(:logs, marker),
    do: count("SELECT count(*) FROM platform.logs WHERE body = $1", marker)

  defp cnpg_count(:events, marker),
    do: count("SELECT count(*) FROM platform.ocsf_events WHERE message = $1", marker)

  defp count(sql, marker) do
    %{rows: [[count]]} = SQL.query!(Repo, sql, [marker])
    count
  end

  defp reset_engine do
    case ProcessRegistry.lookup(:stateful_alert_engine) do
      [{pid, _}] ->
        _ = ProcessRegistry.terminate_child(pid)
        Process.sleep(25)
        :ok

      _ ->
        :ok
    end
  end
end
