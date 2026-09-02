defmodule ServiceRadar.AgentCommands.StatusHandler do
  @moduledoc """
  Persists agent command ack/progress/result updates into AgentCommand records.
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentCommands.AdhocScanResultHandler
  alias ServiceRadar.AgentCommands.PubSub
  alias ServiceRadar.Automation.Ansible.AutomationResultSanitizer
  alias ServiceRadar.Automation.Ansible.CallbackCommandResultCoordinator
  alias ServiceRadar.Automation.Ansible.EventIngestor, as: AnsibleEventIngestor
  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandResultCoordinator
  alias ServiceRadar.Automation.CallbackGrants.CleanupReconciler

  alias ServiceRadar.Automation.Northbound.CommandResultHandler,
    as: NorthboundCommandResultHandler

  alias ServiceRadar.ControlRepo
  alias ServiceRadar.Edge.AgentReleaseManager
  alias ServiceRadar.Observability.MtrMetricsIngestor
  alias ServiceRadar.Observability.MtrPubSub
  alias ServiceRadar.Repo

  require Logger

  @cleanup_command_types ["awx.delete_callback_credential", "awx.cancel_job"]
  @result_coordination_supervisor ServiceRadar.AgentCommands.ResultCoordinationTaskSupervisor
  @result_coordination_shutdown_ms 65_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    PubSub.subscribe_ingress()

    actor = SystemActor.system(:agent_command_status)

    {:ok,
     %{
       actor: actor,
       ack_persister: Keyword.get(opts, :ack_persister, &persist_ack/2),
       progress_persister: Keyword.get(opts, :progress_persister, &persist_progress/2),
       persisted_ack_broadcaster:
         Keyword.get(opts, :persisted_ack_broadcaster, &PubSub.broadcast_persisted_ack/1),
       persisted_progress_broadcaster:
         Keyword.get(
           opts,
           :persisted_progress_broadcaster,
           &PubSub.broadcast_persisted_progress/1
         ),
       ack_consumer: Keyword.get(opts, :ack_consumer, default_ack_consumer(actor)),
       progress_consumers:
         Keyword.get(opts, :progress_consumers, default_progress_consumers(actor)),
       cleanup_reconciler: Keyword.get(opts, :cleanup_reconciler, CleanupReconciler),
       callback_result_coordinator:
         Keyword.get(opts, :callback_result_coordinator, CallbackCommandResultCoordinator),
       secure_execution_result_coordinator:
         Keyword.get(
           opts,
           :secure_execution_result_coordinator,
           SecureExecutionCommandResultCoordinator
         ),
       result_coordination_dispatcher:
         Keyword.get(opts, :result_coordination_dispatcher, &dispatch_result_coordination/1),
       result_persister: Keyword.get(opts, :result_persister, &persist_result/2),
       persisted_result_broadcaster:
         Keyword.get(opts, :persisted_result_broadcaster, &PubSub.broadcast_persisted_result/1),
       result_consumers:
         Keyword.get(opts, :result_consumers, [
           &safe_maybe_ingest_mtr_result/1,
           &AdhocScanResultHandler.handle_command_result/1,
           fn data ->
             AgentReleaseManager.handle_command_result(data,
               actor: SystemActor.system(:agent_command_status)
             )
           end,
           fn data ->
             AnsibleEventIngestor.handle_command_result(data,
               actor: SystemActor.system(:agent_command_status)
             )
           end,
           fn data ->
             NorthboundCommandResultHandler.handle_command_result(data,
               actor: SystemActor.system(:agent_command_status)
             )
           end
         ])
     }}
  end

  @impl true
  def handle_info({:command_ack, data}, state) do
    data = AutomationResultSanitizer.sanitize_ack(data)

    if persist_update_with(data, state, :ack_persister, &persist_ack/2, :ack) == :ok do
      safe_broadcast_persisted_update(
        data,
        Map.get(state, :persisted_ack_broadcaster, &PubSub.broadcast_persisted_ack/1),
        :ack
      )

      state
      |> Map.get(:ack_consumer, default_ack_consumer(Map.get(state, :actor)))
      |> safe_call_update_consumer(data, :ack)
    end

    {:noreply, state}
  end

  def handle_info({:command_progress, data}, state) do
    data = AutomationResultSanitizer.sanitize_progress(data)

    if persist_update_with(data, state, :progress_persister, &persist_progress/2, :progress) ==
         :ok do
      safe_broadcast_persisted_update(
        data,
        Map.get(
          state,
          :persisted_progress_broadcaster,
          &PubSub.broadcast_persisted_progress/1
        ),
        :progress
      )

      state
      |> Map.get(:progress_consumers, default_progress_consumers(Map.get(state, :actor)))
      |> Enum.each(&safe_call_update_consumer(&1, data, :progress))
    end

    {:noreply, state}
  end

  def handle_info({:command_result, data}, state) do
    safe_data = data |> AutomationResultSanitizer.sanitize() |> sanitize_cleanup_result()
    persisted? = persist_result_with(safe_data, state) == :ok

    if persisted? do
      safe_broadcast_persisted_result(
        safe_data,
        Map.get(state, :persisted_result_broadcaster, &PubSub.broadcast_persisted_result/1)
      )

      safe_reconcile_callback_cleanup(
        safe_data,
        Map.get(state, :cleanup_reconciler, CleanupReconciler)
      )

      safe_dispatch_result_coordination(safe_data, state)

      Enum.each(Map.get(state, :result_consumers, []), &safe_call_result_consumer(&1, safe_data))
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @spec sanitize_cleanup_result(map()) :: map()
  def sanitize_cleanup_result(data) when is_map(data) do
    command_type = map_get_any(data, [:command_type, "command_type"], nil)

    if command_type in @cleanup_command_types do
      success? = map_get_any(data, [:success, "success"], false) == true
      payload = map_get_any(data, [:payload, "payload", :result_payload, "result_payload"], %{})

      %{
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        command_type: command_type,
        agent_id: map_get_any(data, [:agent_id, "agent_id"], nil),
        partition_id: map_get_any(data, [:partition_id, "partition_id"], nil),
        success: success?
      }
      |> Map.put(:payload, safe_cleanup_payload(command_type, payload))
      |> Map.put(
        :message,
        if(success?, do: "cleanup command completed", else: "cleanup command failed")
      )
      |> Map.put(:failure_reason, if(success?, do: nil, else: "cleanup_command_failed"))
    else
      data
    end
  end

  def sanitize_cleanup_result(data), do: data

  defp safe_cleanup_payload("awx.delete_callback_credential", payload) do
    %{
      "verb" => safe_exact_string(payload, "verb", "awx.delete_callback_credential"),
      "ok" => map_get_any(payload, ["ok", :ok], false) == true,
      "credential_id" => safe_positive_integer(payload, "credential_id"),
      "credential_type_id" => safe_positive_integer(payload, "credential_type_id"),
      "cleanup_status" =>
        safe_enum_string(payload, "cleanup_status", ["deleted", "already_absent"])
    }
  end

  defp safe_cleanup_payload("awx.cancel_job", payload) do
    %{
      "verb" => safe_exact_string(payload, "verb", "awx.cancel_job"),
      "ok" => map_get_any(payload, ["ok", :ok], false) == true,
      "job_id" => safe_positive_integer(payload, "job_id"),
      "status" => safe_http_status(payload)
    }
  end

  defp safe_exact_string(payload, key, expected) do
    if safe_payload_value(payload, key) == expected,
      do: expected,
      else: "invalid"
  end

  defp safe_positive_integer(payload, key) do
    value = safe_payload_value(payload, key)
    if is_integer(value) and value > 0 and value <= 2_147_483_647, do: value
  end

  defp safe_enum_string(payload, key, allowed) do
    value = safe_payload_value(payload, key)
    if value in allowed, do: value, else: "invalid"
  end

  defp safe_http_status(payload) do
    value = map_get_any(payload, ["status", :status], nil)
    if is_integer(value) and value in 100..599, do: value
  end

  defp safe_payload_value(payload, "verb"), do: map_get_any(payload, ["verb", :verb], nil)

  defp safe_payload_value(payload, "credential_id"),
    do: map_get_any(payload, ["credential_id", :credential_id], nil)

  defp safe_payload_value(payload, "credential_type_id"),
    do: map_get_any(payload, ["credential_type_id", :credential_type_id], nil)

  defp safe_payload_value(payload, "job_id"), do: map_get_any(payload, ["job_id", :job_id], nil)

  defp safe_payload_value(payload, "cleanup_status"),
    do: map_get_any(payload, ["cleanup_status", :cleanup_status], nil)

  defp safe_payload_value(_payload, _key), do: nil

  defp safe_reconcile_callback_cleanup(data, reconciler) do
    cond do
      is_function(reconciler, 1) -> reconciler.(data)
      is_atom(reconciler) -> reconciler.handle_command_result(data)
      true -> {:error, :cleanup_reconciler_unavailable}
    end

    :ok
  rescue
    exception ->
      Logger.warning("AgentCommandStatusHandler: callback cleanup reconciliation failed",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        command_type: map_get_any(data, [:command_type, "command_type"], nil),
        exception: exception.__struct__
      )

      :ok
  catch
    kind, _reason ->
      Logger.warning("AgentCommandStatusHandler: callback cleanup reconciliation failed",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        command_type: map_get_any(data, [:command_type, "command_type"], nil),
        failure_kind: kind
      )

      :ok
  end

  defp safe_coordinate_callback_result(data, coordinator) do
    cond do
      is_function(coordinator, 1) -> coordinator.(data)
      is_atom(coordinator) -> coordinator.handle_command_result(data)
      true -> {:error, :callback_result_coordinator_unavailable}
    end

    :ok
  rescue
    exception ->
      Logger.warning("AgentCommandStatusHandler: callback result coordination failed",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        command_type: map_get_any(data, [:command_type, "command_type"], nil),
        exception: exception.__struct__
      )

      :ok
  catch
    kind, _reason ->
      Logger.warning("AgentCommandStatusHandler: callback result coordination failed",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        command_type: map_get_any(data, [:command_type, "command_type"], nil),
        failure_kind: kind
      )

      :ok
  end

  defp safe_coordinate_secure_execution_result(data, coordinator) do
    cond do
      is_function(coordinator, 1) -> coordinator.(data)
      is_atom(coordinator) -> coordinator.handle_command_result(data)
      true -> {:error, :secure_execution_result_coordinator_unavailable}
    end

    :ok
  rescue
    exception ->
      Logger.warning("AgentCommandStatusHandler: secure execution result coordination failed",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        command_type: map_get_any(data, [:command_type, "command_type"], nil),
        exception: exception.__struct__
      )

      :ok
  catch
    kind, _reason ->
      Logger.warning("AgentCommandStatusHandler: secure execution result coordination threw",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        command_type: map_get_any(data, [:command_type, "command_type"], nil),
        failure_kind: kind
      )

      :ok
  end

  defp safe_dispatch_result_coordination(data, state) do
    callback_coordinator =
      Map.get(state, :callback_result_coordinator, CallbackCommandResultCoordinator)

    secure_coordinator =
      Map.get(
        state,
        :secure_execution_result_coordinator,
        SecureExecutionCommandResultCoordinator
      )

    work = fn ->
      safe_coordinate_callback_result(data, callback_coordinator)
      safe_coordinate_secure_execution_result(data, secure_coordinator)
    end

    dispatcher =
      Map.get(state, :result_coordination_dispatcher, &dispatch_result_coordination/1)

    case dispatcher.(work) do
      :ok -> :ok
      {:ok, _pid} -> :ok
      {:error, reason} -> log_coordination_admission_failure(data, reason)
      other -> log_coordination_admission_failure(data, other)
    end
  rescue
    exception ->
      log_coordination_admission_failure(data, {:exception, exception.__struct__})
  catch
    kind, _reason ->
      log_coordination_admission_failure(data, {:throw, kind})
  end

  defp dispatch_result_coordination(work) when is_function(work, 0) do
    Task.Supervisor.start_child(@result_coordination_supervisor, work,
      shutdown: @result_coordination_shutdown_ms
    )
  end

  defp log_coordination_admission_failure(data, reason) do
    Logger.warning("AgentCommandStatusHandler: result coordination deferred to durable recovery",
      command_id: map_get_any(data, [:command_id, "command_id"], nil),
      command_type: map_get_any(data, [:command_type, "command_type"], nil),
      reason: safe_coordination_admission_reason(reason)
    )

    :ok
  end

  defp safe_coordination_admission_reason(:max_children), do: :max_children
  defp safe_coordination_admission_reason(:noproc), do: :supervisor_unavailable
  defp safe_coordination_admission_reason({:noproc, _reason}), do: :supervisor_unavailable
  defp safe_coordination_admission_reason({:exception, module}) when is_atom(module), do: module
  defp safe_coordination_admission_reason({:throw, kind}) when is_atom(kind), do: kind
  defp safe_coordination_admission_reason(_reason), do: :coordination_admission_failed

  defp safe_call_result_consumer(consumer, data) when is_function(consumer, 1) do
    consumer.(data)
    :ok
  rescue
    exception ->
      Logger.warning("AgentCommandStatusHandler: persisted result consumer failed",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        exception: exception.__struct__
      )

      :ok
  catch
    kind, _reason ->
      Logger.warning("AgentCommandStatusHandler: persisted result consumer threw",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        failure_kind: kind
      )

      :ok
  end

  defp safe_call_result_consumer(_consumer, _data), do: :ok

  defp default_ack_consumer(actor) do
    fn data -> AgentReleaseManager.handle_command_ack(data, actor: actor) end
  end

  defp default_progress_consumers(actor) do
    [
      &safe_maybe_ingest_mtr_result/1,
      &AdhocScanResultHandler.handle_command_progress/1,
      fn data -> AgentReleaseManager.handle_command_progress(data, actor: actor) end
    ]
  end

  defp safe_call_update_consumer(consumer, data, kind) when is_function(consumer, 1) do
    consumer.(data)
    :ok
  rescue
    exception ->
      Logger.warning("AgentCommandStatusHandler: persisted update consumer failed",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        update_kind: kind,
        exception: exception.__struct__
      )

      :ok
  catch
    failure_kind, _reason ->
      Logger.warning("AgentCommandStatusHandler: persisted update consumer threw",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        update_kind: kind,
        failure_kind: failure_kind
      )

      :ok
  end

  defp safe_call_update_consumer(_consumer, _data, _kind), do: :ok

  defp safe_broadcast_persisted_update(data, broadcaster, kind)
       when is_function(broadcaster, 1) do
    broadcaster.(data)
    :ok
  rescue
    exception ->
      Logger.warning("AgentCommandStatusHandler: persisted update broadcast failed",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        update_kind: kind,
        exception: exception.__struct__
      )

      :ok
  catch
    failure_kind, _reason ->
      Logger.warning("AgentCommandStatusHandler: persisted update broadcast threw",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        update_kind: kind,
        failure_kind: failure_kind
      )

      :ok
  end

  defp safe_broadcast_persisted_update(_data, _broadcaster, _kind), do: :ok

  defp safe_broadcast_persisted_result(data, broadcaster) when is_function(broadcaster, 1) do
    broadcaster.(data)
    :ok
  rescue
    exception ->
      Logger.warning("AgentCommandStatusHandler: persisted result broadcast failed",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        exception: exception.__struct__
      )

      :ok
  catch
    kind, _reason ->
      Logger.warning("AgentCommandStatusHandler: persisted result broadcast threw",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        failure_kind: kind
      )

      :ok
  end

  defp safe_broadcast_persisted_result(_data, _broadcaster), do: :ok

  defp persist_result_with(data, state) do
    persister = Map.get(state, :result_persister, &persist_result/2)

    if is_function(persister, 2),
      do: persister.(data, Map.get(state, :actor)),
      else: {:error, :command_result_persister_unavailable}
  rescue
    exception ->
      Logger.warning("AgentCommandStatusHandler: command result persistence raised",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        exception: exception.__struct__
      )

      {:error, :command_result_persistence_failed}
  catch
    kind, _reason ->
      Logger.warning("AgentCommandStatusHandler: command result persistence threw",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        failure_kind: kind
      )

      {:error, :command_result_persistence_failed}
  end

  defp persist_update_with(data, state, persister_key, default_persister, kind) do
    persister = Map.get(state, persister_key, default_persister)

    if is_function(persister, 2),
      do: persister.(data, Map.get(state, :actor)),
      else: {:error, :command_update_persister_unavailable}
  rescue
    exception ->
      Logger.warning("AgentCommandStatusHandler: command update persistence raised",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        update_kind: kind,
        exception: exception.__struct__
      )

      {:error, :command_update_persistence_failed}
  catch
    failure_kind, _reason ->
      Logger.warning("AgentCommandStatusHandler: command update persistence threw",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        update_kind: kind,
        failure_kind: failure_kind
      )

      {:error, :command_update_persistence_failed}
  end

  defp persist_ack(%{command_id: command_id} = data, _actor) do
    command_id_text = normalize_command_id(command_id)
    authenticated_agent_id = map_get_any(data, [:agent_id, "agent_id"], nil)
    authenticated_partition_id = map_get_any(data, [:partition_id, "partition_id"], nil)
    reported_command_type = map_get_any(data, [:command_type, "command_type"], nil)

    if command_id_text && is_binary(authenticated_agent_id) && authenticated_agent_id != "" &&
         is_binary(authenticated_partition_id) && authenticated_partition_id != "" &&
         is_binary(reported_command_type) && reported_command_type != "" do
      control_query_exact(
        """
        UPDATE platform.agent_commands
        SET
          status = 'acknowledged',
          acknowledged_at = COALESCE(acknowledged_at, now() AT TIME ZONE 'utc'),
          message = $2,
          updated_at = now() AT TIME ZONE 'utc'
        WHERE command_id = $1::text::uuid
          AND agent_id = $3
          AND command_type = $4
          AND partition_id = $5
          AND status IN ('queued', 'sent', 'acknowledged')
        RETURNING command_id
        """,
        [
          command_id_text,
          Map.get(data, :message),
          authenticated_agent_id,
          reported_command_type,
          authenticated_partition_id
        ],
        "acknowledge command",
        command_id_text
      )
    else
      {:error, :command_ack_provenance_required}
    end
  end

  defp persist_progress(%{command_id: command_id} = data, _actor) do
    command_id_text = normalize_command_id(command_id)
    authenticated_agent_id = map_get_any(data, [:agent_id, "agent_id"], nil)
    authenticated_partition_id = map_get_any(data, [:partition_id, "partition_id"], nil)
    reported_command_type = map_get_any(data, [:command_type, "command_type"], nil)

    if command_id_text && is_binary(authenticated_agent_id) && authenticated_agent_id != "" &&
         is_binary(authenticated_partition_id) && authenticated_partition_id != "" &&
         is_binary(reported_command_type) && reported_command_type != "" do
      control_query_exact(
        """
        UPDATE platform.agent_commands
        SET
          status = CASE
            WHEN status IN ('queued', 'sent', 'acknowledged') THEN 'running'
            ELSE status
          END,
          started_at = CASE
            WHEN status IN ('queued', 'sent', 'acknowledged')
              THEN COALESCE(started_at, now() AT TIME ZONE 'utc')
            ELSE started_at
          END,
          last_progress_at = now() AT TIME ZONE 'utc',
          message = $2,
          progress_percent = $3,
          progress_payload = $4::jsonb,
          updated_at = now() AT TIME ZONE 'utc'
        WHERE command_id = $1::text::uuid
          AND agent_id = $5
          AND command_type = $6
          AND partition_id = $7
          AND status IN ('queued', 'sent', 'acknowledged', 'running')
        RETURNING command_id
        """,
        [
          command_id_text,
          Map.get(data, :message),
          Map.get(data, :progress_percent),
          json_param(Map.get(data, :payload)),
          authenticated_agent_id,
          reported_command_type,
          authenticated_partition_id
        ],
        "persist command progress",
        command_id_text
      )
    else
      {:error, :command_progress_provenance_required}
    end
  end

  defp persist_result(data, _actor) when is_map(data) do
    command_id = map_get_any(data, [:command_id, "command_id"], nil)
    command_id_text = normalize_command_id(command_id)
    authenticated_agent_id = map_get_any(data, [:agent_id, "agent_id"], nil)
    authenticated_partition_id = map_get_any(data, [:partition_id, "partition_id"], nil)
    reported_command_type = map_get_any(data, [:command_type, "command_type"], nil)

    if not is_nil(command_id_text) and is_binary(authenticated_agent_id) and
         authenticated_agent_id != "" and
         is_binary(authenticated_partition_id) and authenticated_partition_id != "" and
         is_binary(reported_command_type) and reported_command_type != "" do
      success? = map_get_any(data, [:success, "success"], false) == true
      status = if(success?, do: "completed", else: "failed")
      result_payload = json_param(map_get_any(data, [:payload, "payload"], nil))

      failure_reason =
        if(success?,
          do: nil,
          else: map_get_any(data, [:failure_reason, "failure_reason"], nil) || "command_failed"
        )

      control_query_exact(
        """
        UPDATE platform.agent_commands
        SET
          status = $2,
          completed_at = COALESCE(completed_at, now() AT TIME ZONE 'utc'),
          message = CASE
            WHEN status IN ('completed', 'failed', 'expired', 'canceled', 'offline') THEN message
            ELSE $3
          END,
          result_payload = $4::jsonb,
          failure_reason = $5,
          updated_at = now() AT TIME ZONE 'utc'
        WHERE command_id = $1::text::uuid
          AND agent_id = $6
          AND command_type = $7
          AND partition_id = $8
          AND (
            status NOT IN ('completed', 'failed', 'expired', 'canceled', 'offline')
            OR (
              status = $2
              AND message IS NOT DISTINCT FROM $3
              AND result_payload IS NOT DISTINCT FROM $4::jsonb
              AND failure_reason IS NOT DISTINCT FROM $5
            )
          )
        RETURNING command_id
        """,
        [
          command_id_text,
          status,
          map_get_any(data, [:message, "message"], nil),
          result_payload,
          failure_reason,
          authenticated_agent_id,
          reported_command_type,
          authenticated_partition_id
        ],
        "persist command result",
        command_id_text
      )
    else
      {:error, :command_result_provenance_required}
    end
  end

  defp maybe_ingest_mtr_result(data) when is_map(data) do
    command_type = map_get_any(data, [:command_type, "command_type"], "")
    success = map_get_any(data, [:success, "success"], false)
    payload = map_get_any(data, [:payload, "payload"], nil)

    cond do
      to_string(command_type) == "mtr.run" and success == true ->
        trace = payload_trace(payload)

        if is_map(payload) and is_map(trace),
          do: ingest_mtr_result(data, payload, trace)

      to_string(command_type) == "mtr.bulk_run" and is_map(payload) ->
        ingest_bulk_mtr_progress(payload, data)

      true ->
        :ok
    end
  end

  defp maybe_ingest_mtr_result(_data), do: :ok

  defp safe_maybe_ingest_mtr_result(data) do
    maybe_ingest_mtr_result(data)
  rescue
    exception ->
      Logger.warning(
        "AgentCommandStatusHandler: failed to ingest MTR command update",
        safe_failure_metadata(exception,
          command_id: map_get_any(data, [:command_id, "command_id"], nil),
          command_type: map_get_any(data, [:command_type, "command_type"], nil)
        )
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "AgentCommandStatusHandler: failed to ingest MTR command update",
        safe_failure_metadata({kind, reason},
          command_id: map_get_any(data, [:command_id, "command_id"], nil),
          command_type: map_get_any(data, [:command_type, "command_type"], nil)
        )
      )

      :ok
  end

  defp ingest_mtr_result(data, payload, trace) do
    target = first_target(payload, trace)

    timestamp =
      map_get_any(trace, ["timestamp", :timestamp], nil) ||
        map_get_any(data, [:timestamp, "timestamp"], nil)

    mtr_payload = build_ingest_payload(data, trace, target, timestamp)
    status = build_ingest_status(data)

    case MtrMetricsIngestor.ingest(mtr_payload, status) do
      :ok ->
        _ =
          MtrPubSub.broadcast_ingest(%{
            command_id: Map.get(data, :command_id),
            target: target,
            agent_id: Map.get(data, :agent_id)
          })

        :ok

      {:error, reason} ->
        Logger.warning(
          "AgentCommandStatusHandler: failed to ingest on-demand MTR result",
          safe_failure_metadata(reason, command_id: Map.get(data, :command_id))
        )
    end
  end

  defp first_target(payload, trace) do
    map_get_any(payload, ["target", :target], nil) ||
      map_get_any(trace, ["target", :target, "target_ip", :target_ip], nil) ||
      ""
  end

  defp build_ingest_payload(data, trace, target, timestamp) do
    %{
      "results" => [
        %{
          "check_id" => map_get_any(data, [:command_id, "command_id"], nil),
          "check_name" => "on-demand",
          "target" => target,
          "available" => map_get_any(trace, ["target_reached", :target_reached], false) == true,
          "trace" => trace,
          "timestamp" => timestamp,
          "error" => nil
        }
      ]
    }
  end

  defp build_ingest_status(data) do
    %{
      agent_id: map_get_any(data, [:agent_id, "agent_id"], nil),
      gateway_id:
        map_get_any(data, [:gateway_id, "gateway_id", :gateway_node, "gateway_node"], nil),
      partition: map_get_any(data, [:partition_id, "partition_id"], nil)
    }
  end

  defp payload_trace(payload) when is_map(payload) do
    case map_get_any(payload, ["trace", :trace], nil) do
      trace when is_map(trace) -> trace
      _ -> nil
    end
  end

  defp payload_trace(_payload), do: nil

  defp ingest_bulk_mtr_progress(payload, data) when is_map(payload) do
    updates =
      payload
      |> map_get_any(["target_updates", :target_updates], [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    command_id = map_get_any(data, [:command_id, "command_id"], nil)
    persist_bulk_target_updates(command_id, updates)
    ingest_bulk_target_traces(command_id, data, updates)
  end

  defp ingest_bulk_mtr_progress(_payload, _data), do: :ok

  defp ingest_bulk_target_traces(nil, _data, _updates), do: :ok
  defp ingest_bulk_target_traces(_command_id, _data, []), do: :ok

  defp ingest_bulk_target_traces(command_id, data, updates) when is_list(updates) do
    results =
      updates
      |> Enum.map(&bulk_ingest_result(command_id, data, &1))
      |> Enum.reject(&is_nil/1)

    if results != [] do
      status_payload = build_ingest_status(data)

      case MtrMetricsIngestor.ingest(%{"results" => results}, status_payload) do
        :ok ->
          Enum.each(results, fn result ->
            _ =
              MtrPubSub.broadcast_ingest(%{
                command_id: command_id,
                target: result["target"],
                agent_id: Map.get(data, :agent_id)
              })
          end)

        {:error, reason} ->
          Logger.warning(
            "AgentCommandStatusHandler: failed to ingest bulk MTR results",
            safe_failure_metadata(reason,
              command_id: command_id,
              target_count: length(results)
            )
          )
      end
    end
  end

  defp bulk_ingest_result(command_id, data, update) when is_map(update) do
    trace = map_get_any(update, ["trace", :trace], nil)
    target = map_get_any(update, ["target", :target], "")
    status = normalize_bulk_target_status(map_get_any(update, ["status", :status], "queued"))

    if status == "completed" and is_map(trace) and target != "" do
      timestamp =
        map_get_any(trace, ["timestamp", :timestamp], nil) ||
          map_get_any(data, [:timestamp, "timestamp"], nil)

      %{
        "check_id" => "#{command_id}:#{target}",
        "check_name" => "bulk-mtr",
        "target" => target,
        "available" => map_get_any(trace, ["target_reached", :target_reached], false) == true,
        "trace" => trace,
        "timestamp" => timestamp,
        "error" => nil,
        "device_id" => map_get_any(data, [:command_id, "command_id"], nil)
      }
    end
  end

  defp bulk_ingest_result(_command_id, _data, _update), do: nil

  defp persist_bulk_target_updates(nil, _updates), do: :ok
  defp persist_bulk_target_updates(_command_id, []), do: :ok

  defp persist_bulk_target_updates(command_id, updates) when is_list(updates) do
    command_id_text = normalize_command_id(command_id)

    rows =
      updates
      |> Enum.map(&bulk_target_update_row/1)
      |> Enum.reject(&is_nil/1)

    if rows != [] and not is_nil(command_id_text) do
      case control_repo().query(
             """
             WITH updates AS (
               SELECT
                 $1::text AS command_id,
                 x.target::text AS target,
                 x.status::text AS status,
                 x.error::text AS error,
                 x.result_payload::jsonb AS result_payload,
                 COALESCE(x.attempt_count, 1)::integer AS attempt_count,
                 CASE WHEN x.status = 'running' THEN now() AT TIME ZONE 'utc' END AS started_at,
                 CASE
                   WHEN x.status IN ('completed', 'failed', 'canceled', 'timed_out')
                     THEN now() AT TIME ZONE 'utc'
                 END AS completed_at
               FROM jsonb_to_recordset($2::jsonb) AS x(
                 target text,
                 status text,
                 error text,
                 result_payload jsonb,
                 attempt_count integer
               )
               WHERE x.target IS NOT NULL AND btrim(x.target) <> ''
             )
             INSERT INTO platform.mtr_bulk_job_targets (
               command_id,
               target,
               status,
               error,
               result_payload,
               attempt_count,
               started_at,
               completed_at,
               inserted_at,
               updated_at
             )
             SELECT
               command_id::uuid,
               target,
               status,
               error,
               result_payload,
               attempt_count,
               started_at,
               completed_at,
               now() AT TIME ZONE 'utc',
               now() AT TIME ZONE 'utc'
             FROM updates
             ON CONFLICT (command_id, target)
             DO UPDATE SET
               status = EXCLUDED.status,
               error = EXCLUDED.error,
               result_payload = COALESCE(EXCLUDED.result_payload, platform.mtr_bulk_job_targets.result_payload),
               attempt_count = GREATEST(platform.mtr_bulk_job_targets.attempt_count, EXCLUDED.attempt_count),
               started_at = COALESCE(platform.mtr_bulk_job_targets.started_at, EXCLUDED.started_at),
               completed_at = COALESCE(EXCLUDED.completed_at, platform.mtr_bulk_job_targets.completed_at),
               updated_at = now() AT TIME ZONE 'utc'
             """,
             [command_id_text, rows]
           ) do
        {:ok, _result} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "AgentCommandStatusHandler: failed to persist bulk MTR target updates",
            safe_failure_metadata(reason,
              command_id: command_id,
              target_count: length(rows)
            )
          )
      end
    end
  end

  defp bulk_target_update_row(update) when is_map(update) do
    target =
      update
      |> map_get_any(["target", :target], nil)
      |> to_string_or_nil()

    if is_nil(target) or target == "" do
      nil
    else
      %{
        target: target,
        status: normalize_bulk_target_status(map_get_any(update, ["status", :status], "queued")),
        error: map_get_any(update, ["error", :error], nil),
        result_payload: map_get_any(update, ["result_payload", :result_payload], nil),
        attempt_count: map_get_any(update, ["attempt_count", :attempt_count], 1)
      }
    end
  end

  defp bulk_target_update_row(_update), do: nil

  defp normalize_bulk_target_status(value) do
    value =
      value
      |> to_string()
      |> String.trim()
      |> String.downcase()

    if value in ["queued", "running", "completed", "failed", "canceled", "timed_out"] do
      value
    else
      "queued"
    end
  end

  defp normalize_command_id(nil), do: nil

  defp normalize_command_id(command_id) do
    case Ecto.UUID.cast(command_id) do
      {:ok, uuid} ->
        uuid

      :error ->
        case Ecto.UUID.load(command_id) do
          {:ok, uuid} -> uuid
          :error -> nil
        end
    end
  end

  defp control_query_exact(sql, params, action, command_id) do
    case control_repo().query(sql, params) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        Logger.warning("AgentCommandStatusHandler: refused to #{action}",
          command_id: command_id,
          reason: "missing, terminal-conflicting, or provenance-mismatched command"
        )

        {:error, :command_result_not_persisted}

      {:ok, %{num_rows: count}} ->
        Logger.error("AgentCommandStatusHandler: non-unique #{action}",
          command_id: command_id,
          row_count: count
        )

        {:error, :command_result_non_unique}

      {:error, reason} ->
        log_control_query_failure(action, command_id, reason)

        {:error, reason}
    end
  end

  @doc false
  def log_control_query_failure(action, command_id, reason) when is_binary(action) do
    Logger.warning(
      "AgentCommandStatusHandler: failed to #{action}",
      safe_failure_metadata(reason, command_id: command_id)
    )

    :ok
  end

  defp control_repo do
    if Process.whereis(ControlRepo) do
      ControlRepo
    else
      Repo
    end
  end

  defp safe_failure_metadata(reason, metadata) when is_list(metadata) do
    metadata ++ SafeFailureEvidence.log_metadata(reason)
  end

  defp json_param(nil), do: nil

  defp json_param(value) when is_map(value), do: value

  defp json_param(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, decoded} -> %{"value" => decoded}
      {:error, _reason} -> %{"value" => value}
    end
  end

  defp json_param(value), do: %{"value" => value}

  defp map_get_any(map, keys, default) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, default, fn key ->
      case Map.get(map, key) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp map_get_any(_map, _keys, default), do: default

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)
end
