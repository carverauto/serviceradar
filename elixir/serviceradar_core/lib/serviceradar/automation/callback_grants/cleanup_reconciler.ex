defmodule ServiceRadar.Automation.CallbackGrants.CleanupReconciler do
  @moduledoc """
  Reconciles asynchronous AWX cleanup command results into callback grants.

  Correlation comes only from the locally persisted `AgentCommand.context`.
  Result payloads cannot select a grant, execution, controller, job, or
  credential. Only bounded status atoms and exact identifiers are passed to
  the callback-grant store; response bodies and credential material are never
  logged or persisted by this module.

  A 2xx cancellation response records `cancel_requested`; it is never treated
  as proof that the AWX job reached a terminal state. Only a later exact job
  observation may advance cleanup to `cancel_confirmed`.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.CallbackGrants.AshStore
  alias ServiceRadar.Edge.AgentCommand

  @context_schema "serviceradar.automation_callback_cleanup_command/v1"
  @context_keys MapSet.new([
                  "schema",
                  "grant_id",
                  "execution_id",
                  "controller_id",
                  "dispatch_agent_id",
                  "dispatch_partition_id",
                  "awx_job_id",
                  "credential_id",
                  "cleanup_kind",
                  "cleanup_mode"
                ])
  @delete_payload_keys MapSet.new([
                         "verb",
                         "ok",
                         "credential_id",
                         "credential_type_id",
                         "cleanup_status"
                       ])
  @cancel_payload_keys MapSet.new(["verb", "ok", "job_id", "status"])
  @cleanup_commands ["awx.delete_callback_credential", "awx.cancel_job"]

  @spec handle_command_result(map(), keyword()) :: :ok | {:error, term()}
  def handle_command_result(data, opts \\ [])

  def handle_command_result(data, opts) when is_map(data) and is_list(opts) do
    command_type = value(data, :command_type)

    if command_type in @cleanup_commands do
      with {:ok, command_id} <- uuid(value(data, :command_id)),
           {:ok, command} <- fetch_command(command_id, opts),
           true <-
             same_identifier?(value(command, :id), command_id) ||
               {:error, :cleanup_command_id_mismatch},
           true <-
             value(command, :command_type) == command_type ||
               {:error, :cleanup_command_type_mismatch},
           true <-
             value(data, :agent_id) == value(command, :agent_id) ||
               {:error, :cleanup_result_agent_mismatch},
           true <-
             value(data, :partition_id) == value(command, :partition_id) ||
               {:error, :cleanup_result_partition_mismatch},
           {:ok, context} <- cleanup_context(value(command, :context), command_type),
           true <-
             value(command, :agent_id) == context["dispatch_agent_id"] ||
               {:error, :cleanup_command_agent_mismatch},
           true <-
             value(command, :partition_id) == context["dispatch_partition_id"] ||
               {:error, :cleanup_command_partition_mismatch},
           {:ok, result_status} <- result_status(command_type, data, context),
           attrs = reconciliation_attrs(command_id, context, result_status),
           :ok <- reconcile(context["grant_id"], attrs, opts) do
        :ok
      else
        false -> {:error, :cleanup_command_correlation_mismatch}
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end

  def handle_command_result(_data, _opts), do: {:error, :invalid_cleanup_command_result}

  defp fetch_command(command_id, opts) do
    fetcher = Keyword.get(opts, :fetch_command, &fetch_persisted_command/1)

    if is_function(fetcher, 1),
      do: fetcher.(command_id),
      else: {:error, :cleanup_command_store_unavailable}
  end

  defp fetch_persisted_command(command_id) do
    case AgentCommand.get_by_id(command_id,
           actor: SystemActor.system(:automation_callback_cleanup_reconciler)
         ) do
      {:ok, %AgentCommand{} = command} -> {:ok, command}
      {:ok, nil} -> {:error, :cleanup_command_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile(grant_id, attrs, opts) do
    reconciler =
      Keyword.get(opts, :reconcile, fn id, safe_attrs ->
        AshStore.reconcile_cleanup_result(id, safe_attrs, nil)
      end)

    if is_function(reconciler, 2),
      do: reconciler.(grant_id, attrs),
      else: {:error, :cleanup_grant_store_unavailable}
  end

  defp cleanup_context(context, command_type) when is_map(context) do
    with {:ok, context} <- exact_string_map(context, @context_keys),
         true <-
           context["schema"] == @context_schema || {:error, :cleanup_context_schema_mismatch},
         {:ok, grant_id} <- uuid(context["grant_id"]),
         {:ok, execution_id} <- uuid(context["execution_id"]),
         {:ok, controller_id} <- uuid(context["controller_id"]),
         {:ok, dispatch_agent_id} <- nonempty(context["dispatch_agent_id"]),
         {:ok, dispatch_partition_id} <- nonempty(context["dispatch_partition_id"]),
         {:ok, job_id} <- optional_positive_integer(context["awx_job_id"]),
         {:ok, credential_id} <- optional_positive_integer(context["credential_id"]),
         :ok <- exact_kind(command_type, context["cleanup_kind"], job_id, credential_id),
         :ok <- cleanup_mode(context["cleanup_mode"], context["cleanup_kind"]) do
      {:ok,
       context
       |> Map.put("grant_id", grant_id)
       |> Map.put("execution_id", execution_id)
       |> Map.put("controller_id", controller_id)
       |> Map.put("dispatch_agent_id", dispatch_agent_id)
       |> Map.put("dispatch_partition_id", dispatch_partition_id)
       |> Map.put("awx_job_id", job_id)
       |> Map.put("credential_id", credential_id)}
    else
      false -> {:error, :cleanup_context_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp cleanup_context(_context, _command_type), do: {:error, :cleanup_context_missing}

  defp exact_kind("awx.delete_callback_credential", "credential_delete", _job_id, credential_id)
       when is_integer(credential_id), do: :ok

  defp exact_kind("awx.cancel_job", "job_cancel", job_id, _credential_id) when is_integer(job_id),
    do: :ok

  defp exact_kind(_command_type, _kind, _job_id, _credential_id),
    do: {:error, :cleanup_kind_mismatch}

  defp cleanup_mode(mode, "credential_delete")
       when mode in ["post_activation", "consumed", "revoked", "expired", "job_terminal"], do: :ok

  defp cleanup_mode(mode, "job_cancel") when mode in ["revoked", "expired"], do: :ok
  defp cleanup_mode(_mode, _kind), do: {:error, :cleanup_mode_mismatch}

  defp result_status("awx.delete_callback_credential", data, context) do
    if success?(data) do
      payload = value(data, :payload) || value(data, :result_payload)

      with {:ok, payload} <- exact_string_map(payload, @delete_payload_keys),
           true <- payload["verb"] == "awx.delete_callback_credential",
           true <- payload["ok"] == true,
           true <- payload["credential_id"] == context["credential_id"],
           true <-
             is_integer(payload["credential_type_id"]) and
               payload["credential_type_id"] > 0,
           true <- payload["cleanup_status"] in ["deleted", "already_absent"] do
        {:ok, :deleted}
      else
        _ -> {:ok, :delete_failed}
      end
    else
      {:ok, :delete_failed}
    end
  end

  defp result_status("awx.cancel_job", data, context) do
    if success?(data) do
      payload = value(data, :payload) || value(data, :result_payload)

      with {:ok, payload} <- exact_string_map(payload, @cancel_payload_keys),
           true <- payload["verb"] == "awx.cancel_job",
           true <- payload["ok"] == true,
           true <- payload["job_id"] == context["awx_job_id"],
           status when is_integer(status) and status in 200..299 <- payload["status"] do
        {:ok, :cancel_requested}
      else
        _ -> {:ok, :cancel_failed}
      end
    else
      {:ok, :cancel_failed}
    end
  end

  defp success?(data), do: value(data, :success) == true

  defp reconciliation_attrs(command_id, context, result_status) do
    %{
      command_id: command_id,
      cleanup_kind: context["cleanup_kind"],
      cleanup_mode: context["cleanup_mode"],
      execution_id: context["execution_id"],
      controller_id: context["controller_id"],
      dispatch_agent_id: context["dispatch_agent_id"],
      dispatch_partition_id: context["dispatch_partition_id"],
      awx_job_id: context["awx_job_id"],
      credential_id: context["credential_id"],
      result_status: result_status
    }
  end

  defp exact_string_map(map, expected_keys) when is_map(map) do
    map
    |> Enum.reduce_while({:ok, %{}}, fn {key, item}, {:ok, acc} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      cond do
        not is_binary(key) -> {:halt, {:error, :cleanup_map_key_invalid}}
        not MapSet.member?(expected_keys, key) -> {:halt, {:error, :cleanup_map_field_invalid}}
        Map.has_key?(acc, key) -> {:halt, {:error, :cleanup_map_field_duplicate}}
        true -> {:cont, {:ok, Map.put(acc, key, item)}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        if map_size(normalized) == MapSet.size(expected_keys),
          do: {:ok, normalized},
          else: {:error, :cleanup_map_field_missing}

      {:error, _reason} = error ->
        error
    end
  end

  defp exact_string_map(_map, _expected_keys), do: {:error, :cleanup_map_required}

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_cleanup_uuid}
    end
  end

  defp uuid(_value), do: {:error, :invalid_cleanup_uuid}

  defp optional_positive_integer(nil), do: {:ok, nil}

  defp optional_positive_integer(value)
       when is_integer(value) and value > 0 and value <= 2_147_483_647, do: {:ok, value}

  defp optional_positive_integer(_value), do: {:error, :invalid_cleanup_identifier}

  defp nonempty(value) when is_binary(value) do
    if value != "" and String.trim(value) == value,
      do: {:ok, value},
      else: {:error, :invalid_cleanup_identifier}
  end

  defp nonempty(_value), do: {:error, :invalid_cleanup_identifier}

  defp same_identifier?(left, right), do: to_string(left) == to_string(right)

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_map, _key), do: nil
end
