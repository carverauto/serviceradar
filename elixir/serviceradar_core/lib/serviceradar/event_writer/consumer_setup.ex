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

  @retry_base_ms 5_000
  @retry_max_ms 60_000

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
  The durable a configured stream consumes from. Drain streams name the
  pre-cutover stream in `:durable_source_name`, so JetStream resumes the existing
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
    with {:ok, settings} <-
           apply_auth_settings(%{host: nats_config.host, port: nats_config.port}, nats_config) do
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
