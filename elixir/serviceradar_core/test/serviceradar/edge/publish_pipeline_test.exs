defmodule ServiceRadar.Edge.PublishPipelineTest do
  @moduledoc """
  The two properties task 3.3(c) asks for once publishing is CONCURRENT: the hard window must
  bound how many requests are on the wire at once, and out-of-order PubAcks must advance only the
  contiguous resolved prefix.

  ## The publisher double goes THROUGH the window

  A stub that merely blocked would have made the concurrency assertions vacuous: the pipeline
  would look bounded while the pool it is supposed to be bounded BY was never consulted. So the
  double is a faithful miniature of `JetStreamPublisher.publish_record/2` -- it admits through the
  lane's `PublisherPool`, holds the reservation across a gate the test opens, and then settles or
  reports the attempt failed. Credits are therefore held for exactly as long as a request is
  outstanding, which is the property under test.

  Because the double runs INSIDE the worker, it is also the worker's own process doing the
  admitting and settling -- which is the ownership rule the pipeline is built around, exercised
  rather than assumed.

  ## Concurrency is observed from outside

  Every assertion about how many publishes overlap is made from messages the double sends to the
  test process, which serialises them. Nothing asks the pipeline to report its own concurrency;
  that number would be wrong in the same way the code would be.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.PublisherPool
  alias ServiceRadar.Edge.PublishPipeline
  alias ServiceRadar.Edge.PublishWindow

  @scope <<0xA1>>
  @agent "agent-1"
  @spool <<0xB2>>
  @lane {@scope, @agent, @spool}
  @bytes 50

  defp publication(sequence) do
    %{
      slot: %{
        network_scope_id: @scope,
        authenticated_agent_id: @agent,
        spool_id: @spool,
        sequence: sequence
      },
      record_bytes: :binary.copy(<<0>>, @bytes),
      record_sha256: <<sequence::256>>
    }
  end

  defp pool(frames, bytes) do
    {pool, _transport} = pool_with_transport(frames, bytes)
    pool
  end

  defp pool_with_transport(frames, bytes) do
    {:ok, pid} =
      PublisherPool.start_link(
        class: :bulk,
        frame_credits: frames,
        byte_credits: bytes,
        name: nil
      )

    {pid, register_transport(pid)}
  end

  defp register_transport(pool) do
    transport = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(transport, :kill) end)
    {:ok, _generation} = PublisherPool.register_transport(pool, transport)
    transport
  end

  # A miniature of the real publisher: ADMIT -> (gate) -> SETTLE, all in the worker's own process.
  defp windowed_publisher(test) do
    fn publication, opts ->
      pool = opts |> Keyword.fetch!(:pools) |> Map.fetch!(:bulk)
      sequence = publication.slot.sequence
      bytes = byte_size(publication.record_bytes)

      key =
        PublishWindow.key(@scope, @agent, @spool, sequence, {publication.record_sha256, bytes})

      case PublisherPool.admit(pool, key, bytes, 60_000) do
        {:ok, reservation} ->
          send(test, {:started, sequence, self()})

          receive do
            {:release, {:ok, _ack} = ok} ->
              # The real publisher refuses to report a publish durable when the accounting that
              # authorised it did not survive -- which is precisely what a fenced generation
              # produces. Asserting `:ok` here would have made the double crash on the one path
              # this suite most needs to exercise.
              case PublisherPool.settle(pool, reservation, :primary_publication) do
                :ok -> ok
                {:error, _reason} -> {:error, :systemic}
              end

            {:release, {:error, :poison} = poison} ->
              case PublisherPool.settle(pool, reservation, :permanent_rejection) do
                :ok -> poison
                {:error, _reason} -> {:error, :systemic}
              end

            {:release, other} ->
              _ = PublisherPool.attempt_failed(pool, reservation)
              other
          after
            15_000 -> {:error, :timeout}
          end

        # Refused BEFORE any I/O, exactly as the real publisher classifies an exhausted window.
        {:error, _reason} ->
          send(test, {:refused, sequence})
          {:error, :capacity}
      end
    end
  end

  defp pipeline(pool, publisher, opts \\ []) do
    {:ok, sup} = Task.Supervisor.start_link()

    {:ok, pid} =
      PublishPipeline.start_link(
        [class: :bulk, pool: pool, publisher: publisher, task_supervisor: sup, name: nil] ++ opts
      )

    pid
  end

  defp open(pipeline, first_unresolved \\ 1) do
    :ok = PublishPipeline.open_lane(pipeline, @lane, first_unresolved)
    pipeline
  end

  defp started(sequence) do
    receive do
      {:started, ^sequence, worker} -> worker
    after
      5_000 -> flunk("the publisher for sequence #{sequence} never started")
    end
  end

  # Collects the next `n` publishes to start, in whatever order they do. Returns sequence => pid.
  defp started_any(n) do
    Enum.reduce(1..n, %{}, fn _, acc ->
      receive do
        {:started, sequence, worker} -> Map.put(acc, sequence, worker)
      after
        5_000 -> flunk("only #{map_size(acc)} of #{n} publishes started")
      end
    end)
  end

  defp refute_started(within) do
    receive do
      {:started, sequence, _worker} ->
        flunk("sequence #{sequence} started while the bound should have held it back")
    after
      within -> :ok
    end
  end

  defp release(worker, result), do: send(worker, {:release, result})

  defp ack(sequence), do: {:ok, %{stream: "edge", seq: sequence, duplicate: false}}

  defp resolved(pipeline) do
    {:ok, through} = PublishPipeline.resolved_through(pipeline, @lane)
    through
  end

  defp eventually(fun, tries \\ 300)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, tries - 1)
    end
  end

  describe "publishing is pipelined, and the bound is a bound" do
    test "max_inflight caps how many publishes are outstanding AT ONCE" do
      # Six offers, three slots. The point is not that three start -- it is that the fourth does
      # NOT, and then does exactly when a slot frees. A pipeline that dispatched on being offered
      # would pass the first half of this and fail the second.
      p = pool(16, 4_000)
      pipe = open(pipeline(p, windowed_publisher(self()), max_inflight: 3))

      for sequence <- 1..6, do: :ok = PublishPipeline.offer(pipe, publication(sequence))

      workers = started_any(3)
      assert map_size(workers) == 3
      refute_started(150)

      # Releasing ONE frees exactly ONE slot.
      {_sequence, worker} = Enum.at(workers, 0)
      release(worker, ack(1))

      more = started_any(1)
      assert map_size(more) == 1
      refute_started(150)
    end

    test "the lane GRANT bounds concurrent PUBLICATIONS, not merely concurrent admissions" do
      # The headline property of this increment. `max_inflight` is deliberately larger than the
      # grant, so if the window did not bind, five publishes would be on the wire at once.
      # Serially this was untestable: one caller could only ever have one request outstanding, so
      # the window bounded admissions and nothing bounded publications.
      p = pool(2, 4_000)
      pipe = open(pipeline(p, windowed_publisher(self()), max_inflight: 8))

      for sequence <- 1..5, do: :ok = PublishPipeline.offer(pipe, publication(sequence))

      workers = started_any(2)
      assert map_size(workers) == 2

      # The other three were refused BEFORE any I/O rather than queued behind the grant.
      assert eventually(fn -> refusals_seen() == 3 end),
             "publications past the grant were not refused"

      refute_started(150)

      # AND the grant is genuinely held, not merely counted: nothing else fits until a settle.
      assert %{outstanding_frames: 2, available_frames: 0} = PublisherPool.capacity(p)
    end

    test "BYTE credits bind concurrency the same way frame credits do" do
      # Four frames but only enough bytes for two, so the byte ceiling is the binding one. With a
      # frame-only bound this would run four publishes at once.
      p = pool(4, 2 * @bytes)
      pipe = open(pipeline(p, windowed_publisher(self()), max_inflight: 8))

      for sequence <- 1..4, do: :ok = PublishPipeline.offer(pipe, publication(sequence))

      assert map_size(started_any(2)) == 2
      assert eventually(fn -> refusals_seen() == 2 end)
      refute_started(150)
    end
  end

  describe "out-of-order PubAcks advance only the contiguous prefix" do
    test "acks landing 3,5,1,2,4 move the watermark 0,0,1,3,5" do
      # The reason the prefix exists. Frames earn their outcome out of order, and a watermark that
      # moved on each ack would claim sequences behind a gap were durable.
      p = pool(8, 4_000)
      pipe = open(pipeline(p, windowed_publisher(self()), max_inflight: 5))

      for sequence <- 1..5, do: :ok = PublishPipeline.offer(pipe, publication(sequence))
      workers = started_any(5)

      assert resolved(pipe) == 0

      # 3 resolves, but 1 and 2 have not, so NOTHING is contiguous yet.
      release(workers[3], ack(3))
      assert eventually(fn -> inflight(pipe) == 4 end), "sequence 3's outcome was never recorded"
      assert resolved(pipe) == 0

      release(workers[5], ack(5))
      assert eventually(fn -> inflight(pipe) == 3 end), "sequence 5's outcome was never recorded"
      assert resolved(pipe) == 0

      # 1 resolves: the prefix moves to 1 and STOPS -- 2 is still a gap.
      release(workers[1], ack(1))
      assert eventually(fn -> resolved(pipe) == 1 end), "the prefix did not advance to 1"

      # 2 closes the gap under 3, so the watermark jumps ACROSS an outcome recorded earlier.
      release(workers[2], ack(2))
      assert eventually(fn -> resolved(pipe) == 3 end), "the prefix did not jump 1 -> 3"

      # 4 closes the last gap, and 5 -- recorded first of all -- is finally covered.
      release(workers[4], ack(4))
      assert eventually(fn -> resolved(pipe) == 5 end), "the prefix did not jump 3 -> 5"
    end

    test "a RETRYABLE outcome caps the prefix exactly like a missing one" do
      # A transient failure is not a verdict. Advancing past it would report a record durable that
      # the gateway never accepted.
      p = pool(8, 4_000)
      pipe = open(pipeline(p, windowed_publisher(self()), max_inflight: 3))

      for sequence <- 1..3, do: :ok = PublishPipeline.offer(pipe, publication(sequence))
      workers = started_any(3)

      release(workers[1], ack(1))
      release(workers[2], {:error, :timeout})
      release(workers[3], ack(3))

      assert eventually(fn -> resolved(pipe) == 1 end), "the prefix did not advance to 1"

      # NOT VACUOUS: 3 really was recorded, and it is 2 capping the prefix rather than 3 missing.
      refute eventually(fn -> resolved(pipe) > 1 end, 20),
             "a retryable outcome let the prefix advance past it"

      # AND the retryable frame is still CHARGED -- it is owed a republish on the same slot.
      assert %{outstanding_frames: 1} = PublisherPool.capacity(p)
    end

    test "PROVEN poison resolves, because a permanent rejection is a real outcome" do
      # REJECTED_PERMANENT is in the resolving set: the record will never be accepted, so holding
      # the prefix behind it would wedge the lane on a sequence that can never succeed.
      p = pool(8, 4_000)
      pipe = open(pipeline(p, windowed_publisher(self()), max_inflight: 3))

      for sequence <- 1..3, do: :ok = PublishPipeline.offer(pipe, publication(sequence))
      workers = started_any(3)

      release(workers[1], ack(1))
      release(workers[2], {:error, :poison})
      release(workers[3], ack(3))

      assert eventually(fn -> resolved(pipe) == 3 end),
             "a permanent rejection did not resolve its sequence"

      # And its credits were RELEASED, unlike a retryable one: there is nothing left to republish.
      assert eventually(fn -> match?(%{outstanding_frames: 0}, PublisherPool.capacity(p)) end)
    end

    test "a worker that DIES leaves its sequence unresolved" do
      # Process death is no evidence about the broker -- a worker can die after its request
      # reached the socket. Recording it as resolved would advance the prefix on a guess.
      p = pool(8, 4_000)
      pipe = open(pipeline(p, windowed_publisher(self()), max_inflight: 3))

      for sequence <- 1..3, do: :ok = PublishPipeline.offer(pipe, publication(sequence))
      workers = started_any(3)

      release(workers[1], ack(1))
      Process.exit(workers[2], :kill)
      release(workers[3], ack(3))

      assert eventually(fn -> resolved(pipe) == 1 end)

      refute eventually(fn -> resolved(pipe) > 1 end, 20),
             "a dead worker's sequence was treated as resolved"

      # The pipeline itself survived: async_nolink is what keeps a crashing publish away from the
      # ledger. A linked task would have taken every other lane's prefix with it.
      assert Process.alive?(pipe)
      assert %{inflight: 0} = PublishPipeline.stats(pipe)
    end
  end

  describe "task 3.3's restart and fencing criteria, under CONCURRENCY" do
    @describetag :capture_log

    test "a generation dying mid-flight keeps EVERY charge, and a replacement inherits them" do
      # Criterion (i), which until now was proven only against the serial publisher -- where one
      # caller could have exactly one request outstanding, so "old and replacement requests
      # together cannot exceed the grant" was a claim about a single request. Here FOUR are on the
      # wire when the generation dies, which is the case the criterion was written for.
      # `max_inflight` is deliberately ABOVE the grant, so what holds the fifth publication back
      # is the lane's remaining capacity and not the pipeline's own concurrency cap. With the two
      # equal, the queue would have absorbed it and the assertion below would have passed without
      # the grant being consulted at all.
      {p, transport} = pool_with_transport(4, 4_000)
      pipe = open(pipeline(p, windowed_publisher(self()), max_inflight: 8))

      for sequence <- 1..4, do: :ok = PublishPipeline.offer(pipe, publication(sequence))
      workers = started_any(4)
      assert %{outstanding_frames: 4, available_frames: 0} = PublisherPool.capacity(p)

      Process.exit(transport, :kill)
      assert eventually(fn -> PublisherPool.generations(p).accepting === nil end)

      # THE INVARIANT: generation death ended four attempts and released NOT ONE credit. It is no
      # evidence about whether those bytes reached the broker.
      assert %{outstanding_frames: 4, available_frames: 0} = PublisherPool.capacity(p)

      # So a replacement publishes against the REMAINING capacity, which is none -- rather than
      # against a fresh grant, which is the over-admission this criterion exists to prevent.
      _replacement = register_transport(p)
      assert %{available_frames: 0} = PublisherPool.capacity(p)

      :ok = PublishPipeline.offer(pipe, publication(5))
      assert eventually(fn -> refusals_seen() >= 1 end)
      refute_started(150)

      # AND nothing was reported durable on accounting that did not survive: every ack arrives
      # after the fence, so each is downgraded rather than resolving its sequence.
      for {_sequence, worker} <- workers, do: release(worker, ack(1))
      assert eventually(fn -> inflight(pipe) == 0 end)
      assert resolved(pipe) == 0
    end

    test "a retry is refused while a CONCURRENT attempt for that publication is in flight" do
      # Criterion (ii) in the case it was written for. Serially it could not arise: the single
      # caller was inside its own request, so there was no second process to offer a retry. Here
      # the retry is a genuinely separate worker, and it must be fenced by the previous attempt's
      # REQUEST rather than by a deadline.
      p = pool(4, 4_000)
      pipe = open(pipeline(p, windowed_publisher(self()), max_inflight: 4))

      :ok = PublishPipeline.offer(pipe, publication(1))
      worker = started(1)
      assert %{outstanding_frames: 1} = PublisherPool.capacity(p)

      # The SAME publication offered again while the first attempt is still on the wire.
      :ok = PublishPipeline.offer(pipe, publication(1))

      assert eventually(fn -> refusals_seen() == 1 end),
             "a second attempt for one reservation was admitted concurrently"

      # ONE charge, not two: the retry took no credits and started no request.
      assert %{outstanding_frames: 1, outstanding_bytes: @bytes} = PublisherPool.capacity(p)

      # And the refusal did not resolve the sequence. The original attempt is still the live one,
      # and its ack SUPERSEDES the provisional retryable the refusal recorded.
      assert resolved(pipe) == 0
      release(worker, ack(1))
      assert eventually(fn -> resolved(pipe) == 1 end)
    end
  end

  describe "backpressure is a refusal, and lanes are data" do
    test "an offer past max_queue is refused rather than buffered" do
      p = pool(8, 4_000)
      pipe = open(pipeline(p, windowed_publisher(self()), max_inflight: 1, max_queue: 1))

      assert :ok = PublishPipeline.offer(pipe, publication(1))
      _worker = started(1)

      # One slot in flight, one in the queue, and then the pipeline says no.
      assert :ok = PublishPipeline.offer(pipe, publication(2))
      assert {:error, :queue_full} = PublishPipeline.offer(pipe, publication(3))
    end

    test "an offer for a lane that was never opened is refused" do
      # Fail closed. The base cannot be invented here: seeding a resumed lane from its origin
      # would re-open a window the agent has already closed.
      p = pool(8, 4_000)
      pipe = pipeline(p, windowed_publisher(self()))

      assert {:error, :lane_not_open} = PublishPipeline.offer(pipe, publication(1))
      assert {:error, :lane_not_open} = PublishPipeline.resolved_through(pipe, @lane)
    end

    test "a resumed lane starts at the agent's first_unresolved_sequence, not at its origin" do
      p = pool(8, 4_000)
      pipe = open(pipeline(p, windowed_publisher(self()), max_inflight: 2), 40)

      assert resolved(pipe) == 39

      :ok = PublishPipeline.offer(pipe, publication(40))
      release(started(40), ack(40))
      assert eventually(fn -> resolved(pipe) == 40 end)
    end

    test "re-opening an OPEN lane is refused rather than reseeding it" do
      # Reseeding would discard every outcome recorded since, silently moving the watermark
      # backwards on a lane the gateway has already reported progress for.
      p = pool(8, 4_000)
      pipe = open(pipeline(p, windowed_publisher(self())))

      assert {:error, :lane_already_open} = PublishPipeline.open_lane(pipe, @lane, 1)
    end

    test "lanes are DATA in one process, bounded by count and starting nothing" do
      # `nats-tenant-isolation` forbids a process per network scope, agent or partition. Opening
      # lanes must therefore add state and not children -- asserted on the pipeline's links, which
      # a per-lane process started by this module would show up in.
      p = pool(8, 4_000)
      pipe = pipeline(p, windowed_publisher(self()), max_lanes: 3)

      {:links, before} = Process.info(pipe, :links)

      for n <- 1..3 do
        assert :ok = PublishPipeline.open_lane(pipe, {@scope, "agent-#{n}", @spool}, 1)
      end

      assert %{lanes: 3} = PublishPipeline.stats(pipe)
      assert {:links, ^before} = Process.info(pipe, :links)

      # AND the count is bounded: "data rather than a process" must not become unbounded
      # retention instead.
      assert {:error, :lane_limit} =
               PublishPipeline.open_lane(pipe, {@scope, "agent-4", @spool}, 1)

      :ok = PublishPipeline.close_lane(pipe, {@scope, "agent-1", @spool})
      assert :ok = PublishPipeline.open_lane(pipe, {@scope, "agent-4", @spool}, 1)
    end

    test "a lane sequence outside the protobuf range is REFUSED, not raised" do
      # `ResolvedPrefix.new/1` GUARDS on the uint64 range rather than refusing it, so an unchecked
      # value raises inside this GenServer -- killing the process and every OTHER lane's prefix
      # with it. A refusable input must not be able to do that.
      p = pool(8, 4_000)
      pipe = pipeline(p, windowed_publisher(self()))

      for bad <- [0, -1, 0x1_0000_0000_0000_0000, :not_a_sequence, nil] do
        assert {:error, :first_unresolved_sequence} =
                 PublishPipeline.open_lane(pipe, @lane, bad),
               "open_lane accepted #{inspect(bad)}"
      end

      # ALIVE, and still usable: the refusals changed nothing.
      assert Process.alive?(pipe)
      assert %{lanes: 0} = PublishPipeline.stats(pipe)
      assert :ok = PublishPipeline.open_lane(pipe, @lane, 1)
    end

    test "a publication with no usable slot is refused, and nothing is charged for it" do
      p = pool(8, 4_000)
      pipe = open(pipeline(p, windowed_publisher(self())))

      assert {:error, :slot} = PublishPipeline.offer(pipe, %{slot: %{}})
      assert {:error, :slot} = PublishPipeline.offer(pipe, %{})
      assert %{outstanding_frames: 0} = PublisherPool.capacity(p)
      assert %{queued: 0, inflight: 0} = PublishPipeline.stats(pipe)
    end
  end

  # How many publishes have been refused by the window so far. Drains the test mailbox, so it is
  # accumulated in the process dictionary rather than recounted.
  defp refusals_seen do
    receive do
      {:refused, _sequence} ->
        Process.put(:refusals, (Process.get(:refusals) || 0) + 1)
        refusals_seen()
    after
      0 -> Process.get(:refusals) || 0
    end
  end

  # How many publishes the pipeline still has outstanding. The sync point for an outcome whose
  # effect on the watermark is deliberately NOTHING -- an out-of-order ack behind a gap moves no
  # watermark, so waiting on `resolved_through` there would wait forever or pass vacuously.
  defp inflight(pipeline), do: PublishPipeline.stats(pipeline).inflight
end
