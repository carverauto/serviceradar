defmodule ServiceRadar.EventWriter.StreamOwnership do
  @moduledoc """
  EventWriter's side of the stream-ownership claim (design D6 of
  `update-jetstream-storage-budget`).

  `events`, `flows` and `ARANCINI_CAUSAL` each have two possible writers of the
  stream shape (`max_bytes`, replicas, retention): a dedicated collector (the
  otel log-collector, flow-collector, bmp-collector) and EventWriter, which
  creates the stream when it is absent so its consumers can bind. The owner is
  recorded in the stream's metadata under `serviceradar.owner`:

    * claimed by `event-writer` - EventWriter reconciles the shape;
    * claimed by a collector - EventWriter only merges its subjects;
    * no claim (a stream created before the claim existed, or one whose claim
      was removed) - EventWriter only merges subjects until the stream has stayed
      unclaimed for a grace period (15 minutes by default), then claims it and
      reconciles it to the fallback size. A collector that starts inside the
      window claims the stream first, so EventWriter never shrinks it.

  `decide/3` is the pure claim decision. `reconcile/3` is one tick of the
  ownership reconcile timer in `ServiceRadar.EventWriter.Producer`: it re-reads
  `STREAM.INFO` for every watched stream, applies the decision, and only ever
  issues `STREAM.UPDATE` - it never touches a consumer.

  When EventWriter first saw a stream unclaimed lives in the tracker, which lives
  in process state, so a restart starts the grace period again: that can only
  delay a claim, never make one early. The clock is injectable.
  """

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.NATS.JetstreamConsumer

  require Logger

  @owner "event-writer"
  @multi_owner_streams ["events", "flows", "ARANCINI_CAUSAL"]
  @default_grace_period_ms 900_000

  # Stream shape options a watched stream is reconciled to (the fallback shape
  # Config applies to every consumer of a multi-owner stream).
  @shape_keys [
    :stream_retention,
    :stream_storage,
    :stream_discard,
    :stream_replicas,
    :stream_max_bytes,
    :stream_max_age,
    :stream_duplicate_window,
    :stream_owner_claim
  ]

  defstruct grace_period_ms: @default_grace_period_ms,
            clock: nil,
            unclaimed_since: %{}

  @typedoc """
  * `:reconcile` - claimed by `event-writer`: reconcile the shape.
  * `:claim` - unclaimed for the whole grace period: claim, then reconcile.
  * `:merge_subjects` - claimed by a collector: merge subjects only.
  * `:await_grace` - unclaimed, still inside the grace period: merge subjects only.
  """
  @type decision :: :reconcile | :claim | :merge_subjects | :await_grace

  @type t :: %__MODULE__{
          grace_period_ms: non_neg_integer(),
          clock: (-> integer()),
          unclaimed_since: %{optional(String.t()) => integer()}
        }

  @type request_fun :: (String.t(), binary() -> {:ok, map()} | {:error, term()})

  @typedoc "What a watched stream is reconciled to: its subjects and shape options."
  @type watched :: %{
          optional(String.t()) => %{subjects: [String.t()], opts: keyword()}
        }

  @doc "The claim EventWriter records on a stream it owns."
  @spec owner() :: String.t()
  def owner, do: @owner

  @doc "The streams that a collector or EventWriter may own."
  @spec multi_owner_streams() :: [String.t()]
  def multi_owner_streams, do: @multi_owner_streams

  @spec multi_owner_stream?(String.t()) :: boolean()
  def multi_owner_stream?(stream_name), do: stream_name in @multi_owner_streams

  @doc "The grace period used when none is configured (15 minutes)."
  @spec default_grace_period_ms() :: pos_integer()
  def default_grace_period_ms, do: @default_grace_period_ms

  @doc """
  A fresh tracker, with nothing observed unclaimed yet.

  Options: `:grace_period_ms` and `:clock`, a zero-arity function returning the
  current time in milliseconds (monotonic by default).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      grace_period_ms: Keyword.get(opts, :grace_period_ms) || @default_grace_period_ms,
      clock: Keyword.get(opts, :clock) || (&monotonic_ms/0)
    }
  end

  @doc """
  Decides what EventWriter does to the existing stream `stream_name`, given the
  config `STREAM.INFO` returned for it.

  A stream with no claim is recorded as first seen unclaimed at the tracker's
  current time; it is claimed once it has stayed unclaimed for the grace period.
  Observing any claim forgets that time, so a claim removed later starts the
  grace period again.
  """
  @spec decide(t(), String.t(), map()) :: {decision(), t()}
  def decide(%__MODULE__{} = tracker, stream_name, config)
      when is_binary(stream_name) and is_map(config) do
    case JetstreamConsumer.stream_owner(config) do
      @owner -> {:reconcile, forget(tracker, stream_name)}
      nil -> decide_unclaimed(tracker, stream_name)
      _collector -> {:merge_subjects, forget(tracker, stream_name)}
    end
  end

  @doc "True when `decision` lets EventWriter change the stream's shape."
  @spec reconciles_shape?(decision()) :: boolean()
  def reconciles_shape?(decision), do: decision in [:reconcile, :claim]

  @doc """
  The multi-owner streams EventWriter consumes and would create, keyed by
  JetStream stream name, with the subjects its consumers need and the fallback
  shape. A consumer that never creates its stream (`ensure_stream: false`, the
  flow drain consumers) or carries no `event-writer` claim is not watched.
  """
  @spec watched_streams([map()]) :: watched()
  def watched_streams(streams) when is_list(streams) do
    streams
    |> Enum.filter(&watched_stream?/1)
    |> Enum.group_by(&Config.jetstream_stream_name/1)
    |> Map.new(fn {stream_name, [first | _] = group} ->
      subjects = group |> Enum.map(& &1.subject) |> Enum.uniq()

      opts =
        @shape_keys
        |> Enum.map(&{&1, Map.get(first, &1)})
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      {stream_name, %{subjects: subjects, opts: opts}}
    end)
  end

  defp watched_stream?(stream) do
    Map.get(stream, :stream_owner_claim) == @owner and
      Map.get(stream, :ensure_stream, true) != false and
      stream |> Config.jetstream_stream_name() |> multi_owner_stream?()
  end

  @doc """
  One ownership reconcile tick: applies the claim rule to every watched stream
  and returns the updated tracker. `request` performs one JetStream API request
  (see `ServiceRadar.NATS.JetstreamConsumer.stream_info/3`).

  Only `STREAM.INFO` and `STREAM.UPDATE` are issued. A stream that is absent or
  cannot be read is logged and left for the next tick.
  """
  @spec reconcile(t(), request_fun(), watched()) :: t()
  def reconcile(%__MODULE__{} = tracker, request, watched)
      when is_function(request, 2) and is_map(watched) do
    watched
    |> Enum.sort()
    |> Enum.reduce(tracker, fn {stream_name, spec}, acc ->
      reconcile_stream(acc, request, stream_name, spec)
    end)
  end

  defp reconcile_stream(tracker, request, stream_name, spec) do
    case JetstreamConsumer.stream_info(request, stream_name) do
      {:ok, config, stored} ->
        {decision, tracker} = decide(tracker, stream_name, config)
        apply_decision(decision, request, stream_name, spec, config, stored)
        tracker

      :absent ->
        Logger.debug("EventWriter ownership tick: stream #{stream_name} does not exist")
        tracker

      {:error, reason} ->
        Logger.warning(
          "EventWriter ownership tick could not read stream #{stream_name}: #{inspect(reason)}"
        )

        tracker
    end
  end

  defp apply_decision(:claim, request, stream_name, spec, _config, _stored) do
    # Stream update is not compare-and-swap: re-read immediately before claiming
    # and skip the update if any claim has appeared since the decision.
    case JetstreamConsumer.stream_info(request, stream_name) do
      {:ok, fresh, stored} ->
        claim_if_unclaimed(request, stream_name, spec, fresh, stored)

      :absent ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "EventWriter could not re-read stream #{stream_name} before claiming it: " <>
            inspect(reason)
        )

        :ok
    end
  end

  defp apply_decision(_decision, request, stream_name, spec, config, stored) do
    # :reconcile reconciles the shape; :merge_subjects and :await_grace merge
    # subjects only, because the claim check in the payload builder leaves the
    # shape of a stream EventWriter has not claimed untouched.
    update(request, stream_name, config, desired_payload(config, stream_name, spec), stored)
  end

  defp claim_if_unclaimed(request, stream_name, spec, fresh, stored) do
    case JetstreamConsumer.stream_owner(fresh) do
      nil ->
        Logger.info(
          "EventWriter claiming stream #{stream_name}: it stayed unclaimed for the grace period"
        )

        claimed = JetstreamConsumer.put_stream_owner(fresh, @owner)
        update(request, stream_name, fresh, desired_payload(claimed, stream_name, spec), stored)

      owner ->
        Logger.info(
          "EventWriter not claiming stream #{stream_name}: #{inspect(owner)} claimed it first"
        )
    end
  end

  defp desired_payload(config, stream_name, %{subjects: subjects, opts: opts}) do
    Enum.reduce(subjects, config, fn subject, acc ->
      {:ok, payload} =
        JetstreamConsumer.reconciled_stream_payload(acc, stream_name, subject, opts)

      payload
    end)
  end

  # A rejected update is logged by update_stream_if_changed/6 and retried at the
  # next tick; it never affects the consumers.
  defp update(request, stream_name, config, payload, stored) do
    payload = JetstreamConsumer.hold_discard_new_max_bytes(stream_name, config, payload, stored)
    _ = JetstreamConsumer.update_stream_if_changed(request, stream_name, config, payload, stored)
    :ok
  end

  defp decide_unclaimed(tracker, stream_name) do
    now = tracker.clock.()
    since = Map.get(tracker.unclaimed_since, stream_name, now)
    tracker = %{tracker | unclaimed_since: Map.put(tracker.unclaimed_since, stream_name, since)}

    if now - since >= tracker.grace_period_ms do
      {:claim, tracker}
    else
      {:await_grace, tracker}
    end
  end

  defp forget(tracker, stream_name) do
    %{tracker | unclaimed_since: Map.delete(tracker.unclaimed_since, stream_name)}
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
