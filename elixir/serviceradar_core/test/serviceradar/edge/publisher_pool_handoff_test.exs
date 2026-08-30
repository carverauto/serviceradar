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
      assert {:error, :pool_timeout} = Task.await(task, 5_000)
      :sys.resume(p)

      # Still charged: the record was never resolved, so its credits must not come back.
      Process.sleep(50)

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
      Process.sleep(20)
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

      :sys.suspend(p)
      task = Task.async(fn -> PublisherPool.admit(p, k(1), 50, 200) end)

      # Queued for far longer than the 200ms ack window the caller asked for.
      Process.sleep(400)
      :sys.resume(p)
      assert {:ok, _res} = Task.await(task, 5_000)

      # Stamped before the call, this reservation would already be expired on arrival.
      assert PublisherPool.expired(p) === [],
             "the ack interval was consumed by time spent waiting for the pool"
    end
  end
end
