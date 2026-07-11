defmodule ServiceRadar.Observability.PluginResultIngestorTest do
  use ServiceRadar.DataCase, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Gateway
  alias ServiceRadar.Observability.PluginResultIngestor
  alias ServiceRadar.Observability.ServiceStatePubSub
  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Observability.ServiceStatus
  alias ServiceRadar.Observability.ServiceStatusPubSub
  alias ServiceRadar.Repo
  alias ServiceRadar.ResultsRouter

  defmodule FailingHandler do
    @moduledoc false

    def supports?(_payload, _status), do: true

    def ingest(payload, _status, _opts) do
      notify_test({:failing_handler_ingest, payload})
      {:error, :forced_failure}
    end

    defp notify_test(message) do
      if pid = Application.get_env(:serviceradar_core, :plugin_result_ingestor_test_pid) do
        send(pid, message)
      end
    end
  end

  defmodule RaisingSupportHandler do
    @moduledoc false

    def supports?(_payload, _status) do
      raise "support check failed api_token: \"do-not-persist\""
    end

    def ingest(_payload, _status, _opts) do
      send(
        Application.fetch_env!(:serviceradar_core, :plugin_result_ingestor_test_pid),
        :unexpected_support_handler_ingest
      )

      :ok
    end
  end

  defmodule LongErrorHandler do
    @moduledoc false

    def supports?(_payload), do: true

    def ingest(_payload, _status, _opts) do
      {:error,
       %{
         api_token: "do-not-persist",
         bearer: "bearer-structured-secret",
         credential: "credential-structured-secret",
         privateKey: "private-key-structured-secret",
         token: "bare-token-structured-secret",
         detail:
           "Authorization: Bearer bearer-text-secret " <>
             "token=bare-token-text-secret credential 'credential-text-secret' " <>
             "private_key=private-key-text-secret " <>
             "-----BEGIN PRIVATE KEY-----pem-text-secret-----END PRIVATE KEY----- " <>
             String.duplicate("x", 2_000)
       }}
    end
  end

  defmodule ReplayHandler do
    @moduledoc false

    @outcomes_key {__MODULE__, :outcomes}

    def put_outcomes(outcomes), do: Process.put(@outcomes_key, outcomes)

    def supports?(_payload, _status), do: true

    def ingest(_payload, _status, _opts) do
      case Process.get(@outcomes_key, []) do
        [outcome | rest] ->
          Process.put(@outcomes_key, rest)
          outcome

        [] ->
          :ok
      end
    end
  end

  defmodule SecondaryReplayHandler do
    @moduledoc false

    @outcomes_key {__MODULE__, :outcomes}

    def put_outcomes(outcomes), do: Process.put(@outcomes_key, outcomes)

    def supports?(_payload, _status), do: true

    def ingest(_payload, _status, _opts) do
      case Process.get(@outcomes_key, []) do
        [outcome | rest] ->
          Process.put(@outcomes_key, rest)
          outcome

        [] ->
          :ok
      end
    end
  end

  defmodule TextErrorHandler do
    @moduledoc false

    def supports?(_payload, _status), do: true

    def ingest(_payload, _status, _opts) do
      {:error,
       "Authorization: Bearer bearer-text-secret " <>
         "token=bare-token-text-secret credential 'credential-text-secret' " <>
         "private_key=private-key-text-secret " <>
         "-----BEGIN PRIVATE KEY-----pem-text-secret-----END PRIVATE KEY-----"}
    end
  end

  defmodule SensitiveCredentialHandler do
    @moduledoc false

    def supports?(_payload, _status), do: true

    def ingest(_payload, _status, _opts) do
      private_key_begin = "-----BEGIN " <> "PRIVATE KEY-----\n"
      private_key_end = "\n-----END " <> "PRIVATE KEY-----"
      rsa_private_key_begin = "-----BEGIN RSA " <> "PRIVATE KEY-----\n"

      {:error,
       %{
         detail:
           "Authorization: Basic basic-auth-secret\n" <>
             private_key_begin <>
             String.duplicate("long-pem-secret-", 100) <>
             private_key_end,
         unterminated:
           rsa_private_key_begin <>
             String.duplicate("unterminated-pem-secret-", 100)
       }}
    end
  end

  defmodule ThrowingHandler do
    @moduledoc false

    def supports?(_payload, _status), do: true
    def ingest(_payload, _status, _opts), do: throw({:token, "throw-token-secret"})
  end

  defmodule ExitingHandler do
    @moduledoc false

    def supports?(_payload, _status), do: true
    def ingest(_payload, _status, _opts), do: exit({:credential, "exit-credential-secret"})
  end

  defmodule RejectingStateRegistry do
    @moduledoc false

    def upsert_from_status_strict(_status) do
      {:error,
       %{
         credential: "state-credential-secret",
         private_key: "state-private-key-secret",
         token: "state-token-secret"
       }}
    end
  end

  setup do
    previous_handlers = Application.get_env(:serviceradar_core, :plugin_result_handlers)

    previous_registry =
      Application.get_env(:serviceradar_core, :plugin_result_state_registry)

    previous_test_pid =
      Application.get_env(:serviceradar_core, :plugin_result_ingestor_test_pid)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [FailingHandler])
    Application.put_env(:serviceradar_core, :plugin_result_ingestor_test_pid, self())

    on_exit(fn ->
      restore_env(:plugin_result_handlers, previous_handlers)
      restore_env(:plugin_result_state_registry, previous_registry)
      restore_env(:plugin_result_ingestor_test_pid, previous_test_pid)
    end)

    :ok
  end

  test "records downstream handler failures as the current unavailable state" do
    {payload, status, observed_at} = plugin_result_fixture()

    assert {:error, {:plugin_result_handlers_failed, [{FailingHandler, ":forced_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert_receive {:failing_handler_ingest, ^payload}

    assert [
             [^observed_at, true, "edge plugin completed", _reported_details],
             [failed_at, false, failure_message, details]
           ] = history_rows(status)

    assert failed_at == DateTime.add(observed_at, 1, :microsecond)

    assert failure_message ==
             "Plugin result downstream ingest failed: " <>
               "ServiceRadar.Observability.PluginResultIngestorTest.FailingHandler"

    assert %{
             "downstream_ingest" => %{
               "status" => "failed",
               "generation" => 1,
               "handler_set" => %{
                 "id" => handler_set_id,
                 "version" => 1
               },
               "observation_timestamp" => observation_timestamp,
               "handlers" => [
                 %{
                   "handler" =>
                     "ServiceRadar.Observability.PluginResultIngestorTest.FailingHandler",
                   "error" => ":forced_failure"
                 }
               ]
             },
             "reported_result" => ^payload
           } = Jason.decode!(details)

    assert is_binary(handler_set_id)
    assert byte_size(handler_set_id) == 64
    assert observation_timestamp == DateTime.to_iso8601(observed_at)

    assert [[false, ^failure_message, ^failed_at]] = current_state_rows(status)
  end

  test "duplicate observations rerun handlers without duplicating history" do
    {payload, status, observed_at} = plugin_result_fixture()
    :ok = ServiceStatePubSub.subscribe()

    expected_error =
      {:error, {:plugin_result_handlers_failed, [{FailingHandler, ":forced_failure"}]}}

    assert ^expected_error = PluginResultIngestor.ingest(payload, status)
    assert_receive {:service_state_updated, _state}

    assert ^expected_error = PluginResultIngestor.ingest(payload, status)
    refute_receive {:service_state_updated, _state}, 50

    assert_receive {:failing_handler_ingest, ^payload}
    assert_receive {:failing_handler_ingest, ^payload}

    assert [
             [^observed_at, true, "edge plugin completed", _],
             [failed_at, false, _, _]
           ] = history_rows(status)

    assert failed_at == DateTime.add(observed_at, 1, :microsecond)
  end

  test "successful replay records recovery after an initial handler failure" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    ReplayHandler.put_outcomes([{:error, :transient_failure}, :ok])
    {payload, status, observed_at} = plugin_result_fixture()

    assert {:error, {:plugin_result_handlers_failed, [{ReplayHandler, ":transient_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert :ok = PluginResultIngestor.ingest(payload, status)

    failed_at = DateTime.add(observed_at, 1, :microsecond)
    recovered_at = DateTime.add(observed_at, 2, :microsecond)

    assert [
             [^observed_at, true, "edge plugin completed", _],
             [^failed_at, false, _, _],
             [^recovered_at, true, "edge plugin completed", recovery_history_details]
           ] = history_rows(status)

    recovery_details = current_state_details(status)
    assert recovery_details == recovery_history_details

    assert %{
             "downstream_ingest" => %{
               "status" => "succeeded",
               "generation" => 1,
               "handler_set" => %{"id" => handler_set_id, "version" => 1},
               "recovered_from_failure" => true
             }
           } = Jason.decode!(recovery_details)

    assert is_binary(handler_set_id)

    assert [[true, "edge plugin completed", ^recovered_at]] = current_state_rows(status)
  end

  test "a failing duplicate cannot downgrade an already successful observation" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])

    ReplayHandler.put_outcomes([
      :ok,
      {:error, :late_duplicate_failure},
      {:error, :repeated_duplicate_failure}
    ])

    {payload, status, observed_at} = plugin_result_fixture()

    assert :ok = PluginResultIngestor.ingest(payload, status)

    assert {:error,
            {:plugin_result_handlers_failed, [{ReplayHandler, ":late_duplicate_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    recovered_at = DateTime.add(observed_at, 2, :microsecond)
    assert [[true, "edge plugin completed", ^recovered_at]] = current_state_rows(status)

    assert {:error,
            {:plugin_result_handlers_failed, [{ReplayHandler, ":repeated_duplicate_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert [[true, "edge plugin completed", ^recovered_at]] = current_state_rows(status)

    assert [
             [^observed_at, true, "edge plugin completed", _],
             [failed_at, false, _, _],
             [^recovered_at, true, "edge plugin completed", _]
           ] = history_rows(status)

    assert failed_at == DateTime.add(observed_at, 1, :microsecond)
  end

  test "older observations cannot replace newer current state" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {payload, status, observed_at} = plugin_result_fixture()
    newer_at = DateTime.add(observed_at, 10, :second)

    newer_payload = %{
      payload
      | "status" => "CRITICAL",
        "summary" => "newer critical result",
        "observed_at" => DateTime.to_iso8601(newer_at)
    }

    assert :ok = PluginResultIngestor.ingest(newer_payload, status)
    assert :ok = PluginResultIngestor.ingest(payload, status)

    newer_succeeded_at = DateTime.add(newer_at, 2, :microsecond)

    assert [[false, "newer critical result", ^newer_succeeded_at]] =
             current_state_rows(status)
  end

  test "unavailable wins equal-timestamp current-state conflicts in either arrival order" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {healthy_payload, first_status, observed_at} = plugin_result_fixture()

    unavailable_payload = %{
      healthy_payload
      | "status" => "CRITICAL",
        "summary" => "same-time critical result"
    }

    assert :ok = PluginResultIngestor.ingest(healthy_payload, first_status)
    assert :ok = PluginResultIngestor.ingest(unavailable_payload, first_status)
    assert :ok = PluginResultIngestor.ingest(healthy_payload, first_status)

    succeeded_at = DateTime.add(observed_at, 2, :microsecond)

    assert [[false, "same-time critical result", ^succeeded_at]] =
             current_state_rows(first_status)

    {_payload, second_status, _observed_at} = plugin_result_fixture()

    assert :ok = PluginResultIngestor.ingest(unavailable_payload, second_status)
    assert :ok = PluginResultIngestor.ingest(healthy_payload, second_status)

    assert [[false, "same-time critical result", ^succeeded_at]] =
             current_state_rows(second_status)
  end

  test "a legacy raw state cannot prove downstream success on replay" do
    {payload, status, observed_at} = plugin_result_fixture()
    insert_history_status(status, payload, observed_at, "edge plugin completed")

    seed_service_state(status, observed_at,
      available: true,
      message: "edge plugin completed",
      state: "inactive"
    )

    other_gateway_status = %{status | gateway_id: "#{status.gateway_id}-other"}

    seed_service_state(other_gateway_status, observed_at,
      available: true,
      message: "edge plugin completed",
      state: "active"
    )

    assert {:error, {:plugin_result_handlers_failed, [{FailingHandler, ":forced_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    failed_at = DateTime.add(observed_at, 1, :microsecond)

    assert [
             [^observed_at, true, "edge plugin completed", _],
             [^failed_at, false, _, failure_details]
           ] = history_rows(status)

    assert %{"downstream_ingest" => %{"status" => "failed", "generation" => 1}} =
             Jason.decode!(failure_details)

    assert [[false, _, ^failed_at, "active"]] = current_state_rows_with_state(status)

    assert [[true, "edge plugin completed", ^observed_at, "inactive"]] =
             current_state_rows_with_state(other_gateway_status)
  end

  test "handler-set generations order new failures and same-set replay success" do
    {payload, status, observed_at} = plugin_result_fixture()

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    ReplayHandler.put_outcomes([:ok])

    assert :ok = PluginResultIngestor.ingest(payload, status)

    first_success_at = DateTime.add(observed_at, 2, :microsecond)
    assert [[true, "edge plugin completed", ^first_success_at]] = current_state_rows(status)

    assert [[^observed_at, true, "edge plugin completed", _]] = history_rows(status)

    assert %{
             "downstream_ingest" => %{
               "generation" => 1,
               "handler_set" => %{"id" => first_set_id},
               "status" => "succeeded"
             }
           } = status |> current_state_details() |> Jason.decode!()

    Application.put_env(
      :serviceradar_core,
      :plugin_result_handlers,
      [ReplayHandler, SecondaryReplayHandler]
    )

    ReplayHandler.put_outcomes([:ok, :ok, :ok])

    SecondaryReplayHandler.put_outcomes([
      {:error, :new_handler_failure},
      :ok,
      {:error, :replayed_failure}
    ])

    assert {:error,
            {:plugin_result_handlers_failed, [{SecondaryReplayHandler, ":new_handler_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    second_failure_at = DateTime.add(observed_at, 3, :microsecond)
    assert [[false, _, ^second_failure_at]] = current_state_rows(status)

    assert :ok = PluginResultIngestor.ingest(payload, status)

    second_success_at = DateTime.add(observed_at, 4, :microsecond)
    assert [[true, "edge plugin completed", ^second_success_at]] = current_state_rows(status)

    assert {:error,
            {:plugin_result_handlers_failed, [{SecondaryReplayHandler, ":replayed_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert [[true, "edge plugin completed", ^second_success_at]] = current_state_rows(status)

    second_success_details = current_state_details(status)

    assert [
             [^observed_at, true, _, _],
             [^second_failure_at, false, _, second_failure_details],
             [^second_success_at, true, _, recovery_history_details]
           ] = history_rows(status)

    assert recovery_history_details == second_success_details

    assert %{
             "downstream_ingest" => %{
               "generation" => 2,
               "handler_set" => %{"id" => second_set_id},
               "status" => "failed"
             }
           } = Jason.decode!(second_failure_details)

    assert %{
             "downstream_ingest" => %{
               "generation" => 2,
               "handler_set" => %{"id" => ^second_set_id},
               "recovered_from_failure" => true,
               "status" => "succeeded"
             }
           } = Jason.decode!(second_success_details)

    refute first_set_id == second_set_id
  end

  test "a new handler set records recovery from the prior set's failure" do
    {payload, status, observed_at} = plugin_result_fixture()

    assert {:error, {:plugin_result_handlers_failed, [{FailingHandler, ":forced_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    ReplayHandler.put_outcomes([:ok])

    assert :ok = PluginResultIngestor.ingest(payload, status)

    failed_at = DateTime.add(observed_at, 1, :microsecond)
    recovered_at = DateTime.add(observed_at, 4, :microsecond)

    assert [
             [^observed_at, true, _, _],
             [^failed_at, false, _, _],
             [^recovered_at, true, _, recovery_details]
           ] = history_rows(status)

    assert %{
             "downstream_ingest" => %{
               "generation" => 2,
               "recovered_from_failure" => true,
               "status" => "succeeded"
             }
           } = Jason.decode!(recovery_details)

    assert [[true, "edge plugin completed", ^recovered_at]] = current_state_rows(status)
    assert current_state_details(status) == recovery_details
  end

  test "returning to an older handler set allocates above the global generation" do
    {payload, status, observed_at} = plugin_result_fixture()

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    ReplayHandler.put_outcomes([{:error, :set_a_failure}, :ok, {:error, :set_a_returned}])

    assert {:error, {:plugin_result_handlers_failed, [{ReplayHandler, ":set_a_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert :ok = PluginResultIngestor.ingest(payload, status)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [SecondaryReplayHandler])
    SecondaryReplayHandler.put_outcomes([:ok])
    assert :ok = PluginResultIngestor.ingest(payload, status)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])

    assert {:error, {:plugin_result_handlers_failed, [{ReplayHandler, ":set_a_returned"}]}} =
             PluginResultIngestor.ingest(payload, status)

    first_failure_at = DateTime.add(observed_at, 1, :microsecond)
    first_recovery_at = DateTime.add(observed_at, 2, :microsecond)
    returned_failure_at = DateTime.add(observed_at, 5, :microsecond)

    assert [
             [^observed_at, true, _, _],
             [^first_failure_at, false, _, _],
             [^first_recovery_at, true, _, _],
             [^returned_failure_at, false, _, returned_failure_details]
           ] = history_rows(status)

    assert %{
             "downstream_ingest" => %{
               "generation" => 3,
               "status" => "failed"
             }
           } = Jason.decode!(returned_failure_details)

    assert [[false, _, ^returned_failure_at]] = current_state_rows(status)
  end

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

  test "support check exceptions become sanitized handler failures" do
    Application.put_env(
      :serviceradar_core,
      :plugin_result_handlers,
      [RaisingSupportHandler]
    )

    {payload, status, _observed_at} = plugin_result_fixture()

    assert {:error, {:plugin_result_handlers_failed, [{RaisingSupportHandler, error_text}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert error_text =~ "support_check_failed"
    assert error_text =~ "[REDACTED]"
    refute error_text =~ "do-not-persist"
    refute_received :unexpected_support_handler_ingest

    assert [[false, _, _]] = current_state_rows(status)

    assert [_, [_, false, _, details]] = history_rows(status)

    assert %{
             "downstream_ingest" => %{
               "handlers" => [%{"error" => ^error_text}]
             }
           } = Jason.decode!(details)
  end

  test "handler errors are redacted and bounded before logging or persistence" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [LongErrorHandler])
    {payload, status, _observed_at} = plugin_result_fixture()

    assert {:error, {:plugin_result_handlers_failed, [{LongErrorHandler, error_text}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert byte_size(error_text) <= 1_000
    assert error_text =~ "[REDACTED]"

    for secret <- [
          "do-not-persist",
          "bearer-structured-secret",
          "credential-structured-secret",
          "private-key-structured-secret",
          "bare-token-structured-secret",
          "bearer-text-secret",
          "bare-token-text-secret",
          "credential-text-secret",
          "private-key-text-secret",
          "pem-text-secret"
        ] do
      refute error_text =~ secret
    end

    assert [_, [_, false, _, details]] = history_rows(status)

    assert %{
             "downstream_ingest" => %{
               "handlers" => [%{"error" => persisted_error}]
             }
           } = Jason.decode!(details)

    assert persisted_error == error_text
  end

  test "long PEM values and Basic authorization are redacted before truncation" do
    Application.put_env(
      :serviceradar_core,
      :plugin_result_handlers,
      [SensitiveCredentialHandler]
    )

    {payload, status, _observed_at} = plugin_result_fixture()

    captured_log =
      capture_log(fn ->
        send(self(), {:sensitive_result, PluginResultIngestor.ingest(payload, status)})
      end)

    assert_receive {:sensitive_result,
                    {:error,
                     {:plugin_result_handlers_failed, [{SensitiveCredentialHandler, error_text}]}}}

    assert error_text =~ "[REDACTED]"
    assert error_text =~ "[REDACTED PRIVATE KEY]"

    assert [_, [_, false, _, details]] = history_rows(status)

    assert %{
             "downstream_ingest" => %{
               "handlers" => [%{"error" => persisted_error}]
             }
           } = Jason.decode!(details)

    assert persisted_error == error_text

    for secret <- [
          "basic-auth-secret",
          "long-pem-secret",
          "unterminated-pem-secret"
        ] do
      refute error_text =~ secret
      refute persisted_error =~ secret
      refute captured_log =~ secret
    end
  end

  test "textual bearer, token, credential, and private key forms are redacted" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [TextErrorHandler])
    {payload, status, _observed_at} = plugin_result_fixture()

    assert {:error, {:plugin_result_handlers_failed, [{TextErrorHandler, error_text}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert error_text =~ "[REDACTED]"

    for secret <- [
          "bearer-text-secret",
          "bare-token-text-secret",
          "credential-text-secret",
          "private-key-text-secret",
          "pem-text-secret"
        ] do
      refute error_text =~ secret
    end

    assert [_, [_, false, _, details]] = history_rows(status)

    assert %{
             "downstream_ingest" => %{
               "handlers" => [%{"error" => ^error_text}]
             }
           } = Jason.decode!(details)
  end

  test "handler throws and exits become redacted failures" do
    Application.put_env(
      :serviceradar_core,
      :plugin_result_handlers,
      [ThrowingHandler, ExitingHandler]
    )

    {payload, status, _observed_at} = plugin_result_fixture()

    assert {:error,
            {:plugin_result_handlers_failed,
             [{ThrowingHandler, throw_error}, {ExitingHandler, exit_error}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert throw_error =~ "throw"
    assert throw_error =~ "[REDACTED]"
    refute throw_error =~ "throw-token-secret"

    assert exit_error =~ "exit"
    assert exit_error =~ "[REDACTED]"
    refute exit_error =~ "exit-credential-secret"
    assert [[false, _, _]] = current_state_rows(status)
  end

  test "top-level ingest exceptions return only bounded sanitized text" do
    {payload, status, _observed_at} = plugin_result_fixture()

    assert {:error, {:plugin_result_ingest_failed, error_text}} =
             PluginResultIngestor.ingest(payload, {:invalid_status, status})

    assert is_binary(error_text)
    assert String.valid?(error_text)
    assert byte_size(error_text) <= 1_000
  end

  test "state persistence errors roll back markers and release the observation lock" do
    Application.put_env(
      :serviceradar_core,
      :plugin_result_state_registry,
      RejectingStateRegistry
    )

    {payload, status, observed_at} = plugin_result_fixture()

    assert {:error,
            {:plugin_result_handler_failure_persistence_failed,
             [{FailingHandler, ":forced_failure"}], persistence_error}} =
             PluginResultIngestor.ingest(payload, status)

    assert persistence_error =~ "[REDACTED]"
    assert byte_size(persistence_error) <= 1_000
    refute persistence_error =~ "state-credential-secret"
    refute persistence_error =~ "state-private-key-secret"
    refute persistence_error =~ "state-token-secret"

    assert [[^observed_at, true, "edge plugin completed", _]] = history_rows(status)
    assert [] = current_state_rows(status)

    Application.put_env(
      :serviceradar_core,
      :plugin_result_state_registry,
      ServiceStateRegistry
    )

    assert {:error, {:plugin_result_handlers_failed, [{FailingHandler, ":forced_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    failed_at = DateTime.add(observed_at, 1, :microsecond)

    assert [
             [^observed_at, true, "edge plugin completed", _],
             [^failed_at, false, _, _]
           ] = history_rows(status)

    assert [[false, _, ^failed_at]] = current_state_rows(status)
  end

  defp plugin_result_fixture do
    suffix = System.unique_integer([:positive])

    observed_at =
      DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.truncate(:microsecond)

    payload = %{
      "status" => "OK",
      "summary" => "edge plugin completed",
      "observed_at" => DateTime.to_iso8601(observed_at)
    }

    status = %{
      source: "plugin-result",
      agent_id: "plugin-handler-agent-#{suffix}",
      gateway_id: "plugin-handler-gateway-#{suffix}",
      partition: "default",
      service_type: "plugin",
      service_name: "plugin-handler-service-#{suffix}"
    }

    {payload, status, observed_at}
  end

  defp history_rows(status) do
    Repo.query!(
      """
      SELECT timestamp, available, message, details
      FROM platform.service_status
      WHERE agent_id = $1
        AND gateway_id = $2
        AND partition = $3
        AND service_type = $4
        AND service_name = $5
      ORDER BY timestamp
      """,
      [
        status.agent_id,
        status.gateway_id,
        status.partition,
        status.service_type,
        status.service_name
      ]
    ).rows
  end

  defp current_state_rows(status) do
    Repo.query!(
      """
      SELECT available, message, last_observed_at AT TIME ZONE 'UTC'
      FROM platform.service_state
      WHERE agent_id = $1
        AND gateway_id = $2
        AND partition = $3
        AND service_type = $4
        AND service_name = $5
      """,
      [
        status.agent_id,
        status.gateway_id,
        status.partition,
        status.service_type,
        status.service_name
      ]
    ).rows
  end

  defp current_state_rows_with_state(status) do
    Repo.query!(
      """
      SELECT available, message, last_observed_at AT TIME ZONE 'UTC', state
      FROM platform.service_state
      WHERE agent_id = $1
        AND gateway_id = $2
        AND partition = $3
        AND service_type = $4
        AND service_name = $5
      """,
      [
        status.agent_id,
        status.gateway_id,
        status.partition,
        status.service_type,
        status.service_name
      ]
    ).rows
  end

  defp logical_current_state_rows(status) do
    Repo.query!(
      """
      SELECT gateway_id, state
      FROM platform.service_state
      WHERE agent_id = $1
        AND partition = $2
        AND service_type = $3
        AND service_name = $4
      ORDER BY gateway_id
      """,
      [
        status.agent_id,
        status.partition,
        status.service_type,
        status.service_name
      ]
    ).rows
  end

  defp current_state_details(status) do
    Repo.query!(
      """
      SELECT details
      FROM platform.service_state
      WHERE agent_id = $1
        AND gateway_id = $2
        AND partition = $3
        AND service_type = $4
        AND service_name = $5
      """,
      [
        status.agent_id,
        status.gateway_id,
        status.partition,
        status.service_type,
        status.service_name
      ]
    ).rows
    |> List.first()
    |> List.first()
  end

  defp insert_history_status(status, payload, observed_at, message) do
    Repo.query!(
      """
      INSERT INTO platform.service_status (
        timestamp,
        gateway_id,
        agent_id,
        service_name,
        service_type,
        available,
        message,
        details,
        partition,
        created_at
      )
      VALUES ($1, $2, $3, $4, $5, true, $6, $7, $8, $1)
      """,
      [
        observed_at,
        status.gateway_id,
        status.agent_id,
        status.service_name,
        status.service_type,
        message,
        Jason.encode!(payload),
        status.partition
      ]
    )
  end

  defp seed_service_state(status, observed_at, opts) do
    Repo.query!(
      """
      INSERT INTO platform.service_state (
        id,
        agent_id,
        gateway_id,
        partition,
        service_type,
        service_name,
        available,
        message,
        details,
        last_observed_at,
        state,
        inserted_at,
        updated_at
      )
      VALUES (
        gen_random_uuid(),
        $1,
        $2,
        $3,
        $4,
        $5,
        $6,
        $7,
        $7,
        $8::timestamptz AT TIME ZONE 'UTC',
        $9,
        now() AT TIME ZONE 'UTC',
        now() AT TIME ZONE 'UTC'
      )
      """,
      [
        status.agent_id,
        status.gateway_id,
        status.partition,
        status.service_type,
        status.service_name,
        Keyword.fetch!(opts, :available),
        Keyword.fetch!(opts, :message),
        observed_at,
        Keyword.fetch!(opts, :state)
      ]
    )
  end

  defp create_agent(agent_id, gateway_id) do
    actor = SystemActor.system(:plugin_result_ingestor_test)

    assert {:ok, _gateway} =
             Gateway
             |> Ash.Changeset.for_create(:register, %{id: gateway_id}, actor: actor)
             |> Ash.create(domain: ServiceRadar.Infrastructure)

    assert {:ok, _agent} =
             Agent
             |> Ash.Changeset.for_create(
               :register,
               %{
                 uid: agent_id,
                 name: agent_id,
                 gateway_id: gateway_id
               },
               actor: actor
             )
             |> Ash.create(domain: ServiceRadar.Infrastructure)
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
