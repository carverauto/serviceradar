defmodule ServiceRadar.EventWriter.EdgeRecordStreamCutover do
  @moduledoc """
  Drain-barrier cutover of an edge-record source stream from `Limits` to
  `WorkQueue` retention.

  The broker refuses retention changes to or from `WorkQueue` in place, so an
  existing limits stream cannot be updated: it is sealed (publishes are refused
  with a retryable error and stay in agent spool), drained through its sole
  owning durable, deleted, and recreated by the reconcile path with the
  production shape. No step publishes to two streams (no dual-write), and the
  old stream is deleted only once nothing is owed (no lost records).

  Every step is idempotent, so a retried cutover converges: sealing an already
  sealed stream and deleting an already deleted stream both succeed, and a
  drained check that finds a converted stream reports `:already_converted`.
  Anything that aborts the cutover unseals the stream first, so publishers are
  never left paused by a failed attempt.
  """

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.ConsumerSetup
  alias ServiceRadar.NATS.JetstreamConsumer

  require Logger

  @drain_poll_ms 1_000
  @drain_timeout_ms 300_000

  @type request_fun ::
          (String.t(), binary() -> {:ok, map()} | {:error, term()})

  @doc """
  Cuts `stream` over to `WorkQueue` retention. Returns `:cut_over` once the old
  stream is deleted (the caller recreates it through the reconcile path),
  `:already_converted` when the stream already uses `WorkQueue`, `:no_stream`
  when there is nothing to convert, or `{:error, reason}` with the stream
  unsealed.
  """
  @spec run(request_fun(), Config.t(), map(), keyword()) ::
          :already_converted | :no_stream | :cut_over | {:error, term()}
  def run(request, %Config{} = config, stream, opts \\ []) do
    stream_name = Config.jetstream_stream_name(stream)
    durable = ConsumerSetup.durable_name(config, stream)
    timeout = Keyword.get(opts, :drain_timeout_ms, @drain_timeout_ms)

    case JetstreamConsumer.stream_info(request, stream_name, nil) do
      :absent ->
        :no_stream

      {:error, _reason} = error ->
        error

      {:ok, current, stored} ->
        case Map.get(current, "retention") do
          "workqueue" ->
            :already_converted

          "limits" ->
            seal_drain_delete(request, stream_name, durable, current, stored, timeout)

          retention ->
            {:error, {:unexpected_retention, retention}}
        end
    end
  end

  defp seal_drain_delete(request, stream_name, durable, current, stored, timeout) do
    sealed = Map.put(current, "sealed", true)

    case JetstreamConsumer.update_stream_if_changed(
           request,
           stream_name,
           current,
           sealed,
           stored,
           nil
         ) do
      :ok ->
        drain_delete(request, stream_name, durable, sealed, stored, timeout)

      {:error, _reason} = error ->
        log_abort(stream_name, durable, error)
        error
    end
  end

  defp drain_delete(request, stream_name, durable, sealed, stored, timeout) do
    with :drained <- await_drained(request, stream_name, durable, timeout),
         :ok <- JetstreamConsumer.delete_stream(request, stream_name, nil) do
      Logger.info("Cut over edge-record stream to WorkQueue retention",
        stream: stream_name,
        durable: durable
      )

      :cut_over
    else
      {:error, _reason} = error ->
        unseal(request, stream_name, sealed, stored)
        log_abort(stream_name, durable, error)
        error
    end
  end

  defp log_abort(stream_name, durable, reason) do
    Logger.error("Edge-record stream cutover aborted; stream left in place",
      stream: stream_name,
      durable: durable,
      reason: inspect(reason)
    )
  end

  defp unseal(request, stream_name, sealed_config, stored) do
    unsealed = Map.put(sealed_config, "sealed", false)

    case JetstreamConsumer.update_stream_if_changed(
           request,
           stream_name,
           sealed_config,
           unsealed,
           stored,
           nil
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Edge-record stream cutover could not unseal after abort",
          stream: stream_name,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp await_drained(request, stream_name, durable, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_drained(request, stream_name, durable, deadline)
  end

  defp poll_drained(request, stream_name, durable, deadline) do
    case JetstreamConsumer.consumer_info(request, stream_name, durable, nil) do
      {:ok, %{"num_pending" => 0, "num_ack_pending" => 0}} ->
        :drained

      {:ok, _info} ->
        retry_drained(request, stream_name, durable, deadline)

      :absent ->
        # No durable yet: only safe when nothing is stored. Anything stored
        # with no consumer to drain it must wait, never delete.
        case JetstreamConsumer.stream_info(request, stream_name, nil) do
          {:ok, _config, 0} -> :drained
          {:ok, _, _} -> {:error, :drain_waiting_for_consumer}
          :absent -> {:error, :stream_vanished}
          {:error, _reason} -> retry_drained(request, stream_name, durable, deadline)
        end

      {:error, _reason} ->
        retry_drained(request, stream_name, durable, deadline)
    end
  end

  defp retry_drained(request, stream_name, durable, deadline) do
    if System.monotonic_time(:millisecond) + @drain_poll_ms >= deadline do
      {:error, :drain_timeout}
    else
      Process.sleep(@drain_poll_ms)
      poll_drained(request, stream_name, durable, deadline)
    end
  end
end
