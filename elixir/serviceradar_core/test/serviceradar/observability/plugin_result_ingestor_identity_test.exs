defmodule ServiceRadar.Observability.PluginResultIngestorIdentityTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

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

    first_failure_at = DateTime.add(observed_at, 1, :microsecond)
    second_reported_at = DateTime.add(observed_at, 2, :microsecond)
    second_failure_at = DateTime.add(observed_at, 3, :microsecond)

    assert [
             [^observed_at, true, _, _],
             [^first_failure_at, false, _, first_failure_details]
           ] = history_rows(first_status)

    assert [
             [^second_reported_at, true, "edge plugin completed", second_reported_details],
             [^second_failure_at, false, _, second_failure_details]
           ] =
             history_rows(second_status)

    assert %{
             "_serviceradar_plugin_result" => %{
               "kind" => "reported",
               "observation_timestamp" => observation_timestamp
             }
           } = Jason.decode!(second_reported_details)

    assert observation_timestamp == DateTime.to_iso8601(observed_at)

    assert %{"downstream_ingest" => %{"generation" => 1}} =
             Jason.decode!(first_failure_details)

    assert %{"downstream_ingest" => %{"generation" => 2}} =
             Jason.decode!(second_failure_details)

    assert [[false, _, ^first_failure_at]] = current_state_rows(first_status)
    assert [[false, _, ^second_failure_at]] = current_state_rows(second_status)
  end

  test "state proof preserves the authenticated gateway instead of the agent registry gateway" do
    {payload, status, observed_at} = plugin_result_fixture()
    registry_gateway = "#{status.gateway_id}-registry"
    create_agent(status.agent_id, registry_gateway)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    ReplayHandler.put_outcomes([:ok, {:error, :replayed_failure}])

    assert :ok = PluginResultIngestor.ingest(payload, status)

    assert {:error, {:plugin_result_handlers_failed, [{ReplayHandler, ":replayed_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    failed_at = DateTime.add(observed_at, 1, :microsecond)
    proven_at = DateTime.add(observed_at, 2, :microsecond)

    assert [
             [^observed_at, true, _, _],
             [^failed_at, false, _, _],
             [^proven_at, true, _, _]
           ] = history_rows(status)

    assert [[true, "edge plugin completed", ^proven_at]] = current_state_rows(status)
    assert [] = current_state_rows(%{status | gateway_id: registry_gateway})
  end

  test "physical slot reallocation carries forward same-provenance state proof" do
    {payload, status, observed_at} = plugin_result_fixture()

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    ReplayHandler.put_outcomes([:ok, {:error, :late_failure}])

    assert :ok = PluginResultIngestor.ingest(payload, status)

    collision_status = %{
      status
      | agent_id: "#{status.agent_id}-collision",
        partition: "collision-partition",
        service_type: "plugin-collision"
    }

    collision_at = DateTime.add(observed_at, 1, :microsecond)
    insert_history_status(collision_status, %{"status" => "CRITICAL"}, collision_at, "occupied")

    assert {:error, {:plugin_result_handlers_failed, [{ReplayHandler, ":late_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    reallocated_failure_at = DateTime.add(observed_at, 3, :microsecond)
    reallocated_success_at = DateTime.add(observed_at, 4, :microsecond)

    assert [
             [^observed_at, true, _, _],
             [^reallocated_failure_at, false, _, failure_details],
             [^reallocated_success_at, true, _, success_details]
           ] = history_rows(status)

    assert %{"downstream_ingest" => %{"generation" => 2, "status" => "failed"}} =
             Jason.decode!(failure_details)

    assert %{"downstream_ingest" => %{"generation" => 2, "status" => "succeeded"}} =
             Jason.decode!(success_details)

    assert [[true, "edge plugin completed", ^reallocated_success_at]] =
             current_state_rows(status)
  end

  test "marker allocation cannot cross the next genuine observation" do
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

    assert {:error,
            {:plugin_result_handler_failure_persistence_failed,
             [{FailingHandler, ":forced_failure"}], persistence_error}} =
             PluginResultIngestor.ingest(payload, status)

    assert persistence_error =~ "handler_marker_window_exhausted"

    assert [
             [^observed_at, true, "edge plugin completed", _],
             [^next_observed_at, true, "next observation", _]
           ] = history_rows(status)

    assert [] = current_state_rows(status)
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

    insert_history_status(collision_status, %{"status" => "OK"}, observed_at, "occupied")

    assert :ok = PluginResultIngestor.ingest(payload, status)

    shifted_reported_at = DateTime.add(observed_at, 1, :microsecond)
    succeeded_at = DateTime.add(observed_at, 4, :microsecond)

    assert [[^shifted_reported_at, true, "edge plugin completed", reported_details]] =
             history_rows(status)

    assert %{
             "_serviceradar_plugin_result" => %{"kind" => "reported"},
             "downstream_ingest" => %{"status" => "failed"}
           } = Jason.decode!(reported_details)

    assert %{
             "downstream_ingest" => %{
               "status" => "succeeded",
               "generation" => 2,
               "recovered_from_failure" => false
             }
           } = status |> current_state_details() |> Jason.decode!()

    assert [[true, "edge plugin completed", ^succeeded_at]] = current_state_rows(status)
  end

  test "results router leaves plugin result state ownership with the plugin ingestor" do
    previous_ingestor =
      Application.get_env(:serviceradar_core, :plugin_result_ingestor)

    Application.put_env(
      :serviceradar_core,
      :plugin_result_ingestor,
      PluginResultIngestor
    )

    on_exit(fn -> restore_env(:plugin_result_ingestor, previous_ingestor) end)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {payload, status, observed_at} = plugin_result_fixture()
    enclosing_timestamp = DateTime.add(observed_at, 10, :second)
    :ok = ServiceStatusPubSub.subscribe()

    routed_status =
      Map.merge(status, %{
        available: true,
        agent_timestamp: enclosing_timestamp,
        message: Jason.encode!(payload)
      })

    assert {:reply, :ok, %{}} =
             ResultsRouter.handle_call({:results_update, routed_status}, self(), %{})

    succeeded_at = DateTime.add(observed_at, 2, :microsecond)

    assert [[^observed_at, true, "edge plugin completed", _details]] =
             history_rows(status)

    assert [[true, "edge plugin completed", ^succeeded_at]] =
             current_state_rows(status)

    assert %{
             "downstream_ingest" => %{
               "generation" => 1,
               "observation_timestamp" => observation_timestamp,
               "status" => "succeeded"
             }
           } = status |> current_state_details() |> Jason.decode!()

    assert observation_timestamp == DateTime.to_iso8601(observed_at)
    refute succeeded_at == enclosing_timestamp

    assert_receive {:service_status_updated,
                    %ServiceStatus{
                      agent_id: agent_id,
                      gateway_id: gateway_id,
                      timestamp: ^observed_at
                    }}

    assert agent_id == status.agent_id
    assert gateway_id == status.gateway_id
    refute_receive {:service_status_updated, _duplicate}, 50
  end

  test "buffered results router persists and broadcasts through the plugin ingestor" do
    previous_ingestor = Application.get_env(:serviceradar_core, :plugin_result_ingestor)
    previous_batching = Application.get_env(:serviceradar_core, :results_router_batching)

    Application.put_env(:serviceradar_core, :plugin_result_ingestor, PluginResultIngestor)
    Application.put_env(:serviceradar_core, :results_router_batching, true)

    on_exit(fn ->
      restore_env(:plugin_result_ingestor, previous_ingestor)
      restore_env(:results_router_batching, previous_batching)
    end)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {payload, status, observed_at} = plugin_result_fixture()
    :ok = ServiceStatusPubSub.subscribe()

    routed_status =
      Map.merge(status, %{
        available: true,
        agent_timestamp: DateTime.add(observed_at, 15, :second),
        message: Jason.encode!(payload)
      })

    initial_state = %{buffer: [], buffer_size: 0, timer: nil}

    assert {:noreply, buffered_state} =
             ResultsRouter.handle_cast({:results_update, routed_status}, initial_state)

    assert buffered_state.buffer_size == 1
    assert [] = history_rows(status)

    assert {:noreply, flushed_state} = ResultsRouter.handle_info(:flush_results, buffered_state)
    if is_reference(flushed_state.timer), do: Process.cancel_timer(flushed_state.timer)

    succeeded_at = DateTime.add(observed_at, 2, :microsecond)
    assert [[^observed_at, true, "edge plugin completed", _]] = history_rows(status)
    assert [[true, "edge plugin completed", ^succeeded_at]] = current_state_rows(status)

    assert_receive {:service_status_updated, %ServiceStatus{timestamp: ^observed_at}}
    refute_receive {:service_status_updated, _duplicate}, 50
  end

  test "concurrent identities retain distinct reported history rows" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {payload, first_status, observed_at} = plugin_result_fixture()

    second_status = %{
      first_status
      | agent_id: "#{first_status.agent_id}-concurrent",
        partition: "concurrent-partition",
        service_type: "plugin-concurrent"
    }

    tasks =
      for status <- [first_status, second_status] do
        Task.async(fn -> PluginResultIngestor.ingest(payload, status) end)
      end

    assert [:ok, :ok] = Enum.map(tasks, &Task.await(&1, 5_000))

    assert [[first_reported_at, true, "edge plugin completed", first_details]] =
             history_rows(first_status)

    assert [[second_reported_at, true, "edge plugin completed", second_details]] =
             history_rows(second_status)

    assert [first_reported_at, second_reported_at] |> MapSet.new() |> MapSet.size() == 2
    assert observed_at in [first_reported_at, second_reported_at]

    for details <- [first_details, second_details] do
      assert %{"_serviceradar_plugin_result" => %{"kind" => "reported"}} =
               Jason.decode!(details)
    end

    assert [[true, _, _]] = current_state_rows(first_status)
    assert [[true, _, _]] = current_state_rows(second_status)
  end

  test "cross-gateway copies of one observation serialize one active logical state" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {payload, first_status, observed_at} = plugin_result_fixture()
    second_status = %{first_status | gateway_id: "#{first_status.gateway_id}-alternate"}

    observation_lock_identity =
      Jason.encode!([
        "plugin-result-observation",
        first_status.agent_id,
        first_status.partition,
        first_status.service_type,
        first_status.service_name,
        DateTime.to_iso8601(observed_at)
      ])

    parent = self()

    lock_holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
            observation_lock_identity
          ])

          send(parent, :cross_gateway_observation_lock_held)

          receive do
            :release_cross_gateway_observation_lock -> :ok
          after
            5_000 -> raise "timed out waiting to release cross-gateway observation lock"
          end
        end)
      end)

    assert_receive :cross_gateway_observation_lock_held

    tasks =
      for status <- [first_status, second_status] do
        Task.async(fn ->
          result = PluginResultIngestor.ingest(payload, status)
          send(parent, {:cross_gateway_ingest_done, status.gateway_id})
          result
        end)
      end

    refute_receive {:cross_gateway_ingest_done, _gateway_id}, 250
    send(lock_holder.pid, :release_cross_gateway_observation_lock)
    assert {:ok, :ok} = Task.await(lock_holder, 5_000)
    assert [:ok, :ok] = Enum.map(tasks, &Task.await(&1, 5_000))

    for status <- [first_status, second_status] do
      assert [[^observed_at, true, "edge plugin completed", details]] = history_rows(status)

      assert %{"_serviceradar_plugin_result" => %{"kind" => "reported"}} =
               Jason.decode!(details)
    end

    logical_states = logical_current_state_rows(first_status)
    assert length(logical_states) == 2
    assert Enum.count(logical_states, fn [_gateway_id, state] -> state == "active" end) == 1

    assert MapSet.new(logical_states, fn [gateway_id, _state] -> gateway_id end) ==
             MapSet.new([first_status.gateway_id, second_status.gateway_id])
  end

  test "notification-aware state upserts do not publish effects from a rolled-back transaction" do
    {_payload, status, observed_at} = plugin_result_fixture()
    :ok = ServiceStatePubSub.subscribe()

    attrs = %{
      agent_id: status.agent_id,
      gateway_id: status.gateway_id,
      partition: status.partition,
      service_type: status.service_type,
      service_name: status.service_name,
      available: false,
      message: "must roll back",
      timestamp: observed_at
    }

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert {:ok, notifications, side_effects} =
                        ServiceStateRegistry.upsert_from_status_strict_with_notifications(attrs)

               assert is_list(notifications)
               assert side_effects != []
               refute_receive {:service_state_updated, _state}
               Repo.rollback(:forced_rollback)
             end)

    refute_receive {:service_state_updated, _state}, 50
    assert [] = current_state_rows(status)
  end
end
