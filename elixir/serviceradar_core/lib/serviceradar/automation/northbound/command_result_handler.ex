defmodule ServiceRadar.Automation.Northbound.CommandResultHandler do
  @moduledoc """
  Applies agent command results for northbound Wasm action invocations.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Northbound.ActionInvocation
  alias ServiceRadar.Automation.Northbound.ActionInvocationTarget
  alias ServiceRadar.Automation.Northbound.PollWorker
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Edge.Crypto

  require Logger

  @command_type "plugin.run_action"
  @terminal_target_statuses [:succeeded, :failed, :skipped, :suppressed, :expired, :canceled]
  @default_signature_header "x-serviceradar-callback-signature"
  @default_timestamp_header "x-serviceradar-callback-timestamp"
  @default_timestamp_tolerance_seconds 300

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

  @spec handle_callback_result(String.t(), map(), keyword()) ::
          {:ok, :accepted | :already_terminal} | {:error, term()}
  def handle_callback_result(job_id, payload, opts \\ [])

  def handle_callback_result(job_id, %{} = payload, opts)
      when is_binary(job_id) and job_id != "" do
    actor = Keyword.get(opts, :actor, SystemActor.system(:northbound_callback_result_handler))
    token = Keyword.get(opts, :token)

    with {:ok, target} <- get_target(job_id, actor),
         :ok <- authorize_callback(target, token, opts),
         {:ok, invocation} <- get_invocation(target.invocation_id, actor) do
      if terminal_target?(target) do
        {:ok, :already_terminal}
      else
        record_callback_result(invocation, target, payload, actor)
      end
    end
  end

  def handle_callback_result(_job_id, _payload, _opts), do: {:error, :invalid_callback_payload}

  defp apply_result(data, actor) do
    with {:ok, context} <- command_context(map_get(data, :command_id, nil), actor),
         {:ok, invocation_id} <- context_invocation_id(context),
         {:ok, invocation} <- get_invocation(invocation_id, actor) do
      payload = normalize_payload(map_get(data, :payload, %{}))
      status = result_status(payload)

      success? =
        status == :succeeded or
          (map_get(data, :success, false) == true and status not in [:failed, :expired])

      terminal_status = terminal_status(status, success?)

      if status in [:deferred, :polling, :result_fetching] do
        record_deferred_results(invocation, payload, status, actor)
        record_invocation_deferred(invocation, data, payload, status, actor)
      else
        record_target_results(invocation, payload, terminal_status, actor)
        record_invocation_result(invocation, data, payload, terminal_status, actor)
      end

      consume_command_credential_grants(context, actor)
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

  defp consume_command_credential_grants(context, actor) do
    context
    |> map_get(:credential_broker_grant_ids, [])
    |> List.wrap()
    |> Enum.each(&consume_command_credential_grant(&1, actor))
  end

  defp consume_command_credential_grant(grant_id, actor)
       when is_binary(grant_id) and grant_id != "" do
    case CredentialBrokerGrant.get_by_id(grant_id, actor: actor) do
      {:ok, %CredentialBrokerGrant{status: status} = grant} when status in [:issued, :active] ->
        _ = CredentialBrokerGrant.consume(grant, actor: actor)
        :ok

      _ ->
        :ok
    end
  rescue
    exception ->
      Logger.warning("Failed to consume northbound credential broker grant",
        grant_id: grant_id,
        reason: Exception.message(exception)
      )

      :ok
  end

  defp consume_command_credential_grant(_grant_id, _actor), do: :ok

  defp get_invocation(id, actor) do
    case ActionInvocation.get_by_id(id, actor: actor) do
      {:ok, nil} -> {:error, :invocation_not_found}
      {:ok, invocation} -> {:ok, invocation}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :invocation_not_found}
    end
  end

  defp get_target(id, actor) do
    case ActionInvocationTarget.get_by_id(id, actor: actor) do
      {:ok, nil} -> {:error, :target_not_found}
      {:ok, target} -> {:ok, target}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :target_not_found}
    end
  end

  defp authorize_callback(_target, token, _opts) when not is_binary(token) or token == "",
    do: {:error, :invalid_callback_token}

  defp authorize_callback(%{callback_token_hash: hash} = target, token, opts)
       when is_binary(hash) and hash != "" do
    token_hash = sha256_hex(token)

    if byte_size(hash) == byte_size(token_hash) and Plug.Crypto.secure_compare(hash, token_hash) do
      authorize_callback_signature(target, opts)
    else
      {:error, :invalid_callback_token}
    end
  end

  defp authorize_callback(_target, _token, _opts), do: {:error, :callback_not_configured}

  defp authorize_callback_signature(%{callback_auth_mode: mode}, _opts)
       when mode in [nil, :token], do: :ok

  defp authorize_callback_signature(%{callback_auth_mode: :hmac_optional} = target, opts) do
    if callback_signature_present?(target, opts) do
      verify_callback_hmac(target, opts)
    else
      :ok
    end
  end

  defp authorize_callback_signature(%{callback_auth_mode: :hmac_required} = target, opts) do
    if callback_signature_present?(target, opts) do
      verify_callback_hmac(target, opts)
    else
      {:error, :missing_callback_signature}
    end
  end

  defp authorize_callback_signature(_target, _opts), do: :ok

  defp callback_signature_present?(target, opts) do
    signature_value(target, opts) not in [nil, ""] or
      timestamp_value(target, opts) not in [nil, ""]
  end

  defp verify_callback_hmac(target, opts) do
    with {:ok, secret} <- callback_hmac_secret(target),
         {:ok, timestamp} <- callback_timestamp(target, opts),
         :ok <- verify_callback_timestamp(target, timestamp, opts),
         {:ok, signature} <- callback_signature(target, opts) do
      compare_callback_signature(secret, timestamp.raw, raw_body(opts), signature)
    end
  end

  defp callback_hmac_secret(%{callback_hmac_secret_ciphertext: ciphertext})
       when is_binary(ciphertext) and ciphertext != "" do
    case Crypto.decrypt_safe(ciphertext) do
      {:ok, secret} when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :callback_not_configured}
    end
  end

  defp callback_hmac_secret(_target), do: {:error, :callback_not_configured}

  defp callback_timestamp(target, opts) do
    case timestamp_value(target, opts) do
      value when is_binary(value) and value != "" ->
        parse_callback_timestamp(value)

      _ ->
        {:error, :missing_callback_timestamp}
    end
  end

  defp parse_callback_timestamp(value) when is_binary(value) do
    trimmed = String.trim(value)

    if match?({_integer, ""}, Integer.parse(trimmed)) do
      {seconds, ""} = Integer.parse(trimmed)
      {:ok, datetime} = DateTime.from_unix(seconds)
      {:ok, %{raw: trimmed, datetime: datetime}}
    else
      case DateTime.from_iso8601(trimmed) do
        {:ok, datetime, _offset} -> {:ok, %{raw: trimmed, datetime: datetime}}
        _ -> {:error, :invalid_callback_timestamp}
      end
    end
  rescue
    _ -> {:error, :invalid_callback_timestamp}
  end

  defp verify_callback_timestamp(target, %{datetime: timestamp}, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    tolerance =
      target.callback_hmac_timestamp_tolerance_seconds || @default_timestamp_tolerance_seconds

    skew_seconds = abs(DateTime.diff(now, timestamp, :second))

    if skew_seconds <= tolerance do
      :ok
    else
      {:error, :stale_callback_signature}
    end
  end

  defp callback_signature(target, opts) do
    case signature_value(target, opts) do
      value when is_binary(value) and value != "" -> {:ok, normalize_signature(value)}
      _ -> {:error, :missing_callback_signature}
    end
  end

  defp compare_callback_signature(secret, timestamp, raw_body, signature) do
    expected =
      secret
      |> hmac_sha256("#{timestamp}.#{raw_body}")
      |> Base.encode16(case: :lower)

    with "sha256=" <> supplied_hex <- signature,
         true <- byte_size(supplied_hex) == byte_size(expected),
         true <- Plug.Crypto.secure_compare(supplied_hex, expected) do
      :ok
    else
      _ -> {:error, :invalid_callback_signature}
    end
  end

  defp hmac_sha256(secret, message), do: :crypto.mac(:hmac, :sha256, secret, message)

  defp normalize_signature(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp signature_value(target, opts), do: header_value(opts, signature_header(target))
  defp timestamp_value(target, opts), do: header_value(opts, timestamp_header(target))

  defp signature_header(%{callback_hmac_signature_header: header})
       when is_binary(header) and header != "", do: header

  defp signature_header(_target), do: @default_signature_header

  defp timestamp_header(%{callback_hmac_timestamp_header: header})
       when is_binary(header) and header != "", do: header

  defp timestamp_header(_target), do: @default_timestamp_header

  defp header_value(opts, header) do
    headers = Keyword.get(opts, :headers, %{})
    normalized = String.downcase(header)

    cond do
      is_map(headers) ->
        Map.get(headers, normalized) || Map.get(headers, header)

      is_list(headers) ->
        Enum.find_value(headers, fn
          {key, value} when is_binary(key) ->
            if String.downcase(key) == normalized, do: value

          _ ->
            nil
        end)

      true ->
        nil
    end
  end

  defp raw_body(opts) do
    case Keyword.get(opts, :raw_body, "") do
      body when is_binary(body) -> body
      body when is_list(body) -> IO.iodata_to_binary(body)
      _ -> ""
    end
  end

  defp record_callback_result(invocation, target, payload, actor) do
    payload = normalize_payload(payload)
    result_payload = callback_result_payload(target, payload)
    status = result_status(result_payload)

    success? =
      status == :succeeded or
        (map_get(payload, :success, false) == true and status not in [:failed, :expired])

    if status in [:deferred, :polling, :result_fetching] do
      next_poll_at = next_poll_at(result_payload, payload)

      attrs =
        target
        |> deferred_attrs(result_payload, payload, next_poll_at)
        |> Map.put(:callback_received_at, DateTime.utc_now())

      updated =
        case status do
          :result_fetching ->
            ActionInvocationTarget.record_result_fetching(target, attrs, actor: actor)

          _ ->
            ActionInvocationTarget.record_polling(target, attrs, actor: actor)
        end

      case updated do
        {:ok, updated_target} -> _ = PollWorker.schedule_target(updated_target, next_poll_at)
        _ -> :ok
      end
    else
      terminal_status = terminal_status(status, success?)

      attrs =
        result_payload
        |> target_result_attrs(payload)
        |> Map.put(:callback_received_at, DateTime.utc_now())

      _ = record_terminal_target_result(target, terminal_status, attrs, actor)
    end

    refresh_invocation_after_callback(invocation, payload, status, actor)
  end

  defp record_invocation_result(invocation, data, payload, :succeeded, actor) do
    ActionInvocation.record_succeeded(
      invocation,
      %{
        result_summary: result_summary(data, payload),
        external_correlation_id: external_correlation_id(payload)
      },
      actor: actor
    )
  end

  defp record_invocation_result(invocation, data, payload, :expired, actor) do
    ActionInvocation.record_expired(
      invocation,
      %{
        result_summary: result_summary(data, payload),
        external_correlation_id: external_correlation_id(payload),
        error_class: to_string(map_get(payload, :error_class, "provider_timeout")),
        error_message: error_message(data, payload)
      },
      actor: actor
    )
  end

  defp record_invocation_result(invocation, data, payload, _status, actor) do
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

  defp record_invocation_deferred(invocation, data, payload, :result_fetching, actor) do
    ActionInvocation.record_result_fetching(
      invocation,
      %{
        result_summary: result_summary(data, payload),
        external_correlation_id: external_correlation_id(payload)
      },
      actor: actor
    )
  end

  defp record_invocation_deferred(invocation, data, payload, _status, actor) do
    ActionInvocation.record_polling(
      invocation,
      %{
        result_summary: result_summary(data, payload),
        external_correlation_id: external_correlation_id(payload)
      },
      actor: actor
    )
  end

  defp record_deferred_results(invocation, payload, fallback_status, actor) do
    targets = list_targets(invocation.id, actor)
    target_payloads = payload |> map_get(:targets, []) |> List.wrap()

    Enum.each(targets, fn target ->
      case target_payload_for(target, target_payloads, payload) do
        nil ->
          :ok

        result_payload ->
          status =
            normalize_status(map_get(result_payload, :status, fallback_status), fallback_status)

          next_poll_at = next_poll_at(result_payload, payload)
          attrs = deferred_attrs(target, result_payload, payload, next_poll_at)

          updated =
            case status do
              :result_fetching ->
                ActionInvocationTarget.record_result_fetching(target, attrs, actor: actor)

              _ ->
                ActionInvocationTarget.record_deferred(target, attrs, actor: actor)
            end

          case updated do
            {:ok, updated_target} -> _ = PollWorker.schedule_target(updated_target, next_poll_at)
            _ -> :ok
          end
      end
    end)
  end

  defp record_target_results(invocation, payload, fallback_status, actor) do
    targets = list_targets(invocation.id, actor)
    target_payloads = payload |> map_get(:targets, []) |> List.wrap()

    Enum.each(targets, fn target ->
      case target_payload_for(target, target_payloads, payload) do
        nil ->
          :ok

        result_payload ->
          status =
            normalize_status(map_get(result_payload, :status, fallback_status), fallback_status)

          _ =
            record_terminal_target_result(
              target,
              status,
              target_result_attrs(result_payload, payload),
              actor
            )
      end
    end)
  end

  defp target_result_attrs(result_payload, payload) do
    %{
      result: normalize_target_result(result_payload, payload),
      external_correlation_id:
        external_correlation_id(result_payload) || external_correlation_id(payload)
    }
  end

  defp record_terminal_target_result(target, :succeeded, attrs, actor),
    do: ActionInvocationTarget.record_succeeded(target, attrs, actor: actor)

  defp record_terminal_target_result(target, :skipped, attrs, actor),
    do: ActionInvocationTarget.record_skipped(target, attrs, actor: actor)

  defp record_terminal_target_result(target, :suppressed, attrs, actor),
    do: ActionInvocationTarget.record_suppressed(target, attrs, actor: actor)

  defp record_terminal_target_result(target, :expired, attrs, actor),
    do: ActionInvocationTarget.record_expired(target, attrs, actor: actor)

  defp record_terminal_target_result(target, :canceled, attrs, actor),
    do: ActionInvocationTarget.record_canceled(target, attrs, actor: actor)

  defp record_terminal_target_result(target, _status, attrs, actor),
    do: ActionInvocationTarget.record_failed(target, attrs, actor: actor)

  defp list_targets(invocation_id, actor) do
    case ActionInvocationTarget.list_for_invocation(invocation_id, actor: actor) do
      {:ok, targets} -> targets
      _ -> []
    end
  end

  defp matching_target_payload(target, payloads) do
    Enum.find(payloads, fn payload ->
      is_map(payload) and target_payload_matches?(target, payload)
    end)
  end

  defp target_payload_matches?(target, payload) do
    case map_get(payload, :northbound_job_id, nil) || map_get(payload, :job_id, nil) do
      nil ->
        target_value_matches?(target.device_uid, map_get(payload, :device_uid, nil)) and
          target_value_matches?(target.interface_uid, map_get(payload, :interface_uid, nil))

      "" ->
        target_value_matches?(target.device_uid, map_get(payload, :device_uid, nil)) and
          target_value_matches?(target.interface_uid, map_get(payload, :interface_uid, nil))

      job_id ->
        target_value_matches?(target.id, job_id)
    end
  end

  defp target_payload_for(_target, [], fallback), do: fallback

  defp target_payload_for(target, payloads, _fallback),
    do: matching_target_payload(target, payloads)

  defp callback_result_payload(target, payload) do
    target_payloads = payload |> map_get(:targets, []) |> List.wrap()

    case target_payload_for(target, target_payloads, payload) do
      nil -> payload
      result_payload -> result_payload
    end
  end

  defp refresh_invocation_after_callback(invocation, payload, callback_status, actor) do
    targets = list_targets(invocation.id, actor)
    summary_data = %{"success" => aggregate_status(targets) == :succeeded}

    cond do
      targets != [] and Enum.all?(targets, &terminal_target?/1) ->
        attrs = %{
          result_summary: result_summary(summary_data, payload),
          external_correlation_id: external_correlation_id(payload)
        }

        case aggregate_status(targets) do
          :succeeded ->
            _ = ActionInvocation.record_succeeded(invocation, attrs, actor: actor)

          :expired ->
            _ =
              ActionInvocation.record_expired(
                invocation,
                Map.merge(attrs, %{
                  error_class: "provider_timeout",
                  error_message: error_message(%{}, payload)
                }),
                actor: actor
              )

          :canceled ->
            _ = ActionInvocation.record_canceled(invocation, attrs, actor: actor)

          _ ->
            _ =
              ActionInvocation.record_failed(
                invocation,
                Map.merge(attrs, %{
                  error_class: "provider_failed",
                  error_message: error_message(%{}, payload)
                }),
                actor: actor
              )
        end

        {:ok, :accepted}

      callback_status == :result_fetching ->
        _ =
          ActionInvocation.record_result_fetching(
            invocation,
            %{
              result_summary: result_summary(%{"success" => true}, payload),
              external_correlation_id: external_correlation_id(payload)
            },
            actor: actor
          )

        {:ok, :accepted}

      true ->
        _ =
          ActionInvocation.record_polling(
            invocation,
            %{
              result_summary: result_summary(%{"success" => true}, payload),
              external_correlation_id: external_correlation_id(payload)
            },
            actor: actor
          )

        {:ok, :accepted}
    end
  end

  defp terminal_target?(%{status: status}), do: status in @terminal_target_statuses

  defp aggregate_status(targets) do
    statuses = Enum.map(targets, & &1.status)

    cond do
      Enum.any?(statuses, &(&1 == :failed)) -> :failed
      Enum.any?(statuses, &(&1 == :expired)) -> :expired
      Enum.any?(statuses, &(&1 == :canceled)) -> :canceled
      true -> :succeeded
    end
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

  defp terminal_status(status, _success?)
       when status in [:succeeded, :failed, :skipped, :suppressed, :expired, :canceled],
       do: status

  defp terminal_status(_status, true), do: :succeeded
  defp terminal_status(_status, false), do: :failed

  defp normalize_status(status, _fallback)
       when status in [
              :succeeded,
              :failed,
              :skipped,
              :suppressed,
              :deferred,
              :polling,
              :result_fetching,
              :expired,
              :canceled
            ],
       do: status

  defp normalize_status(status, fallback) when is_binary(status) do
    case status |> String.trim() |> String.downcase() do
      "succeeded" -> :succeeded
      "success" -> :succeeded
      "completed" -> :succeeded
      "failed" -> :failed
      "failure" -> :failed
      "error" -> :failed
      "deferred" -> :deferred
      "accepted" -> :deferred
      "pending_external" -> :deferred
      "polling" -> :polling
      "running" -> :polling
      "result_fetching" -> :result_fetching
      "fetching_results" -> :result_fetching
      "expired" -> :expired
      "timeout" -> :expired
      "canceled" -> :canceled
      "cancelled" -> :canceled
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

  defp deferred_attrs(target, result_payload, payload, next_poll_at) do
    %{
      result: normalize_target_result(result_payload, payload),
      external_correlation_id:
        external_correlation_id(result_payload) || external_correlation_id(payload),
      continuation_state:
        continuation_state(result_payload) || continuation_state(payload) ||
          target.continuation_state || %{},
      next_poll_at: next_poll_at,
      poll_deadline_at:
        poll_deadline_at(result_payload) || poll_deadline_at(payload) || target.poll_deadline_at,
      last_poll_at: DateTime.utc_now(),
      poll_attempt_count: target.poll_attempt_count || 0
    }
  end

  defp continuation_state(payload) when is_map(payload) do
    case map_get(payload, :continuation_state, nil) || map_get(payload, :continuation, nil) do
      %{} = state -> state
      _ -> nil
    end
  end

  defp continuation_state(_payload), do: nil

  defp next_poll_at(payload) when is_map(payload) do
    cond do
      match?(%DateTime{}, map_get(payload, :next_poll_at, nil)) ->
        dt = map_get(payload, :next_poll_at, nil)
        dt

      is_binary(map_get(payload, :next_poll_at, nil)) ->
        parse_datetime(map_get(payload, :next_poll_at, nil))

      is_integer(map_get(payload, :next_poll_delay_seconds, nil)) ->
        DateTime.add(DateTime.utc_now(), map_get(payload, :next_poll_delay_seconds, nil), :second)

      is_integer(map_get(payload, :poll_after_seconds, nil)) ->
        DateTime.add(DateTime.utc_now(), map_get(payload, :poll_after_seconds, nil), :second)

      true ->
        DateTime.add(DateTime.utc_now(), 30, :second)
    end
  end

  defp next_poll_at(_payload), do: DateTime.add(DateTime.utc_now(), 30, :second)

  defp next_poll_at(result_payload, payload) do
    if webhook_only?(result_payload) or webhook_only?(payload) do
      nil
    else
      next_poll_at(result_payload) || next_poll_at(payload)
    end
  end

  defp webhook_only?(payload) when is_map(payload) do
    poll_mode = payload |> map_get(:poll_mode, "") |> to_string() |> String.downcase()

    poll_mode in ["webhook", "callback", "webhook_only", "callback_only"] or
      truthy?(map_get(payload, :webhook_only, false)) or
      truthy?(map_get(payload, :callback_only, false))
  end

  defp webhook_only?(_payload), do: false

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp poll_deadline_at(payload) when is_map(payload) do
    cond do
      match?(%DateTime{}, map_get(payload, :poll_deadline_at, nil)) ->
        dt = map_get(payload, :poll_deadline_at, nil)
        dt

      is_binary(map_get(payload, :poll_deadline_at, nil)) ->
        parse_datetime(map_get(payload, :poll_deadline_at, nil))

      is_integer(map_get(payload, :max_duration_seconds, nil)) ->
        DateTime.add(DateTime.utc_now(), map_get(payload, :max_duration_seconds, nil), :second)

      true ->
        nil
    end
  end

  defp poll_deadline_at(_payload), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp map_get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_get(_map, _key, default), do: default

  defp sha256_hex(value) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end
end
