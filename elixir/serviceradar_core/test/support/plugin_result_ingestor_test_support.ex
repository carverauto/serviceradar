defmodule ServiceRadar.Observability.PluginResultIngestorTestSupport do
  @moduledoc false

  import ExUnit.Assertions

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Gateway
  alias ServiceRadar.Repo

  defmacro __using__(_opts) do
    quote do
      use ServiceRadar.DataCase, async: false

      import ExUnit.CaptureLog
      import ServiceRadar.Observability.PluginResultIngestorTestSupport

      alias ServiceRadar.Observability.PluginResultIngestor
      alias ServiceRadar.Observability.PluginResultIngestorTest.ExitingHandler
      alias ServiceRadar.Observability.PluginResultIngestorTest.FailingHandler
      alias ServiceRadar.Observability.PluginResultIngestorTest.LongErrorHandler
      alias ServiceRadar.Observability.PluginResultIngestorTest.RaisingSupportHandler
      alias ServiceRadar.Observability.PluginResultIngestorTest.RejectingStateRegistry
      alias ServiceRadar.Observability.PluginResultIngestorTest.ReplayHandler
      alias ServiceRadar.Observability.PluginResultIngestorTest.SecondaryReplayHandler
      alias ServiceRadar.Observability.PluginResultIngestorTest.SensitiveCredentialHandler
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
            LongErrorHandler,
            RaisingSupportHandler,
            RejectingStateRegistry,
            ReplayHandler,
            SecondaryReplayHandler,
            SensitiveCredentialHandler,
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
  def plugin_result_fixture do
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
