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
  start on a converted stream reports `:already_converted`. Anything that
  aborts the cutover unseals the stream, so publishers are never left paused by
  a failed attempt.
  """

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.ConsumerSetup
  alias ServiceRadar.NATS.JetstreamConsumer

  require Logger

  @drain_timeout_ms 300_000

  @type request_fun ::
          (String.t(), binary() -> {:ok, map()} | {:error, term()})

  @typedoc "A sealed stream waiting for its owning durable to drain."
  @type t :: %{
          stream_name: String.t(),
          durable: String.t(),
          sealed: map(),
          stored: non_neg_integer(),
          deadline: integer()
        }

  @doc """
  Starts cutting `stream` over to `WorkQueue` retention by sealing it. Returns
  `{:draining, cutover}` for the caller to `poll/2` (one step per call, so the
  caller stays responsive while the durable drains), `:already_converted` when
  the stream already uses `WorkQueue`, `:no_stream` when there is nothing to
  convert, or `{:error, reason}` with the stream left unsealed.
  """
  @spec start(request_fun(), Config.t(), map(), keyword()) ::
          {:draining, t()} | :already_converted | :no_stream | {:error, term()}
  def start(request, %Config{} = config, stream, opts \\ []) do
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
            seal(request, stream_name, durable, current, stored, timeout)

          retention ->
            {:error, {:unexpected_retention, retention}}
        end
    end
  end

  @doc """
  Checks the drain once. Returns `{:draining, cutover}` while the durable still
  owes records and the deadline has not passed, `:cut_over` once the drained
  stream is deleted (the caller recreates it through the reconcile path), or
  `{:error, reason}` with the stream unsealed.
  """
  @spec poll(request_fun(), t()) :: {:draining, t()} | :cut_over | {:error, term()}
  def poll(request, cutover) do
    with :drained <- check_drained(request, cutover),
         :ok <- JetstreamConsumer.delete_stream(request, cutover.stream_name, nil) do
      Logger.info("Cut over edge-record stream to WorkQueue retention",
        stream: cutover.stream_name,
        durable: cutover.durable
      )

      :cut_over
    else
      :waiting ->
        if System.monotonic_time(:millisecond) >= cutover.deadline do
          abort(request, cutover, {:error, :drain_timeout})
        else
          {:draining, cutover}
        end

      {:error, _reason} = error ->
        abort(request, cutover, error)
    end
  end

  @doc "Abandons a cutover in progress and unseals its stream."
  @spec abort(request_fun(), t(), {:error, term()}) :: {:error, term()}
  def abort(request, cutover, {:error, _reason} = error) do
    unseal(request, cutover.stream_name, cutover.sealed, cutover.stored)
    log_abort(cutover.stream_name, cutover.durable, error)
    error
  end

  defp seal(request, stream_name, durable, current, stored, timeout) do
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
        {:draining,
         %{
           stream_name: stream_name,
           durable: durable,
           sealed: sealed,
           stored: stored,
           deadline: System.monotonic_time(:millisecond) + timeout
         }}

      {:error, _reason} = error ->
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

  defp check_drained(request, %{stream_name: stream_name, durable: durable}) do
    case JetstreamConsumer.consumer_info(request, stream_name, durable, nil) do
      {:ok, %{"num_pending" => 0, "num_ack_pending" => 0}} ->
        :drained

      {:ok, _info} ->
        :waiting

      :absent ->
        # No durable yet: only safe when nothing is stored. Anything stored
        # with no consumer to drain it must wait, never delete.
        case JetstreamConsumer.stream_info(request, stream_name, nil) do
          {:ok, _config, 0} -> :drained
          {:ok, _, _} -> {:error, :drain_waiting_for_consumer}
          :absent -> {:error, :stream_vanished}
          {:error, _reason} -> :waiting
        end

      {:error, _reason} ->
        :waiting
    end
  end
end
