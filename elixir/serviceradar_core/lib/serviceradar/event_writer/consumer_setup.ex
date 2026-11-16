defmodule ServiceRadar.EventWriter.ConsumerSetup do
  @moduledoc """
  NATS plumbing shared by the two halves of EventWriter consumer setup.

  `ServiceRadar.EventWriter.ConsumerReconciler` runs once per deployment, on the
  coordinator, and creates or reconciles every stream and durable consumer.
  `ServiceRadar.EventWriter.Producer` runs in every core replica and only binds
  to those durables. Both open their own unlinked NATS connection, name a
  configured stream's durable the same way, check that the stream it resolved to
  is the one a flow consumer must use, and describe a failure in the same terms.
  """

  alias ServiceRadar.EventWriter.Config

  @default_connection_timeout_ms 15_000
  @retry_base_ms 5_000
  @retry_max_ms 60_000
  @startup_retry_base_ms 1_000
  @startup_retry_max_ms 5_000

  # JetStream `err_code`s a rolling restart or a stream/consumer leader move returns while the
  # asset has no leader: JSClusterNotAvailErr (10008), JSClusterNotLeaderErr (10009),
  # JSStreamOfflineErr (10118) and JSConsumerOfflineErr (10119). Each clears once a leader is
  # elected.
  @transient_err_codes [10_008, 10_009, 10_118, 10_119]
  # Eight attempts at `retry_delay/1`'s backoff span about four minutes of retries, longer than
  # a rolling restart of a three-node NATS cluster takes.
  @transient_attempt_bound 8

  @doc """
  Opens an unlinked NATS connection and monitors it. The caller handles the
  `:DOWN` message; `close/1` stops the connection.
  """
  @spec open(Config.nats_config()) :: {:ok, pid(), reference()} | {:error, term()}
  def open(nats_config) do
    with {:ok, settings} <- connection_settings(nats_config),
         {:ok, conn} <- Gnat.start_link(settings) do
      Process.unlink(conn)
      {:ok, conn, Process.monitor(conn)}
    end
  end

  @doc """
  Stops a connection opened by `open/1`, or one still linked to the caller.
  Unlinks first so the shutdown never reaches the caller.
  """
  @spec close(pid() | term()) :: :ok
  def close(conn) when is_pid(conn) do
    if Process.alive?(conn) do
      Process.unlink(conn)
      ref = Process.monitor(conn)
      Process.exit(conn, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^conn, _} -> :ok
      after
        1_000 ->
          Process.exit(conn, :kill)

          receive do
            {:DOWN, ^ref, :process, ^conn, _} -> :ok
          after
            200 -> :ok
          end
      end
    end

    :ok
  end

  def close(_conn), do: :ok

  @doc "Backoff before retry `attempt` of a failed stream or connection: 5 s doubling to 60 s."
  @spec retry_delay(pos_integer()) :: pos_integer()
  def retry_delay(attempt) when is_integer(attempt) and attempt >= 1 do
    min(@retry_base_ms * Integer.pow(2, min(attempt - 1, 4)), @retry_max_ms)
  end

  @doc """
  Backoff while waiting for a stream or durable to become ready during startup:
  1 s doubling to 5 s, capped to the remaining startup wait bound.
  """
  @spec startup_retry_delay(pos_integer(), pos_integer()) :: pos_integer()
  def startup_retry_delay(attempt, remaining_ms)
      when is_integer(attempt) and attempt >= 1 and is_integer(remaining_ms) do
    delay =
      min(@startup_retry_base_ms * Integer.pow(2, min(attempt - 1, 3)), @startup_retry_max_ms)

    max(min(delay, remaining_ms), 1)
  end

  @doc """
  Whether `reason` means the stream or durable consumer has not been created or
  reconciled by `ServiceRadar.EventWriter.ConsumerReconciler` yet.
  """
  @spec not_ready_reason?(term()) :: boolean()
  def not_ready_reason?({:stream_not_ready, _stream}), do: true
  def not_ready_reason?({:durable_not_ready, _stream}), do: true
  def not_ready_reason?({:durable_filter_mismatch, _details}), do: true

  def not_ready_reason?({stream_name, reason}) when is_binary(stream_name),
    do: not_ready_reason?(reason)

  def not_ready_reason?(_reason), do: false

  @doc """
  Whether `reason` is a NATS condition that a rolling restart or a JetStream leader move causes
  and that clears by itself: the connection process exited (`{:connection_exit, _}`, such as
  `:noproc` while the server restarts), a JetStream API request timed out, or the server
  reported the cluster without a leader or the stream or consumer offline. A missing stream, a
  denied permission or a mismatched consumer configuration is not transient.
  """
  @spec transient_reason?(term()) :: boolean()
  def transient_reason?({:connection_exit, _reason}), do: true
  def transient_reason?(:timeout), do: true
  def transient_reason?(%{"err_code" => code}) when code in @transient_err_codes, do: true

  def transient_reason?({stream_name, reason}) when is_binary(stream_name),
    do: transient_reason?(reason)

  def transient_reason?(_reason), do: false

  @doc """
  Whether failed attempt `attempt` of a transient reason (`transient_reason?/1`) is still within
  the bound in which it is logged as a warning. Past it, the failure is logged as an error and
  reported (`report_transient_bound_exceeded/3`).
  """
  @spec transient_within_bound?(pos_integer()) :: boolean()
  def transient_within_bound?(attempt) when is_integer(attempt),
    do: attempt <= @transient_attempt_bound

  @doc """
  Emits `[:serviceradar, :event_writer, :consumer_setup, :transient_bound_exceeded]` for a stream
  whose transient setup or bind failure outlasted its bound.
  """
  @spec report_transient_bound_exceeded(String.t(), pos_integer(), term()) :: :ok
  def report_transient_bound_exceeded(stream, attempt, reason) do
    :telemetry.execute(
      [:serviceradar, :event_writer, :consumer_setup, :transient_bound_exceeded],
      %{count: 1, attempt: attempt},
      %{stream: stream, reason: inspect(reason)}
    )
  end

  @doc """
  The durable a configured stream consumes from. A stream may name a
  pre-existing durable in `:durable_source_name`, so JetStream resumes the existing
  ACK cursor instead of creating a new durable.
  """
  @spec durable_name(Config.t(), map()) :: String.t()
  def durable_name(%Config{consumer_name: base}, stream) do
    Config.durable_name(base, Map.get(stream, :durable_source_name) || stream.name)
  end

  @doc """
  Rejects a resolved stream other than the configured one when fallback is not
  allowed. Flow consumers refuse fallback unless they opt in. Any other
  consumer does so when `allow_stream_fallback` is false, so `EDGE_RECORD`
  stays on `TELEMETRY_EDGE_RECORD_V1_BULK` instead of a conflicting owner.
  """
  @spec validate_resolved_stream(map(), String.t()) :: :ok | {:error, term()}
  def validate_resolved_stream(stream, resolved) do
    expected = Config.jetstream_stream_name(stream)

    if resolved != expected and allow_stream_fallback?(stream) == false do
      {:error, {:unexpected_stream, expected: expected, resolved: resolved}}
    else
      :ok
    end
  end

  @doc "Whether JetStream may fall back onto the stream that owns a consumer's subject."
  @spec allow_stream_fallback?(map()) :: boolean()
  def allow_stream_fallback?(stream) do
    Map.get(stream, :allow_stream_fallback, not Config.flows_stream_consumer?(stream))
  end

  @doc """
  A log line and metadata naming a stream whose consumer could not be set up or
  bound.
  """
  @spec describe_failure(Config.t(), map(), term()) :: {String.t(), keyword()}
  def describe_failure(%Config{} = config, stream, reason) do
    name = Map.fetch!(stream, :name)
    stream_name = Config.jetstream_stream_name(stream)
    durable = durable_name(config, stream)
    filter_subject = Map.fetch!(stream, :subject)

    diagnostic =
      "name=#{inspect(name)} durable=#{inspect(durable)} " <>
        "stream=#{inspect(stream_name)} filter_subject=#{inspect(filter_subject)} " <>
        "reason=#{inspect(reason)}"

    {diagnostic,
     [
       consumer: name,
       durable: durable,
       stream: stream_name,
       filter_subject: filter_subject,
       reason: inspect(reason)
     ]}
  end

  defp connection_settings(nats_config) do
    base = %{
      host: nats_config.host,
      port: nats_config.port,
      connection_timeout:
        Map.get(nats_config, :connection_timeout) || @default_connection_timeout_ms
    }

    with {:ok, settings} <- apply_auth_settings(base, nats_config) do
      {:ok, add_tls_settings(settings, nats_config.tls)}
    end
  end

  defp add_tls_settings(settings, true), do: Map.put(settings, :tls, true)

  defp add_tls_settings(settings, tls_opts) when is_list(tls_opts) do
    settings
    |> Map.put(:tls, true)
    |> Map.put(:ssl_opts, tls_opts)
  end

  defp add_tls_settings(settings, _tls), do: settings

  defp apply_auth_settings(settings, nats_config) do
    jwt = normalize(nats_config.jwt)
    nkey_seed = normalize(nats_config.nkey_seed)
    user = normalize(nats_config.user)

    cond do
      nkey_seed != nil ->
        settings =
          settings
          |> Map.put(:nkey_seed, nkey_seed)
          |> Map.put(:auth_required, true)

        {:ok, if(jwt == nil, do: settings, else: Map.put(settings, :jwt, jwt))}

      jwt != nil ->
        {:error, :missing_nkey_seed}

      user != nil ->
        {:ok, Map.merge(settings, %{user: user, password: nats_config.password})}

      true ->
        {:ok, settings}
    end
  end

  defp normalize(nil), do: nil

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(value), do: value
end
