defmodule ServiceRadar.Observability.PluginResultIngestorTestSupport do
  @moduledoc false

  import ExUnit.Assertions

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Gateway
  alias ServiceRadar.Observability.PluginResultSlot
  alias ServiceRadar.Observability.ServiceIdentity
  alias ServiceRadar.Repo

  defmacro __using__(_opts) do
    quote do
      use ServiceRadar.DataCase, async: false

      import ExUnit.CaptureLog
      import ServiceRadar.Observability.PluginResultIngestorTestSupport
      import ServiceRadar.Observability.PluginResultRepairAssignmentSupport

      alias ServiceRadar.Observability.PluginResultIngestor
      alias ServiceRadar.Observability.PluginResultIngestorTest.AcceptingStateRegistry
      alias ServiceRadar.Observability.PluginResultIngestorTest.ExitingHandler
      alias ServiceRadar.Observability.PluginResultIngestorTest.FailingHandler
      alias ServiceRadar.Observability.PluginResultIngestorTest.LongErrorHandler
      alias ServiceRadar.Observability.PluginResultIngestorTest.RaisingSupportHandler
      alias ServiceRadar.Observability.PluginResultIngestorTest.RejectingStateRegistry
      alias ServiceRadar.Observability.PluginResultIngestorTest.ReplayHandler
      alias ServiceRadar.Observability.PluginResultIngestorTest.SecondaryReplayHandler
      alias ServiceRadar.Observability.PluginResultIngestorTest.SensitiveCredentialHandler
      alias ServiceRadar.Observability.PluginResultIngestorTest.SuccessfulHandler
      alias ServiceRadar.Observability.PluginResultIngestorTest.TextErrorHandler
      alias ServiceRadar.Observability.PluginResultIngestorTest.ThrowingHandler
      alias ServiceRadar.Observability.ServiceStatePubSub
      alias ServiceRadar.Observability.ServiceStateRegistry
      alias ServiceRadar.Observability.ServiceStatus
      alias ServiceRadar.Observability.ServiceStatusPubSub
      alias ServiceRadar.Repo
      alias ServiceRadar.ResultsRouter

      setup do
        Enum.each(
          [
            ExitingHandler,
            FailingHandler,
            AcceptingStateRegistry,
            LongErrorHandler,
            RaisingSupportHandler,
            RejectingStateRegistry,
            ReplayHandler,
            SecondaryReplayHandler,
            SensitiveCredentialHandler,
            SuccessfulHandler,
            TextErrorHandler,
            ThrowingHandler
          ],
          &Code.ensure_loaded!/1
        )

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
    end
  end

  @doc false
  def plugin_result_fixture(opts \\ []) do
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

    if Keyword.get(opts, :assignment?, true) do
      ServiceRadar.Observability.PluginResultRepairAssignmentSupport.create_repair_assignment!(
        status
      )
    end

    {payload, status, observed_at}
  end

  @doc false
  def history_rows(status) do
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

  @doc false
  def reported_history_rows(status) do
    Enum.filter(history_rows(status), fn [_timestamp, _available, _message, details] ->
      get_in(Jason.decode!(details), ["_serviceradar_plugin_result", "kind"]) == "reported"
    end)
  end

  @doc false
  def reported_history_row(status, logical_observed_at, message \\ nil) do
    observation_timestamp = DateTime.to_iso8601(logical_observed_at)

    Enum.find(reported_history_rows(status), fn [_timestamp, _available, row_message, details] ->
      marker = details |> Jason.decode!() |> Map.fetch!("_serviceradar_plugin_result")

      marker["observation_timestamp"] == observation_timestamp and
        (is_nil(message) or row_message == message)
    end)
  end

  @doc false
  def reported_event_block_base(status, logical_observed_at, message \\ nil) do
    status
    |> reported_history_row(logical_observed_at, message)
    |> assert_reported_event_block(logical_observed_at)
  end

  @doc false
  def downstream_history_rows(status) do
    Enum.filter(history_rows(status), fn [_timestamp, _available, _message, details] ->
      is_map(get_in(Jason.decode!(details), ["downstream_ingest"]))
    end)
  end

  @doc false
  def assert_reported_event_block([timestamp, _available, _message, details], logical_observed_at) do
    marker = details |> Jason.decode!() |> Map.fetch!("_serviceradar_plugin_result")
    slot = Map.fetch!(marker, "slot")
    width = PluginResultSlot.block_width_microseconds()

    assert marker["kind"] == "reported"
    assert marker["observation_timestamp"] == DateTime.to_iso8601(logical_observed_at)
    assert slot["base_timestamp"] == DateTime.to_iso8601(timestamp)
    assert slot["version"] == 1
    assert slot["width_microseconds"] == width
    assert rem(DateTime.to_unix(timestamp, :microsecond), width) == 0

    assert DateTime.compare(
             DateTime.add(timestamp, width - 1, :microsecond),
             logical_observed_at
           ) in [:lt, :eq]

    assert PluginResultSlot.within_allocation_window?(timestamp, logical_observed_at)

    timestamp
  end

  @doc false
  def assert_handler_marker_in_block(
        [timestamp, _available, _message, details],
        block_base,
        logical_observed_at
      ) do
    marker = details |> Jason.decode!() |> Map.fetch!("downstream_ingest")
    expected_offset = marker_offset(marker["generation"], marker["status"])

    assert marker["observation_timestamp"] == DateTime.to_iso8601(logical_observed_at)
    assert timestamp == DateTime.add(block_base, expected_offset, :microsecond)

    marker
  end

  @doc false
  def marker_timestamp(block_base, generation, status) do
    DateTime.add(block_base, marker_offset(generation, status), :microsecond)
  end

  defp marker_offset(generation, "failed"), do: generation * 2 - 1
  defp marker_offset(generation, "succeeded"), do: generation * 2

  @doc false
  def current_state_rows(status) do
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

  @doc false
  def current_state_rows_with_state(status) do
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

  @doc false
  def logical_current_state_rows(status) do
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

  @doc false
  def logical_current_state_detail_rows(status) do
    Repo.query!(
      """
      SELECT
        gateway_id,
        available,
        message,
        last_observed_at AT TIME ZONE 'UTC',
        state
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

  @doc false
  def current_state_details(status) do
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

  @doc false
  def insert_history_status(status, payload, observed_at, message) do
    insert_history_status_row(status, payload, observed_at, message, nil)
  end

  @doc false
  def insert_history_status_with_service_id(status, payload, observed_at, message) do
    insert_history_status_row(
      status,
      payload,
      observed_at,
      message,
      ServiceIdentity.service_id(status)
    )
  end

  defp insert_history_status_row(status, payload, observed_at, message, service_id) do
    Repo.query!(
      """
      INSERT INTO platform.service_status (
        timestamp,
        gateway_id,
        agent_id,
        service_id,
        service_name,
        service_type,
        available,
        message,
        details,
        partition,
        created_at
      )
      VALUES ($1, $2, $3, $4::text::uuid, $5, $6, true, $7, $8, $9, $1)
      """,
      [
        observed_at,
        status.gateway_id,
        status.agent_id,
        service_id,
        status.service_name,
        status.service_type,
        message,
        Jason.encode!(payload),
        status.partition
      ]
    )
  end

  @doc false
  def seed_service_state(status, observed_at, opts) do
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

  @doc false
  def create_agent(agent_id, gateway_id) do
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

  @doc false
  def restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)

  def restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
