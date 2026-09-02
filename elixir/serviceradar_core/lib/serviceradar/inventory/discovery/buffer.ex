defmodule ServiceRadar.Inventory.Discovery.Buffer do
  @moduledoc """
  Holds partial discovery snapshots until every part arrives, and remembers what
  has already been accepted per observation scope.

  Both jobs need state that outlives a single ingest call, which is why this is
  a process rather than a function.

  ## Reassembly

  A snapshot larger than one telemetry batch is split by the producer into parts
  sharing a `snapshot_id`. A set completes only when every index has arrived AND
  one part is marked `complete`. Counting parts alone accepts a set whose final
  part never came but which received a duplicate instead; the complete flag
  alone accepts a set missing a middle part.

  This path should be effectively cold: the measurement in
  `//go/pkg/agent/netprobe:netprobe_test` puts a fleet-maximum census snapshot at
  0.17% of the batch cap. It exists because when the cap IS exceeded the agent
  drops the whole batch with no re-queue, so the failure is total silence on
  exactly the largest segments.

  ## Supersession

  A snapshot REPLACES its `observation_scope`, so applying an older one after a
  newer one resurrects devices that have since aged out. Nothing between the
  producer and here guarantees ordering, so the comparison is on
  `generated_at_unix_nano`, not arrival.

  netprobe already collapses per interface before emitting. This is the
  defensive half of the same rule, and it is what moves out of the agent's
  `DrainCensusSnapshots`.

  ## Bounds

  Every map is bounded three ways -- TTL, set count, and part count -- because a
  malformed or hostile producer must not be able to grow them. A dropped set is
  counted, never silent.
  """
  use GenServer

  require Logger

  # Long enough to outlast a slow multi-part push, short enough that a producer
  # dying mid-snapshot does not pin memory. Matches the agent-side assembler
  # this replaces.
  @partial_ttl_ms to_timeout(minute: 5)

  # A producer emitting more concurrent snapshot sets than this is malfunctioning
  # or hostile; the oldest is evicted rather than letting the map grow.
  @max_partial_sets 8

  # No real snapshot needs this many parts. Refusing a larger claim stops one
  # corrupt header from reserving a huge map.
  @max_parts 4096

  # Scope watermarks are cheap (one integer each) but still bounded, since
  # `observation_scope` is producer-supplied.
  @max_scopes 1024

  defstruct partials: %{}, watermarks: %{}, dropped: %{}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Offer one envelope.

  Returns `{:ready, payloads}` when a complete snapshot is available (one
  element for a single-part snapshot, or every part in index order),
  `:buffered` while a set is still incomplete, or `{:dropped, reason}`.
  """
  @spec offer(map(), keyword()) :: {:ready, [binary()]} | :buffered | {:dropped, atom()}
  def offer(envelope, opts \\ []) do
    GenServer.call(Keyword.get(opts, :name, __MODULE__), {:offer, envelope, now_ms()})
  end

  @doc "Counts of dropped sets by reason. Test- and metrics-facing."
  @spec dropped(keyword()) :: %{atom() => non_neg_integer()}
  def dropped(opts \\ []) do
    GenServer.call(Keyword.get(opts, :name, __MODULE__), :dropped)
  end

  @doc """
  Drop every buffered part and every supersession watermark.

  Test-facing. The watermarks persist by design -- that is what makes a late
  snapshot unable to undo a newer one -- so tests that exercise supersession need
  a way back to a known state. They cannot get it by starting their own Buffer:
  `DiscoveryIngestor` calls `offer/1` with the default name, so a second instance
  under a test name would simply never be consulted, and starting one under the
  DEFAULT name fails because the application supervisor already owns it.
  """
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []) do
    GenServer.call(Keyword.get(opts, :name, __MODULE__), :reset)
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:offer, envelope, now}, _from, state) do
    state = expire(state, now)
    {result, state} = do_offer(envelope, now, state)
    {:reply, result, state}
  end

  def handle_call(:dropped, _from, state), do: {:reply, state.dropped, state}

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %__MODULE__{}}

  defp do_offer(envelope, now, state) do
    part_count = envelope.part_count || 0

    cond do
      part_count > @max_parts ->
        {{:dropped, :too_many_parts}, count(state, :too_many_parts)}

      part_count <= 1 and envelope.complete ->
        # The overwhelmingly common case: one part, already complete. No
        # buffering at all.
        accept_if_newer([envelope.payload], envelope, state)

      part_count <= 1 ->
        # Not complete, and claims no set it belongs to. Nothing can place it.
        {{:dropped, :incomplete_single_part}, count(state, :incomplete_single_part)}

      envelope.part_index >= part_count ->
        {{:dropped, :invalid_part_index}, count(state, :invalid_part_index)}

      true ->
        buffer_part(envelope, now, state)
    end
  end

  defp buffer_part(envelope, now, state) do
    key = {envelope.schema, envelope.snapshot_id}
    existing = Map.get(state.partials, key)

    if existing && existing.part_count != envelope.part_count do
      # Two different snapshots claiming one id, or a corrupt header. A merged
      # result would report devices present or absent from fragments of two
      # different observations, which is worse than reporting nothing.
      state = %{state | partials: Map.delete(state.partials, key)}
      {{:dropped, :part_count_changed}, count(state, :part_count_changed)}
    else
      state = evict_if_full(state)

      partial =
        existing ||
          %{parts: %{}, part_count: envelope.part_count, first_seen: now, complete_seen: false}

      partial = %{
        partial
        | parts: Map.put(partial.parts, envelope.part_index, envelope.payload),
          # BOTH conditions are required to complete a set. Counting parts alone
          # accepts one whose final part never came but which got a duplicate
          # instead; the flag alone accepts one missing a middle part.
          complete_seen: partial.complete_seen or envelope.complete
      }

      if map_size(partial.parts) == partial.part_count and partial.complete_seen do
        payloads =
          partial.parts |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

        state = %{state | partials: Map.delete(state.partials, key)}
        accept_if_newer(payloads, envelope, state)
      else
        {:buffered, %{state | partials: Map.put(state.partials, key, partial)}}
      end
    end
  end

  # A snapshot replaces its scope, so an older one arriving late must not undo a
  # newer one. An empty scope opts out of supersession entirely.
  defp accept_if_newer(payloads, %{observation_scope: scope}, state) when scope in [nil, ""] do
    {{:ready, payloads}, state}
  end

  defp accept_if_newer(payloads, envelope, state) do
    key = {envelope.schema, envelope.observation_scope}
    generated_at = envelope.generated_at_unix_nano || 0
    previous = Map.get(state.watermarks, key, 0)

    if generated_at < previous do
      {{:dropped, :superseded}, count(state, :superseded)}
    else
      state = %{state | watermarks: bounded_put(state.watermarks, key, generated_at, @max_scopes)}
      {{:ready, payloads}, state}
    end
  end

  defp expire(state, now) do
    {live, expired} =
      Enum.split_with(state.partials, fn {_key, partial} ->
        now - partial.first_seen < @partial_ttl_ms
      end)

    state = Enum.reduce(expired, state, fn _entry, acc -> count(acc, :partial_expired) end)
    %{state | partials: Map.new(live)}
  end

  defp evict_if_full(state) when map_size(:erlang.map_get(:partials, state)) < @max_partial_sets,
    do: state

  defp evict_if_full(state) do
    {oldest_key, _} = Enum.min_by(state.partials, fn {_key, partial} -> partial.first_seen end)

    state
    |> count(:partial_evicted)
    |> Map.update!(:partials, &Map.delete(&1, oldest_key))
  end

  # Watermarks never expire on their own, so the map is capped. Dropping the
  # lowest watermark is the least harmful choice: it can only cause an old
  # snapshot to be re-accepted, never a new one to be rejected.
  defp bounded_put(map, key, value, max) when map_size(map) < max, do: Map.put(map, key, value)

  defp bounded_put(map, key, value, _max) do
    {lowest_key, _} = Enum.min_by(map, fn {_key, watermark} -> watermark end)

    map |> Map.delete(lowest_key) |> Map.put(key, value)
  end

  defp count(state, reason) do
    %{state | dropped: Map.update(state.dropped, reason, 1, &(&1 + 1))}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
