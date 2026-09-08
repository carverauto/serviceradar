defmodule ServiceRadar.Notifications.PluginDeliveryResult do
  @moduledoc """
  Maps a durable agent command receipt onto the notifier SDK's three-state
  result contract.

  The command's outer `completed`/`failed` state says only whether the agent
  considered the invocation successful. Delivery semantics come from the
  versioned `result_payload`: `delivered`, `retryable`, or `failed`.
  """

  alias ServiceRadar.Automation.Northbound.ActionRedaction
  alias ServiceRadar.Notifications.Transport.Result

  @schema "serviceradar.notification_delivery_result.v1"
  @supported_contract_major "1"
  @max_error_bytes 512
  @max_retry_after_seconds 86_400
  @error_class ~r/\A[a-z0-9][a-z0-9_.:-]{0,127}\z/
  @authorization_header ~r/\b(Authorization\s*:\s*)(?:Basic|Bearer)\s+[^\s,}\]]+/iu
  @bearer_value ~r/\b(Bearer)\s+[^\s,}\]]+/iu
  @secret_ref ~r/\b(?:secretref|credentialref):[^\s,}\]]+/iu
  @sensitive_assignment ~r/\b(api[_-]?key|authorization|password|secret|token)\s*[:=]\s*[^\s,}\]]+/iu
  @url_query ~r|(https?://[^\s?]+)\?[^\s,}\]]+|iu

  @spec from_command(map(), String.t()) :: Result.t()
  def from_command(command, delivery_id) when is_map(command) do
    payload =
      normalize_map(Map.get(command, :result_payload) || Map.get(command, "result_payload"))

    with :ok <- validate_schema(payload),
         :ok <- validate_delivery_id(payload, delivery_id),
         :ok <- validate_contract_version(payload) do
      map_status(payload, command)
    else
      {:error, {:sdk_contract_mismatch, version}} ->
        Result.permanent_failure("sdk_contract_mismatch",
          error_message:
            "the notifier SDK contract major is unsupported (received #{inspect(version)})",
          result_summary: %{
            "receipt" => "sdk_contract_mismatch",
            "command_id" => command_id(command),
            "sdk_contract_version" => sanitize_text(version)
          }
        )

      {:error, reason} ->
        invalid_result(command, reason)
    end
  end

  defp map_status(%{"status" => "delivered"} = payload, command) do
    Result.delivered(
      # A command id identifies the host invocation, not the provider-side
      # message/incident. Substituting it here would make a resolve delivery
      # overwrite the firing delivery's Slack ts or PagerDuty incident key.
      external_correlation_id: present_string(payload["external_correlation_id"]),
      result_summary: result_summary(payload, command, "delivered")
    )
  end

  defp map_status(%{"status" => "retryable"} = payload, command) do
    Result.retryable_failure(error_class(payload, "notification_retryable"),
      error_message: error_message(payload, "the notifier requested a retry"),
      retry_after_ms: retry_after_ms(payload),
      result_summary: result_summary(payload, command, "retryable")
    )
  end

  defp map_status(%{"status" => "failed", "error_class" => raw_error_class} = payload, command)
       when is_binary(raw_error_class) and raw_error_class != "" do
    Result.permanent_failure(error_class(payload, "notification_failed"),
      error_message: error_message(payload, "the notifier permanently failed"),
      result_summary: result_summary(payload, command, "failed")
    )
  end

  # Agent-side admission/runtime failures use the notification result schema so
  # they remain correlatable, but do not carry the SDK's error_class. They are
  # transport failures and must spend the bounded retry budget rather than be
  # mistaken for a guest-declared permanent failure.
  defp map_status(%{"status" => "failed"} = payload, command) do
    error = validated_error_class(payload["error"], "agent_command_failed")

    Result.retryable_failure(error,
      error_message: error_message(payload, "the agent could not run the notifier"),
      result_summary: result_summary(payload, command, "agent_failed")
    )
  end

  defp map_status(payload, command) do
    invalid_result(command, "unknown status #{inspect(Map.get(payload, "status"))}")
  end

  defp validate_schema(%{"schema" => @schema}), do: :ok
  defp validate_schema(_payload), do: {:error, "schema mismatch"}

  defp validate_delivery_id(payload, expected) do
    case present_string(Map.get(payload, "delivery_id")) do
      ^expected -> :ok
      nil -> {:error, "missing delivery_id"}
      _other -> {:error, "delivery_id mismatch"}
    end
  end

  # The SDK release is intentionally rolling, so an absent version remains a
  # pre-release compatibility case. Once a guest declares a version, however,
  # accepting a different or malformed major would interpret a contract this
  # host does not understand and could falsely report delivery.
  defp validate_contract_version(payload) do
    case present_string(Map.get(payload, "sdk_contract_version")) do
      nil ->
        :ok

      version ->
        case String.split(version, ".", parts: 2) do
          [@supported_contract_major | _rest] -> :ok
          _other -> {:error, {:sdk_contract_mismatch, version}}
        end
    end
  end

  defp invalid_result(command, reason) do
    Result.retryable_failure("notification_result_invalid",
      error_message: "the agent returned an invalid notification result: #{reason}",
      result_summary: %{
        "receipt" => "notification_result_invalid",
        "command_id" => command_id(command)
      }
    )
  end

  defp result_summary(payload, command, receipt) do
    payload
    |> Map.get("result_summary", %{})
    |> normalize_map()
    |> ActionRedaction.redact()
    |> sanitize_term()
    |> Map.merge(%{
      "receipt" => receipt,
      "command_id" => command_id(command),
      "sdk_contract_version" => present_string(payload["sdk_contract_version"])
    })
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp error_class(payload, default) do
    validated_error_class(Map.get(payload, "error_class"), default)
  end

  defp validated_error_class(value, default) do
    case present_string(value) do
      value when is_binary(value) ->
        if Regex.match?(@error_class, value), do: value, else: default

      _missing ->
        default
    end
  end

  defp error_message(payload, default) do
    payload
    |> Map.get("error_message")
    |> present_string()
    |> Kernel.||(default)
    |> sanitize_text()
    |> truncate_bytes(@max_error_bytes)
  end

  defp retry_after_ms(payload) do
    case Map.get(payload, "retry_after_seconds") do
      seconds when is_integer(seconds) and seconds > 0 ->
        min(seconds, @max_retry_after_seconds) * 1_000

      seconds when is_float(seconds) and seconds > 0 ->
        min(trunc(seconds), @max_retry_after_seconds) * 1_000

      _other ->
        nil
    end
  end

  defp command_id(command) do
    command
    |> Map.get(:id, Map.get(command, "id"))
    |> case do
      nil -> nil
      id -> to_string(id)
    end
  end

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      string -> string
    end
  end

  defp present_string(_value), do: nil

  defp truncate_bytes(value, max) when byte_size(value) <= max, do: value

  defp truncate_bytes(value, max) do
    value
    |> String.codepoints()
    |> Enum.reduce_while("", fn point, acc ->
      if byte_size(acc) + byte_size(point) > max do
        {:halt, acc}
      else
        {:cont, acc <> point}
      end
    end)
  end

  defp normalize_map(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), item} end)
  end

  defp normalize_map(_value), do: %{}

  defp sanitize_term(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, sanitize_term(item)} end)
  end

  defp sanitize_term(value) when is_list(value), do: Enum.map(value, &sanitize_term/1)
  defp sanitize_term(value) when is_binary(value), do: sanitize_text(value)
  defp sanitize_term(value), do: value

  defp sanitize_text(value) when is_binary(value) do
    value
    |> String.replace(@authorization_header, "\\1[REDACTED]")
    |> String.replace(@bearer_value, "\\1 [REDACTED]")
    |> String.replace(@secret_ref, "[REDACTED SECRET REF]")
    |> String.replace(@sensitive_assignment, "\\1=[REDACTED]")
    |> String.replace(@url_query, "\\1?[REDACTED]")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp sanitize_text(value), do: value
end
