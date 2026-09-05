defmodule ServiceRadar.Edge.PublisherPoolHandoffTest do
  @moduledoc """
  The admission handoff: what happens when a caller never takes delivery of a reservation.

  `async: false` deliberately. These mutate `:publisher_pool_call_timeout_ms`, which is global
  application config; running them concurrently with anything else that admits would change that
  code's call timeout underneath it. The rest of the pool's tests stay async in
  `ServiceRadar.Edge.PublisherPoolTest`.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.PublisherPool
  alias ServiceRadar.Edge.PublishWindow

  defp k(seq), do: PublishWindow.key(<<0xA1>>, "agent-1", <<0xB2>>, seq, {:record, seq})

  defp pool(frames, bytes) do
    {:ok, pid} =
      PublisherPool.start_link(
        class: :bulk,
        frame_credits: frames,
        byte_credits: bytes,
        name: nil
      )

    # A lane is CLOSED until a transport registers, so every pool a test uses needs one. The
    # stand-in is a bare process: what the accountant binds to is its LIFETIME, not anything it
    # can do -- generation death is the signal, and a real Gnat connection is not needed to
    # produce it.
    transport = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(transport, :kill) end)
    {:ok, _generation} = PublisherPool.register_transport(pid, transport)
    Process.put({:transport, pid}, transport)

    pid
  end

  defp with_call_timeout(ms) do
    previous = Application.get_env(:serviceradar_core, :publisher_pool_call_timeout_ms)
    Application.put_env(:serviceradar_core, :publisher_pool_call_timeout_ms, ms)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:serviceradar_core, :publisher_pool_call_timeout_ms)
        v -> Application.put_env(:serviceradar_core, :publisher_pool_call_timeout_ms, v)
      end
    end)
  end

  # Waits until the suspended pool has actually RECEIVED the call, instead of assuming a sleep was
  # long enough. A fixed sleep here proves nothing: if the message had not arrived yet, the test
  # would exercise a different interleaving than the one it claims to.
  defp await_queued(pool, n) do
    assert eventually(fn ->
             match?(
               {:message_queue_len, len} when len >= n,
               Process.info(pool, :message_queue_len)
             )
           end),
           "the call never reached the suspended pool"
  end

  defp eventually(fun, tries \\ 200)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, tries - 1)
    end
  end

  describe "an admission the caller never received is revoked" do
    setup do
      with_call_timeout(50)
      :ok
    end

    test "a queued admission processed AFTER the caller gave up does not stay charged" do
      # GenServer.call/3 gives up, but OTP does not cancel the queued message: the pool goes on to
      # admit, charging a frame for a request that was never made. The caller does NOT die -- the
      # publisher catches that exit -- so nothing about caller liveness can recover it. Only the
      # caller's own revocation can, because only the caller knows it never published.
      p = pool(1, 100)

      :sys.suspend(p)
      task = Task.async(fn -> PublisherPool.admit(p, k(1), 50, 60_000) end)
      await_queued(p, 1)
      assert {:error, :pool_timeout} = Task.await(task, 5_000)
      :sys.resume(p)

      assert eventually(fn ->
               match?(%{outstanding_frames: 0, outstanding_bytes: 0}, PublisherPool.capacity(p))
             end),
             "the admission the caller never received stayed charged"

      assert {:ok, _} = PublisherPool.admit(p, k(2), 50, 60_000)
    end

    test "revoking a RETRY restores the reservation, it does not release it" do
      # THE TRAP. A retry adds no credits -- it re-arms a reservation that is still unresolved and
      # still owed a republish. Revoking it as though it had created the reservation released a
      # broker-ambiguous frame and let the lane publish past its grant.
      p = pool(1, 100)

      assert {:ok, first} = PublisherPool.admit(p, k(1), 50, 60_000)
      assert :ok = PublisherPool.attempt_failed(p, first)
      assert %{outstanding_frames: 1, outstanding_bytes: 50} = PublisherPool.capacity(p)

      :sys.suspend(p)
      task = Task.async(fn -> PublisherPool.admit(p, k(1), 50, 60_000) end)
      await_queued(p, 1)
      assert {:error, :pool_timeout} = Task.await(task, 5_000)
      :sys.resume(p)

      # Still charged: the record was never resolved, so its credits must not come back. Waited on
      # the pool draining the revocation, not on a fixed sleep.
      assert eventually(fn ->
               match?({:message_queue_len, 0}, Process.info(p, :message_queue_len))
             end)

      assert %{outstanding_frames: 1, outstanding_bytes: 50} = PublisherPool.capacity(p),
             "revoking a retry released a reservation that was still unresolved"

      # ...and it is retryable again, i.e. the attempt state was restored rather than left live.
      assert {:ok, retry} = PublisherPool.admit(p, k(1), 50, 60_000)
      assert :ok = PublisherPool.settle(p, retry, :primary_publication)
      assert %{outstanding_frames: 0} = PublisherPool.capacity(p)
    end

    test "a caller that dies BEFORE the handoff leaves no phantom charge" do
      # Publication cannot happen before admit/4 returns, so a caller that dies while its
      # admission is still queued cannot have published. That is what authorises releasing here,
      # where caller death in general authorises nothing.
      p = pool(1, 100)

      :sys.suspend(p)
      caller = spawn(fn -> PublisherPool.admit(p, k(1), 50, 60_000) end)
      ref = Process.monitor(caller)
      await_queued(p, 1)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^ref, :process, ^caller, _}
      :sys.resume(p)

      assert eventually(fn ->
               match?(%{outstanding_frames: 0, outstanding_bytes: 0}, PublisherPool.capacity(p))
             end),
             "a caller that died before taking delivery left a phantom charge"
    end
  end

  describe "bookkeeping is bounded" do
    setup do
      with_call_timeout(5_000)
      :ok
    end

    test "a hundred retries of ONE record do not accumulate pending state" do
      # Retained memory must be bounded by the frame grant, not by how many times a record has
      # been retried. Pending entries used to live for the life of the reservation, so a record
      # retried a hundred times carried a hundred of them.
      p = pool(1, 100)

      reservation =
        Enum.reduce(1..100, nil, fn _i, _acc ->
          {:ok, res} = PublisherPool.admit(p, k(1), 50, 60_000)
          :ok = PublisherPool.attempt_failed(p, res)
          res
        end)

      assert %{outstanding_frames: 1, outstanding_bytes: 50} = PublisherPool.capacity(p)

      # The pool's own state, not a proxy for it.
      assert %{pending: pending} = :sys.get_state(p)

      assert map_size(pending) === 0,
             "pending admissions accumulated across retries: #{map_size(pending)}"

      # MONITORS TOO. Each admission monitors its caller until the handoff is confirmed; a leak
      # there grows outside the frame bound just as pending entries would, and is invisible to a
      # check that only looks at the map.
      {:monitors, monitors} = Process.info(p, :monitors)

      # The accountant permanently monitors its TRANSPORT -- that is how generation death is
      # detected -- so the bound is not "no monitors" but "no monitor that grows with retries".
      # Naming the expected one keeps this a real bound instead of a loosened count.
      assert monitors === [{:process, Process.get({:transport, p})}],
             "monitors leaked across retries: #{inspect(monitors)}"

      # NOT VACUOUS, but not by racing the confirmation: an admission is confirmed by a cast from
      # the same process, so by the time this test can observe anything the entry is already gone.
      # What proves the map is really used is that REVOCATION works at all -- it can only find an
      # admission through `pending` -- which the revocation tests above exercise directly.
      assert Map.has_key?(:sys.get_state(p), :pending)

      # The loop ended on attempt_failed, so this reservation has no live attempt: there is
      # nothing to settle, and the credits are still held awaiting the next retry.
      assert {:error, :not_outstanding} =
               PublisherPool.settle(p, reservation, :primary_publication)

      assert %{outstanding_frames: 1} = PublisherPool.capacity(p)
    end
  end

  describe "the PubAck deadline starts when the pool admits" do
    setup do
      with_call_timeout(5_000)
      :ok
    end

    test "time spent queued for the pool is not deducted from the ack interval" do
      # The deadline measures how long a PubAck may take. Stamped by the CALLER before the call,
      # every millisecond spent queued for a contended pool came out of that interval -- so a busy
      # lane silently shortened every ack window, and could report a frame expired before its
      # request had even been sent.
      p = pool(1, 100)
      ack_window = 30_000

      :sys.suspend(p)
      task = Task.async(fn -> PublisherPool.admit(p, k(1), 50, ack_window) end)
      await_queued(p, 1)

      Process.sleep(300)

      # The pool cannot admit before this instant, so a deadline it stamps itself is necessarily
      # at least `resumed_at + ack_window`. That replaces a 200ms scheduling budget which could
      # fail correct code on a slow VM.
      #
      # WHAT THIS DOES AND DOES NOT ESTABLISH, stated because an earlier claim overreached: it
      # catches the defect it exists for -- a deadline stamped by the CALLER, which here loses the
      # ~300ms of queue time this test injects. It does NOT prove the arithmetic exactly. A
      # deadline stamped one millisecond early still satisfies this whenever the pool begins
      # handling at least a millisecond after `resumed_at`, which is usual. Proving exactness
      # would need the clock injected into the pool; the queue-time property is what is asserted
      # here.
      resumed_at = System.monotonic_time(:millisecond)
      :sys.resume(p)
      assert {:ok, _res} = Task.await(task, 5_000)

      assert %{outstanding_frames: 1} = PublisherPool.capacity(p)

      [{_key, {_bytes, deadline, _attempt}}] = Map.to_list(:sys.get_state(p).window.outstanding)

      assert deadline >= resumed_at + ack_window,
             "the ack interval was charged for time queued: deadline is " <>
               "#{resumed_at + ack_window - deadline}ms before resume + window"
    end
  end

  describe "the pool does not activate at admission" do
    setup do
      with_call_timeout(5_000)
      :ok
    end

    test "an admission is PROVISIONAL in the pool's own state until confirmed" do
      # Calls the server directly, bypassing PublisherPool.admit/4 -- that function confirms the
      # handoff for you, so through it the provisional phase is never observable. This is what
      # makes premature activation in admit_reply/5 visible: a pure-window test cannot see it,
      # because the window is only ever asked to activate BY the pool.
      p = pool(2, 200)

      assert {:ok, {key, token}} =
               GenServer.call(p, {:admit, k(1), 50, 60_000, make_ref()}, 5_000)

      assert %{^key => {50, _deadline, attempt}} = :sys.get_state(p).window.outstanding

      assert match?(
               {:pending, ^token, owner, gen} when owner === self() and is_reference(gen),
               attempt
             ),
             "the pool activated the attempt at admission: #{inspect(attempt)}"

      # While provisional it is inert, so nothing can take the slot from the caller that is about
      # to receive it.
      assert PublisherPool.expired(p) === []
      assert {:error, :not_outstanding} = PublisherPool.attempt_failed(p, {key, token})
      assert {:error, :attempt_in_flight} = PublisherPool.admit(p, k(1), 50, 60_000)

      # NOT VACUOUS: the ordinary client path, which DOES confirm, leaves an ACTIVE attempt -- so
      # the assertion above is about the phase and not about a field that is always :pending.
      assert {:ok, {key2, token2}} = PublisherPool.admit(p, k(2), 50, 60_000)

      assert eventually(fn ->
               match?(
                 {_bytes, _deadline, {:active, ^token2, _owner, _gen}},
                 :sys.get_state(p).window.outstanding[key2]
               )
             end),
             "the confirmed handoff never activated"
    end
  end

  describe "the pool takes the owner from the CALL, not from the caller's word" do
    setup do
      with_call_timeout(5_000)
      :ok
    end

    test "holding the reservation is not enough -- one process cannot end another's attempt" do
      # The owner is `from`, so there is no parameter for a caller to lie in. This is what stops
      # a sweep, a supervisor, or any other holder of the tuple from freeing a live request.
      p = pool(1, 100)
      parent = self()

      owner =
        spawn_link(fn ->
          {:ok, res} = PublisherPool.admit(p, k(1), 50, 60_000)
          send(parent, {:reservation, res})

          receive do
            :settle ->
              send(parent, {:settled, PublisherPool.settle(p, res, :primary_publication)})
          end
        end)

      assert_receive {:reservation, res}, 5_000

      assert {:error, :not_outstanding} = PublisherPool.settle(p, res, :primary_publication)
      assert {:error, :not_outstanding} = PublisherPool.attempt_failed(p, res)

      assert %{outstanding_frames: 1, outstanding_bytes: 50} = PublisherPool.capacity(p),
             "a non-owner released a frame that was still in flight"

      # NOT VACUOUS: the same settlement from the owner works.
      send(owner, :settle)
      assert_receive {:settled, :ok}, 5_000
      assert %{outstanding_frames: 0, outstanding_bytes: 0} = PublisherPool.capacity(p)
    end
  end
end
