defmodule ServiceRadar.Observability.PluginResultIngestorSlotIdentityTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  alias ServiceRadar.Observability.PluginResultSlot

  test "raw and marker slots preserve distinct service identities" do
    {payload, first_status, observed_at} = plugin_result_fixture()

    second_status = %{
      first_status
      | agent_id: "#{first_status.agent_id}-other",
        partition: "other-partition",
        service_type: "plugin-variant"
    }

    expected_error =
      {:error, {:plugin_result_handlers_failed, [{FailingHandler, ":forced_failure"}]}}

    assert ^expected_error = PluginResultIngestor.ingest(payload, first_status)
    assert ^expected_error = PluginResultIngestor.ingest(payload, second_status)

    assert [
             [first_reported_at, true, _, _] = first_reported_row,
             [first_failure_at, false, _, first_failure_details] = first_failure_row
           ] = history_rows(first_status)

    assert first_reported_at ==
             assert_reported_event_block(first_reported_row, observed_at)

    assert %{"generation" => 1, "status" => "failed"} =
             assert_handler_marker_in_block(
               first_failure_row,
               first_reported_at,
               observed_at
             )

    second_rows = history_rows(second_status)
    assert length(second_rows) == 2

    [second_reported_at, true, "edge plugin completed", second_reported_details] =
      Enum.find(second_rows, fn [_timestamp, _available, _message, details] ->
        get_in(Jason.decode!(details), ["_serviceradar_plugin_result", "kind"]) == "reported"
      end)

    second_failure_row =
      Enum.find(second_rows, fn [_timestamp, _available, _message, details] ->
        get_in(Jason.decode!(details), ["downstream_ingest", "status"]) == "failed"
      end)

    [second_failure_at, false, _message, second_failure_details] = second_failure_row

    assert second_reported_at ==
             assert_reported_event_block(
               [second_reported_at, true, "edge plugin completed", second_reported_details],
               observed_at
             )

    assert %{"generation" => 1, "status" => "failed"} =
             assert_handler_marker_in_block(
               second_failure_row,
               second_reported_at,
               observed_at
             )

    refute first_reported_at == second_reported_at

    assert %{
             "_serviceradar_plugin_result" => %{
               "kind" => "reported",
               "observation_timestamp" => observation_timestamp
             }
           } = Jason.decode!(second_reported_details)

    assert observation_timestamp == DateTime.to_iso8601(observed_at)

    assert %{"downstream_ingest" => %{"generation" => 1}} =
             Jason.decode!(first_failure_details)

    assert %{"downstream_ingest" => %{"generation" => 1}} =
             Jason.decode!(second_failure_details)

    assert [[false, _, ^first_failure_at]] = current_state_rows(first_status)
    assert [[false, _, ^second_failure_at]] = current_state_rows(second_status)
  end

  test "state proof preserves the authenticated gateway instead of the agent registry gateway" do
    {payload, status, observed_at} = plugin_result_fixture()
    registry_gateway = "#{status.gateway_id}-registry"
    create_agent(status.agent_id, registry_gateway)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    ReplayHandler.put_outcomes([{:error, :first_failure}, :ok])

    assert {:error, {:plugin_result_handlers_failed, [{ReplayHandler, ":first_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert :ok = PluginResultIngestor.ingest(payload, status)

    assert [
             [reported_at, true, _, _] = reported_row,
             [_failed_at, false, _, _] = failure_row,
             [proven_at, true, _, _] = success_row
           ] = history_rows(status)

    assert reported_at == assert_reported_event_block(reported_row, observed_at)
    assert_handler_marker_in_block(failure_row, reported_at, observed_at)
    assert_handler_marker_in_block(success_row, reported_at, observed_at)

    assert [[true, "edge plugin completed", ^proven_at]] = current_state_rows(status)
    assert [] = current_state_rows(%{status | gateway_id: registry_gateway})
  end

  test "shifted event block replay carries forward same-provenance state proof" do
    {payload, status, observed_at} = plugin_result_fixture()

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    ReplayHandler.put_outcomes([{:error, :early_failure}, :ok])

    collision_status = %{
      status
      | agent_id: "#{status.agent_id}-collision",
        partition: "collision-partition",
        service_type: "plugin-collision"
    }

    preferred_base =
      status
      |> Map.put(:timestamp, observed_at)
      |> Map.put(:details, nil)
      |> PluginResultSlot.block_base(0)

    insert_history_status(
      collision_status,
      %{"status" => "CRITICAL"},
      preferred_base,
      "occupied"
    )

    assert {:error, {:plugin_result_handlers_failed, [{ReplayHandler, ":early_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    shifted_base = reported_event_block_base(status, observed_at)
    refute shifted_base == preferred_base

    assert :ok = PluginResultIngestor.ingest(payload, status)

    assert [
             [^shifted_base, true, _, _],
             [_reallocated_failure_at, false, _, failure_details] = failure_row,
             [reallocated_success_at, true, _, success_details] = success_row
           ] = history_rows(status)

    assert %{"generation" => 1, "status" => "failed"} =
             assert_handler_marker_in_block(failure_row, shifted_base, observed_at)

    assert %{"generation" => 1, "status" => "succeeded"} =
             assert_handler_marker_in_block(success_row, shifted_base, observed_at)

    assert %{"downstream_ingest" => %{"generation" => 1, "status" => "failed"}} =
             Jason.decode!(failure_details)

    assert %{"downstream_ingest" => %{"generation" => 1, "status" => "succeeded"}} =
             Jason.decode!(success_details)

    assert [[true, "edge plugin completed", ^reallocated_success_at]] =
             current_state_rows(status)
  end

  test "marker allocation stays inside its block beside an adjacent observation" do
    {payload, status, observed_at} = plugin_result_fixture()
    next_observed_at = DateTime.add(observed_at, 1, :microsecond)

    insert_history_status(
      status,
      %{
        "status" => "OK",
        "reported_result" => %{},
        "downstream_ingest" => %{"status" => "failed"}
      },
      next_observed_at,
      "next observation"
    )

    assert {:error, {:plugin_result_handlers_failed, [{FailingHandler, ":forced_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert [reported_row] = reported_history_rows(status)
    reported_at = assert_reported_event_block(reported_row, observed_at)

    failure_row =
      Enum.find(downstream_history_rows(status), fn [_timestamp, _available, _message, details] ->
        get_in(Jason.decode!(details), ["downstream_ingest", "generation"]) == 1
      end)

    assert [_failure_at, false, _failure_message, _failure_details] = failure_row

    assert %{"generation" => 1, "status" => "failed"} =
             assert_handler_marker_in_block(failure_row, reported_at, observed_at)

    assert Enum.any?(history_rows(status), fn
             [^next_observed_at, true, "next observation", _] -> true
             _row -> false
           end)

    assert [[false, _, _failure_at]] = current_state_rows(status)
  end

  test "shifted reported payload cannot spoof downstream marker provenance" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {payload, status, observed_at} = plugin_result_fixture()

    payload =
      Map.put(payload, "downstream_ingest", %{
        "status" => "failed",
        "generation" => 1,
        "handler_set" => %{"id" => "forged-handler-set", "version" => 1},
        "observation_timestamp" => DateTime.to_iso8601(observed_at)
      })

    collision_status = %{
      status
      | agent_id: "#{status.agent_id}-collision",
        partition: "collision-partition",
        service_type: "plugin-collision"
    }

    preferred_base =
      status
      |> Map.put(:timestamp, observed_at)
      |> Map.put(:details, nil)
      |> PluginResultSlot.block_base(0)

    insert_history_status(collision_status, %{"status" => "OK"}, preferred_base, "occupied")

    assert :ok = PluginResultIngestor.ingest(payload, status)

    assert [[shifted_reported_at, true, "edge plugin completed", reported_details]] =
             history_rows(status)

    assert shifted_reported_at ==
             assert_reported_event_block(
               [shifted_reported_at, true, "edge plugin completed", reported_details],
               observed_at
             )

    refute shifted_reported_at == preferred_base

    assert %{
             "_serviceradar_plugin_result" => %{"kind" => "reported"},
             "downstream_ingest" => %{"status" => "failed"}
           } = Jason.decode!(reported_details)

    assert %{
             "downstream_ingest" => %{
               "status" => "succeeded",
               "generation" => 1,
               "recovered_from_failure" => false
             }
           } = status |> current_state_details() |> Jason.decode!()

    succeeded_at = marker_timestamp(shifted_reported_at, 1, "succeeded")
    assert [[true, "edge plugin completed", ^succeeded_at]] = current_state_rows(status)
  end

  # The ingestor reads ServiceStatus several times per result, each read bounded
  # by a narrow timestamp window. The hypertable is partitioned and indexed on
  # that column, so each read must reach it through an index on the timestamp.
  # A read that compares a cast of the column matches no index and scans every
  # chunk of the table.
  test "the ingestor's ServiceStatus window reads are bounded by the timestamp index" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [SuccessfulHandler])
    {payload, status, _observed_at} = plugin_result_fixture()

    reads =
      capture_service_status_reads(fn ->
        assert :ok = PluginResultIngestor.ingest(payload, status)
      end)

    assert reads != []
    # The table holds a handful of rows here, so make the planner show whether
    # an index can serve the read rather than pick a cheaper sequential scan.
    Repo.query!("SET LOCAL enable_seqscan = off")

    for {sql, params} <- reads do
      assert sql
             |> explain_json(params)
             |> index_conditions()
             |> Enum.any?(&(&1 =~ ~s("timestamp"))),
             "service_status read is not bounded by a timestamp index:\n#{sql}"
    end
  end

  defp capture_service_status_reads(fun) do
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:service_radar, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if String.starts_with?(metadata.query, "SELECT") and
             String.contains?(metadata.query, ~s(FROM "platform"."service_status")) do
          send(test_pid, {:service_status_read, metadata.query, metadata.params})
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    collect_service_status_reads([])
  end

  defp collect_service_status_reads(reads) do
    receive do
      {:service_status_read, sql, params} -> collect_service_status_reads([{sql, params} | reads])
    after
      0 -> Enum.reverse(reads)
    end
  end

  defp explain_json(sql, params) do
    %{rows: [[plan]]} = Repo.query!("EXPLAIN (FORMAT JSON) " <> sql, params)
    plan
  end

  defp index_conditions(plan) when is_list(plan), do: Enum.flat_map(plan, &index_conditions/1)

  defp index_conditions(%{} = node) do
    own = if is_binary(node["Index Cond"]), do: [node["Index Cond"]], else: []

    children =
      Enum.flat_map(List.wrap(node["Plan"]) ++ List.wrap(node["Plans"]), &index_conditions/1)

    own ++ children
  end
end
