defmodule ServiceRadar.Automation.Northbound.CommandResultHandler do
  @moduledoc """
  Applies agent command results for northbound Wasm action invocations.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Northbound.ActionInvocation
  alias ServiceRadar.Automation.Northbound.ActionInvocationTarget
  alias ServiceRadar.Edge.AgentCommand

  require Logger

  @command_type "plugin.run_action"

  @spec handle_command_result(map(), keyword()) :: :ok
  def handle_command_result(data, opts \\ [])

  def handle_command_result(%{} = data, opts) do
    if to_string(map_get(data, :command_type, "")) == @command_type do
      actor = Keyword.get(opts, :actor, SystemActor.system(:northbound_command_result_handler))
      apply_result(data, actor)
    end

    :ok
  rescue
    exception ->
      Logger.warning(
        "NorthboundCommandResultHandler: failed to apply plugin action result",
        command_id: map_get(data, :command_id, nil),
        reason: Exception.format(:error, exception, __STACKTRACE__)
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "NorthboundCommandResultHandler: failed to apply plugin action result",
        command_id: map_get(data, :command_id, nil),
        reason: Exception.format(kind, reason, __STACKTRACE__)
      )

      :ok
  end

  def handle_command_result(_data, _opts), do: :ok

  defp apply_result(data, actor) do
    with {:ok, context} <- command_context(map_get(data, :command_id, nil), actor),
         {:ok, invocation_id} <- context_invocation_id(context),
         {:ok, invocation} <- get_invocation(invocation_id, actor) do
      payload = normalize_payload(map_get(data, :payload, %{}))
      success? = map_get(data, :success, false) == true and result_status(payload) != :failed

      record_target_results(invocation, payload, success?, actor)
      record_invocation_result(invocation, data, payload, success?, actor)
    else
      {:error, :not_northbound_command} ->
        :ok

      {:error, reason} ->
        Logger.debug("Northbound command result ignored: #{inspect(reason)}")
    end
  end

  defp command_context(nil, _actor), do: {:error, :not_northbound_command}

  defp command_context(command_id, actor) do
    case AgentCommand.get_by_id(to_string(command_id), actor: actor) do
      {:ok, %{context: context}} when is_map(context) -> {:ok, context}
      {:ok, _} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :command_not_found}
    end
  end

  defp context_invocation_id(context) when is_map(context) do
    case map_get(context, :northbound_invocation_id, nil) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :not_northbound_command}
    end
  end

  defp get_invocation(id, actor) do
    case ActionInvocation.get_by_id(id, actor: actor) do
      {:ok, nil} -> {:error, :invocation_not_found}
      {:ok, invocation} -> {:ok, invocation}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :invocation_not_found}
    end
  end

  defp record_invocation_result(invocation, data, payload, true, actor) do
    ActionInvocation.record_succeeded(
      invocation,
      %{
        result_summary: result_summary(data, payload),
        external_correlation_id: external_correlation_id(payload)
      },
      actor: actor
    )
  end

  defp record_invocation_result(invocation, data, payload, false, actor) do
    ActionInvocation.record_failed(
      invocation,
      %{
        result_summary: result_summary(data, payload),
        external_correlation_id: external_correlation_id(payload),
        error_class: to_string(map_get(payload, :error_class, "provider_failed")),
        error_message: error_message(data, payload)
      },
      actor: actor
    )
  end

  defp record_target_results(invocation, payload, success?, actor) do
    targets = list_targets(invocation.id, actor)
    target_payloads = payload |> map_get(:targets, []) |> List.wrap()
    fallback_status = if(success?, do: :succeeded, else: :failed)
    now = DateTime.utc_now()

    Enum.each(targets, fn target ->
      result_payload = matching_target_payload(target, target_payloads) || %{}

      status =
        normalize_status(map_get(result_payload, :status, fallback_status), fallback_status)

      attrs = %{
        status: status,
        completed_at: now,
        result: normalize_target_result(result_payload, payload),
        external_correlation_id:
          external_correlation_id(result_payload) || external_correlation_id(payload)
      }

      _ = ActionInvocationTarget.record_result(target, attrs, actor: actor)
    end)
  end

  defp list_targets(invocation_id, actor) do
    case ActionInvocationTarget.list_for_invocation(invocation_id, actor: actor) do
      {:ok, targets} -> targets
      _ -> []
    end
  end

  defp matching_target_payload(target, payloads) do
    Enum.find(payloads, fn payload ->
      is_map(payload) and
        target_value_matches?(target.device_uid, map_get(payload, :device_uid, nil)) and
        target_value_matches?(target.interface_uid, map_get(payload, :interface_uid, nil))
    end)
  end

  defp target_value_matches?(nil, nil), do: true
  defp target_value_matches?(nil, ""), do: true
  defp target_value_matches?(nil, _value), do: false
  defp target_value_matches?(expected, value), do: to_string(expected) == to_string(value)

  defp result_summary(data, payload) do
    summary =
      cond do
        is_map(map_get(payload, :summary, nil)) -> map_get(payload, :summary, nil)
        is_map(payload) -> Map.drop(payload, ["targets", :targets])
        true -> %{"result" => payload}
      end

    summary
    |> Map.put_new("message", map_get(data, :message, nil))
    |> Map.put_new(
      "status",
      map_get(
        payload,
        :status,
        if(map_get(data, :success, false), do: "succeeded", else: "failed")
      )
    )
  end

  defp normalize_target_result(%{} = result_payload, _payload)
       when map_size(result_payload) > 0 do
    Map.get(result_payload, "result") || Map.get(result_payload, :result) || result_payload
  end

  defp normalize_target_result(_result_payload, payload), do: result_summary(%{}, payload)

  defp result_status(payload), do: normalize_status(map_get(payload, :status, nil), :unknown)

  defp normalize_status(status, _fallback)
       when status in [:succeeded, :failed, :skipped, :suppressed], do: status

  defp normalize_status(status, fallback) when is_binary(status) do
    case status |> String.trim() |> String.downcase() do
      "succeeded" -> :succeeded
      "success" -> :succeeded
      "completed" -> :succeeded
      "failed" -> :failed
      "failure" -> :failed
      "error" -> :failed
      "skipped" -> :skipped
      "suppressed" -> :suppressed
      _ -> fallback
    end
  end

  defp normalize_status(_status, fallback), do: fallback

  defp external_correlation_id(payload) when is_map(payload) do
    case map_get(payload, :external_correlation_id, nil) || map_get(payload, :correlation_id, nil) do
      value when is_binary(value) and value != "" -> value
      value when not is_nil(value) -> to_string(value)
      _ -> nil
    end
  end

  defp external_correlation_id(_payload), do: nil

  defp error_message(data, payload) do
    Enum.find_value(
      [
        map_get(payload, :error_message, nil),
        map_get(payload, :error, nil),
        map_get(data, :failure_reason, nil),
        map_get(data, :message, nil)
      ],
      fn
        value when is_binary(value) and value != "" -> value
        value when not is_nil(value) -> inspect(value)
        _ -> nil
      end
    ) || "Provider action failed"
  end

  defp normalize_payload(payload) when is_map(payload), do: payload
  defp normalize_payload(payload) when is_list(payload), do: %{"targets" => payload}
  defp normalize_payload(payload), do: %{"result" => payload}

  defp map_get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_get(_map, _key, default), do: default
end
