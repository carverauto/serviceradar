defmodule ServiceRadar.Edge.SweepHostGauges do
  @moduledoc """
  Delivers the per-host gauges core derives for each projected leased sweep batch
  (`ServiceRadar.Edge.SweepHostMetrics`) without a window in which they can be lost.

  `ServiceRadar.Edge.Projectors.SweepObservation` records a pending marker
  (`platform.sweep_host_gauge_pending`, one row per batch) in the same ledger transaction
  that projects the batch, so the marker commits or rolls back with the projection. After
  the commit, `publish_committed/3` publishes the gauges under the marker's identity and
  deletes the marker. If the node dies or the publish fails in between, the marker stays,
  and `ServiceRadar.Edge.SweepHostGaugeSweeper` republishes every marker older than the
  grace period through `republish_stale/1`, a bounded number per pass.

  The marker holds the batch itself, compressed, because the gauges must be rebuilt exactly:
  the same messages under the same `Nats-Msg-Id`s and the same points under the same storage
  keys. A republish of a batch whose first publish did reach JetStream is therefore
  deduplicated by the stream within its window, and stored once after it by the metrics
  store's `(timestamp, gateway_id, series_key)` key. A message JetStream cannot take is
  handed to `ServiceRadar.NATS.DurablePublish`'s retry job, which then owns it, so the
  marker is deleted once every message is stored or queued.
  """

  alias ServiceRadar.Edge.SweepHostMetrics
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.SweepObservationBatchV1
  alias ServiceRadar.Repo

  require Logger

  @grace_seconds 120
  @batch_limit 50

  @insert_marker """
  INSERT INTO platform.sweep_host_gauge_pending (event_id, agent_id, gateway_id, partition, batch)
  VALUES ($1::uuid, $2, $3, $4, $5)
  ON CONFLICT (event_id) DO NOTHING
  """

  @marker_identity """
  SELECT agent_id, gateway_id, partition
  FROM platform.sweep_host_gauge_pending
  WHERE event_id = $1::uuid
  """

  @delete_marker "DELETE FROM platform.sweep_host_gauge_pending WHERE event_id = $1::uuid"

  @stale_markers """
  SELECT event_id::text, agent_id, gateway_id, partition, batch
  FROM platform.sweep_host_gauge_pending
  WHERE inserted_at < clock_timestamp() - $1::integer * interval '1 second'
  ORDER BY inserted_at
  LIMIT $2
  """

  @doc "Seconds a marker may wait for its committed publish before the sweeper takes it."
  @spec grace_seconds() :: pos_integer()
  def grace_seconds, do: @grace_seconds

  @doc "The most markers one sweeper pass republishes."
  @spec batch_limit() :: pos_integer()
  def batch_limit, do: @batch_limit

  @doc """
  Records the pending marker of a projected batch in the caller's ledger transaction.
  `partition` is the slug the projection resolved; `gateway_id` is the publishing gateway.
  """
  @spec mark(
          module(),
          EdgeRecordV1.t(),
          SweepObservationBatchV1.t(),
          String.t() | nil,
          String.t() | nil
        ) ::
          :ok
  def mark(
        repo,
        %EdgeRecordV1{} = record,
        %SweepObservationBatchV1{} = batch,
        partition,
        gateway_id
      ) do
    repo.query!(@insert_marker, [
      record.event_id,
      record.producer_context.origin_principal_id,
      gateway_id,
      partition,
      batch |> SweepObservationBatchV1.encode() |> :zlib.compress()
    ])

    :ok
  end

  @doc """
  Publishes the gauges of a batch whose projection just committed and deletes its marker,
  under the identity the marker recorded. Without a marker the batch has already been
  published and cleared, so nothing is published. A marker read or publish that fails
  leaves the marker for the sweeper.
  """
  @spec publish_committed(EdgeRecordV1.t(), SweepObservationBatchV1.t(), keyword()) ::
          :ok | {:error, term()}
  def publish_committed(%EdgeRecordV1{} = record, %SweepObservationBatchV1{} = batch, opts \\ []) do
    event_id = Ecto.UUID.load!(record.event_id)

    case marker_identity(event_id) do
      {:ok, nil} -> :ok
      {:ok, identity} -> publish_and_clear(identity, batch, opts)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Republishes up to `:limit` (default `batch_limit/0`) markers older than `:grace_seconds`
  (default `grace_seconds/0`), oldest first, and returns how many it cleared. A marker
  whose publish fails again stays for the next pass. The publish options of
  `ServiceRadar.Edge.SweepHostMetrics.publish/3` pass through.
  """
  @spec republish_stale(keyword()) :: non_neg_integer()
  def republish_stale(opts \\ []) do
    grace = Keyword.get(opts, :grace_seconds, @grace_seconds)
    limit = Keyword.get(opts, :limit, @batch_limit)
    %{rows: rows} = Repo.query!(@stale_markers, [grace, limit])

    Enum.count(rows, fn [event_id, agent_id, gateway_id, partition, compressed] ->
      identity = %{
        event_id: event_id,
        agent_id: agent_id,
        gateway_id: gateway_id,
        partition: partition
      }

      case decode(compressed) do
        {:ok, batch} ->
          publish_and_clear(identity, batch, opts) == :ok

        {:error, reason} ->
          # A marker this node wrote and cannot read can never publish; dropping it is the
          # only bounded outcome.
          Logger.error("Unreadable sweep host gauge marker dropped",
            event_id: event_id,
            reason: inspect(reason)
          )

          clear(event_id)
          false
      end
    end)
  end

  defp publish_and_clear(identity, batch, opts) do
    case SweepHostMetrics.publish(batch, identity, opts) do
      :ok -> clear(identity.event_id)
      {:error, _reason} = error -> error
    end
  end

  defp clear(event_id) do
    Repo.query!(@delete_marker, [Ecto.UUID.dump!(event_id)])
    :ok
  end

  defp decode(compressed) do
    {:ok, compressed |> :zlib.uncompress() |> SweepObservationBatchV1.decode()}
  rescue
    error -> {:error, error}
  end

  defp marker_identity(event_id) do
    case Repo.query(@marker_identity, [Ecto.UUID.dump!(event_id)]) do
      {:ok, %{rows: [[agent_id, gateway_id, partition]]}} ->
        {:ok,
         %{event_id: event_id, agent_id: agent_id, gateway_id: gateway_id, partition: partition}}

      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:error, _reason} = error ->
        error
    end
  rescue
    error -> {:error, error}
  end
end
