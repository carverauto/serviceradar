defmodule ServiceRadar.Edge.PublishPipeline do
  @moduledoc """
  Asynchronous, bounded publish pipelining and out-of-order PubAck accounting
  (unify-sweep-results-proto task 3.3(c), the half `PublisherPool` left open).

  Task 3.3(c) asks for two things this supplies together, because neither is much use alone:
  publishes must be PIPELINED under hard outstanding frame/byte/PubAck-deadline windows "rather
  than serializing every frame on one request", and out-of-order PubAcks must be RECORDED so that
  only the contiguous resolved edge prefix is exposed.

  ## What was actually missing

  `PublishWindow` bounds admission. `PublisherPool` owns that bound per traffic class.
  `ResolvedPrefix` advances a contiguous watermark across out-of-order outcomes. All three
  existed; nothing drove them concurrently. `JetStreamPublisher.publish_record/2` admits,
  requests, and settles inline, so exactly one frame was ever on the wire per calling process --
  which is why `PublisherPool` had to say the window "bounds concurrent admissions but NOT
  concurrent publications".

  With this module the two coincide. Each worker performs the WHOLE cycle -- admit, publish,
  settle -- so the frame and byte credits it takes are held for exactly as long as its request is
  outstanding. The number of requests on the wire is then bounded by the grant, not merely by how
  many callers happen to exist.

  ## WHY EACH WORKER ADMITS FOR ITSELF

  This is the load-bearing design decision, and the obvious alternative is wrong. A dispatcher
  that admitted centrally and handed reservations to workers would break the fencing invariant
  the pool documents: the OWNER of an attempt is the process that called `admit/4`, taken from
  the call's `from` precisely so no caller can name another process, and only the owner may
  `settle/3` or `attempt_failed/2`. A handed-off reservation would leave the dispatcher as owner
  of a request it did not issue and cannot report on.

  So the pipeline hands out WORK, never reservations. Each worker is the owner of its own attempt
  from admission to settlement, which is what carries task 3.3's post-handoff fencing criterion
  (ii) into the concurrent case unchanged rather than reasoning about it afresh.

  ## ONE PIPELINE PER CLASS, NEVER PER LANE

  `nats-tenant-isolation` forbids the installation creating "a durable, connection, PROCESS,
  account, or physical stream per network scope, agent, producer assignment, run/execution,
  output contract, package, or logical partition". A prefix tracker is per SPOOL LANE, so the
  tempting shape -- a process per lane, holding its own tracker -- is exactly the prohibited one.

  The trackers are therefore DATA in one per-class process, keyed by lane. Per-lane state is
  allowed; a per-lane process is not, and the distinction is the whole reason `open_lane/3` takes
  a key rather than starting something.

  Their number is bounded by `:max_lanes` and refused past it, so "data rather than a process"
  does not quietly become unbounded retention instead. Task 3.4 owns the exact-byte and
  retained-memory bounds; what is bounded here is the COUNT.

  ## Backpressure is a refusal, and retry is NOT this module's decision

  An offer beyond `:max_queue` is refused `:queue_full`. That is the whole backpressure policy,
  deliberately.

  Nothing here republishes. A publication whose attempt did not resolve is recorded
  `REJECTED_RETRYABLE`, which CAPS the prefix at the sequence before it, and the caller learns
  that from `resolved_through/2`. Requeueing internally was the first design and it was wrong
  twice: a capacity refusal requeued and redispatched immediately is a hot loop against a
  saturated window, and every other failure may have reached the socket, so republishing it is a
  decision about a source sequence that this module holds no state to make -- the same reason
  `JetStreamPublisher` returns a retryable error rather than retrying.

  ## What resolves, and what only caps

  Conservatively, because the cost of the two errors is not symmetric: a sequence wrongly resolved
  lets the prefix advance past a record that may never have been published, and eventually
  authorises reclaiming customer data that was never delivered.

      {:ok, pub_ack}        -> ACCEPTED_AUTHORITATIVE   resolves
      {:error, :poison}     -> REJECTED_PERMANENT       resolves (PROVEN poison only)
      any other error       -> REJECTED_RETRYABLE       caps the prefix
      the worker CRASHED    -> REJECTED_RETRYABLE       caps the prefix

  A worker crash is deliberately in the last row rather than treated as a missing outcome. It is
  no evidence about the broker -- a process can die after its request reached the socket -- and it
  leaves that worker's reservation charged in the pool, since owner death is not termination.
  That retention is task 3.3's known open gap, owed to 3.5's correlation work; this module does
  not paper over it by pretending the sequence resolved.

  `{:error, {:derivation, _}}` also only caps. It is a local bug or a bad grant rather than a
  broker verdict, and nothing about it proves the record can never be accepted -- which is the
  only thing that makes a rejection terminal.

  ## NOT IN THE SUPERVISION TREE, and that is not an oversight

  Nothing offers to this yet. The gateway's per-lane session is task 3.1's mTLS bidirectional
  record RPC, which does not exist, and `JetStreamPublisher.publish_record/2` still has no
  production caller either. Starting a pipeline per lane in the application would be a process
  with no runtime reason, so it is constructed by its tests and by whatever drives it when 3.1
  lands -- the same status `ResolvedPrefix` has today.

  When it is wired, it belongs LAST under `LaneSupervisor`'s `:rest_for_one`, after the
  accountant and the transport. The order follows from what each death invalidates: this process
  dying loses only its trackers, and a fresh one refuses every offer until the caller re-opens
  its lanes with an agent-reported `first_unresolved_sequence` -- which is the authoritative
  recovery rather than a guess. Transport death invalidates the requests in flight on it, so this
  should go with it. Accountant death already takes everything after it.
  """

  use GenServer

  alias ServiceRadar.Edge.ResolvedPrefix

  require Logger

  @accepted :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE
  @permanent :EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT
  @retryable :EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE

  # Concurrency, lane retention and queue depth are bounded independently because they bound
  # DIFFERENT things. Credits bound what the broker has outstanding; :max_inflight bounds
  # processes and the memory they retain; :max_queue bounds work accepted but not started.
  # Collapsing them would let one grant shape decide all three.
  #
  # The EFFECTIVE concurrency is the smaller of :max_inflight and what the lane's credits allow,
  # and at these defaults that is :max_inflight -- `PublisherSupervisor` grants 64 frames. That is
  # deliberate rather than an oversight: each worker retains a record body, minimal headers and
  # NATS request state for as long as its request is outstanding, so 64 of them is a memory claim
  # nothing has yet bounded. Task 3.4 owns the measured retained-memory bound; until it lands the
  # process count is capped low, and a deployment that has measured its own can raise it.
  @default_max_inflight 8
  @default_max_queue 256
  @default_max_lanes 1024

  # A lane sequence is a protobuf uint64, and `ResolvedPrefix.new/1` GUARDS on that range rather
  # than refusing it. An unchecked value therefore raises a FunctionClauseError inside this
  # GenServer and takes the process -- and every other lane's prefix -- with it. Bounding it here
  # is what keeps a refusable input a refusal.
  @u64_max 0xFFFFFFFFFFFFFFFF

  @typedoc """
  A spool lane: the authenticated slot MINUS the sequence. Sequences are the index INTO a lane,
  so they cannot also identify one -- two agents both at sequence 1 are two lanes, not a retry.
  """
  @type lane :: {binary(), binary(), binary()}

  @doc """
  Starts the pipeline for one traffic class.

  Required:

    * `:class` -- the traffic class, which is the ONLY thing this is keyed on.
    * `:pool` -- the class's `PublisherPool`, passed to each worker so it admits and settles
      against the same window its request is bounded by.
    * `:publisher` -- `(publication, keyword() -> result)`. Injected rather than called directly:
      `JetStreamPublisher` lives in the gateway, which depends on this application and not the
      other way round, so naming it here would invert that.
    * `:task_supervisor` -- workers run under it, so a crashing publish cannot take the ledger
      with it.

  Optional: `:max_inflight`, `:max_queue`, `:max_lanes`, `:publish_opts`, `:name`.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Opens a lane's prefix tracker at the agent's `first_unresolved_sequence`.

  Required before any offer for that lane. Refusing an offer for an unopened lane
  (`:lane_not_open`) is the fail-closed direction: the base cannot be invented here, because
  seeding a resumed lane from its origin would re-open a window the agent has already closed.

  Re-opening an OPEN lane is refused `:lane_already_open` rather than silently reseeding it,
  which would discard the outcomes recorded since.
  """
  @spec open_lane(GenServer.server(), lane(), pos_integer()) :: :ok | {:error, atom()}
  def open_lane(pipeline, lane, first_unresolved_sequence),
    do: GenServer.call(pipeline, {:open_lane, lane, first_unresolved_sequence})

  @doc "Drops a lane's tracker, freeing one of `:max_lanes`."
  @spec close_lane(GenServer.server(), lane()) :: :ok
  def close_lane(pipeline, lane), do: GenServer.call(pipeline, {:close_lane, lane})

  @doc """
  Offers one publication for asynchronous publication.

  Returns as soon as the work is ACCEPTED, not when it is published -- that is the point. The
  outcome lands in the lane's prefix, and `resolved_through/2` is where a caller reads it.

  Refusals: `:lane_not_open`, `:queue_full`, `:slot` (the publication carries no usable slot).
  """
  @spec offer(GenServer.server(), map()) :: :ok | {:error, atom()}
  def offer(pipeline, publication) when is_map(publication),
    do: GenServer.call(pipeline, {:offer, publication})

  @doc "The lane's contiguous resolved watermark. Stops at a gap OR at a retryable outcome."
  @spec resolved_through(GenServer.server(), lane()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def resolved_through(pipeline, lane), do: GenServer.call(pipeline, {:resolved_through, lane})

  @doc """
  Releases prefix evidence below the agent's reported `first_unresolved_sequence`.

  See `ResolvedPrefix.release_below/2`: this is the only local-durability signal the gateway can
  observe, and it is an observation rather than an inference.
  """
  @spec release_below(GenServer.server(), lane(), pos_integer()) :: :ok | {:error, atom()}
  def release_below(pipeline, lane, first_unresolved_sequence),
    do: GenServer.call(pipeline, {:release_below, lane, first_unresolved_sequence})

  @doc "Depth and concurrency, for tests and observability."
  @spec stats(GenServer.server()) :: map()
  def stats(pipeline), do: GenServer.call(pipeline, :stats)

  @impl true
  def init(opts) do
    {:ok,
     %{
       class: Keyword.fetch!(opts, :class),
       pool: Keyword.fetch!(opts, :pool),
       publisher: Keyword.fetch!(opts, :publisher),
       task_supervisor: Keyword.fetch!(opts, :task_supervisor),
       publish_opts: Keyword.get(opts, :publish_opts, []),
       max_inflight: Keyword.get(opts, :max_inflight, @default_max_inflight),
       max_queue: Keyword.get(opts, :max_queue, @default_max_queue),
       max_lanes: Keyword.get(opts, :max_lanes, @default_max_lanes),
       # Accepted but not started. Bounded by :max_queue.
       queue: :queue.new(),
       queued: 0,
       # task ref => %{lane, sequence}. Bounded by :max_inflight.
       inflight: %{},
       # lane => ResolvedPrefix.t(). DATA per lane, never a process. Bounded by :max_lanes.
       lanes: %{}
     }}
  end

  @impl true
  def handle_call({:open_lane, lane, first_unresolved}, _from, state) do
    cond do
      Map.has_key?(state.lanes, lane) ->
        {:reply, {:error, :lane_already_open}, state}

      map_size(state.lanes) >= state.max_lanes ->
        {:reply, {:error, :lane_limit}, state}

      not (is_integer(first_unresolved) and first_unresolved >= 1 and
               first_unresolved <= @u64_max) ->
        {:reply, {:error, :first_unresolved_sequence}, state}

      true ->
        prefix = ResolvedPrefix.new(first_unresolved)
        {:reply, :ok, %{state | lanes: Map.put(state.lanes, lane, prefix)}}
    end
  end

  def handle_call({:close_lane, lane}, _from, state),
    do: {:reply, :ok, %{state | lanes: Map.delete(state.lanes, lane)}}

  def handle_call({:offer, publication}, _from, state) do
    case slot_of(publication) do
      {:ok, lane, sequence} -> offer_reply(state, lane, sequence, publication)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resolved_through, lane}, _from, state) do
    case Map.fetch(state.lanes, lane) do
      {:ok, prefix} -> {:reply, {:ok, ResolvedPrefix.resolved_through(prefix)}, state}
      :error -> {:reply, {:error, :lane_not_open}, state}
    end
  end

  def handle_call({:release_below, lane, first_unresolved}, _from, state) do
    with {:ok, prefix} <- fetch_lane(state, lane),
         {:ok, released} <- ResolvedPrefix.release_below(prefix, first_unresolved) do
      {:reply, :ok, %{state | lanes: Map.put(state.lanes, lane, released)}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       class: state.class,
       inflight: map_size(state.inflight),
       queued: state.queued,
       lanes: map_size(state.lanes),
       max_inflight: state.max_inflight,
       max_queue: state.max_queue
     }, state}
  end

  defp offer_reply(state, lane, sequence, publication) do
    cond do
      not Map.has_key?(state.lanes, lane) ->
        {:reply, {:error, :lane_not_open}, state}

      state.queued >= state.max_queue ->
        {:reply, {:error, :queue_full}, state}

      true ->
        work = %{lane: lane, sequence: sequence, publication: publication}

        {:reply, :ok,
         dispatch(%{state | queue: :queue.in(work, state.queue), queued: state.queued + 1})}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.inflight, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{lane: lane, sequence: sequence}, rest} ->
        # The task succeeded, so its :DOWN carries no information and is flushed rather than
        # falling through to the crash clause below and recording a second outcome.
        Process.demonitor(ref, [:flush])

        {:noreply,
         dispatch(record(%{state | inflight: rest}, lane, sequence, disposition_of(result)))}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.inflight, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{lane: lane, sequence: sequence}, rest} ->
        # The worker died without reporting. RETRYABLE, never resolved: process death says nothing
        # about whether the bytes reached the broker, and the reservation it owned stays charged in
        # the pool because owner death is not termination.
        Logger.warning(
          "edge publish worker for lane #{inspect(lane)} sequence #{sequence} died " <>
            "(#{inspect(reason)}); the sequence stays unresolved and its reservation stays charged"
        )

        {:noreply, dispatch(record(%{state | inflight: rest}, lane, sequence, @retryable))}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Starts workers while there is BOTH queued work and a free slot. The loop is what makes the
  # bound a bound: nothing dispatches on the strength of having been offered.
  #
  # Emptiness is decided by the QUEUE, not by `queued`. The counter exists because `:queue.len/1`
  # is O(n) and `:max_queue` is checked on every offer -- but a counter beside a queue is a second
  # source of truth, and driving the loop from it would turn any drift into a MatchError here,
  # killing the process and every lane's prefix with it. Reading the queue makes the counter
  # advisory: it can only ever be wrong about admitting one more offer, never about correctness.
  defp dispatch(state) do
    if map_size(state.inflight) < state.max_inflight do
      case :queue.out(state.queue) do
        {{:value, work}, rest} ->
          %{state | queue: rest, queued: state.queued - 1}
          |> start_worker(work)
          |> dispatch()

        {:empty, _queue} ->
          state
      end
    else
      state
    end
  end

  defp start_worker(state, %{lane: lane, sequence: sequence, publication: publication}) do
    publisher = state.publisher

    # `:pools` is a lane => pool MAP, which is the option `JetStreamPublisher.pool_for/2` reads.
    # The class IS the lane here, so one entry is the whole map: a pipeline cannot direct work at
    # another class's window because it has no reference to one.
    opts = Keyword.put(state.publish_opts, :pools, %{state.class => state.pool})

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        # ADMIT, PUBLISH AND SETTLE HAPPEN HERE, in this process. That is not an implementation
        # detail: the pool takes the attempt's owner from the call's `from`, so this process
        # becoming the owner is what lets it -- and only it -- report the outcome.
        publisher.(publication, opts)
      end)

    %{
      state
      | inflight: Map.put(state.inflight, task.ref, %{lane: lane, sequence: sequence})
    }
  end

  # Only a durable PubAck and PROVEN poison resolve. Everything else caps the prefix, which is the
  # conservative direction: the prefix must never advance past a record that may not be published.
  defp disposition_of({:ok, _pub_ack}), do: @accepted
  defp disposition_of({:error, :poison}), do: @permanent
  defp disposition_of(_other), do: @retryable

  defp record(state, lane, sequence, disposition) do
    case fetch_lane(state, lane) do
      {:ok, prefix} ->
        case ResolvedPrefix.record(prefix, sequence, disposition) do
          {:ok, updated} ->
            %{state | lanes: Map.put(state.lanes, lane, updated)}

          # A refused outcome leaves the prefix EXACTLY as it was, which is the safe direction:
          # a conflicting or out-of-range sequence must not be able to advance a watermark. It is
          # logged rather than swallowed because it means the caller offered a sequence the lane
          # had already released or resolved differently.
          {:error, reason} ->
            Logger.warning(
              "edge publish outcome refused for lane #{inspect(lane)} sequence #{sequence}: " <>
                "#{inspect(reason)}"
            )

            state
        end

      # The lane was closed while its work was in flight. Nothing to record onto, and inventing a
      # tracker here would resurrect a lane the caller deliberately dropped.
      {:error, :lane_not_open} ->
        state
    end
  end

  defp fetch_lane(state, lane) do
    case Map.fetch(state.lanes, lane) do
      {:ok, prefix} -> {:ok, prefix}
      :error -> {:error, :lane_not_open}
    end
  end

  # The lane and the sequence, from the AUTHENTICATED slot -- the same source `JetStreamPublisher`
  # keys its reservations on, so the two cannot describe different records.
  defp slot_of(publication) do
    slot = Map.get(publication, :slot, %{})

    with scope when is_binary(scope) <- Map.get(slot, :network_scope_id),
         agent when is_binary(agent) <- Map.get(slot, :authenticated_agent_id),
         spool when is_binary(spool) <- Map.get(slot, :spool_id),
         sequence when is_integer(sequence) and sequence >= 1 <- Map.get(slot, :sequence) do
      {:ok, {scope, agent, spool}, sequence}
    else
      _ -> {:error, :slot}
    end
  end
end
