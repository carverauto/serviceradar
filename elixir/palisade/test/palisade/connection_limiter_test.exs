defmodule Palisade.ConnectionLimiterTest do
  use ExUnit.Case, async: true

  alias Palisade.ConnectionLimiter

  setup context do
    name = :"#{inspect(__MODULE__)}.#{context.test}"
    start_supervised!({ConnectionLimiter, Keyword.merge([name: name], context[:limiter] || [])})
    %{limiter: name}
  end

  # A stand-in for a connection process that stays alive until told to stop.
  defp connection do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp stop(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    end
  end

  describe "per-key cap" do
    @describetag limiter: [max_active_per_key: 2]

    test "refuses a further connection until one of the key's processes exits", %{
      limiter: limiter
    } do
      [first, second, third] = for _ <- 1..3, do: connection()

      assert :ok = ConnectionLimiter.admit(limiter, :client, first)
      assert :ok = ConnectionLimiter.admit(limiter, :client, second)
      assert {:error, :max_active_per_key} = ConnectionLimiter.admit(limiter, :client, third)
      assert :ok = ConnectionLimiter.admit(limiter, :other, third)

      stop(first)

      assert :ok = ConnectionLimiter.admit(limiter, :client, third)
      assert ConnectionLimiter.active(limiter, :client) == 2
    end

    test "a crashed connection gives its slot back", %{limiter: limiter} do
      pid = spawn(fn -> receive do: (:crash -> exit(:boom)) end)
      ref = Process.monitor(pid)

      assert :ok = ConnectionLimiter.admit(limiter, :client, pid)
      assert ConnectionLimiter.active(limiter) == 1

      send(pid, :crash)
      assert_receive {:DOWN, ^ref, :process, ^pid, :boom}

      assert ConnectionLimiter.active(limiter) == 0
      assert ConnectionLimiter.active(limiter, :client) == 0
    end
  end

  describe "global cap" do
    @describetag limiter: [max_active: 2]

    test "applies across keys", %{limiter: limiter} do
      assert :ok = ConnectionLimiter.admit(limiter, :a, connection())
      assert :ok = ConnectionLimiter.admit(limiter, :b, connection())
      assert {:error, :max_active} = ConnectionLimiter.admit(limiter, :c, connection())
    end
  end

  describe "admission rate" do
    @describetag limiter: [max_admissions_per_key: 2, max_admissions: 3, window_ms: 60_000]

    test "is capped per key and overall, even after slots are released", %{limiter: limiter} do
      for _ <- 1..2 do
        pid = connection()
        assert :ok = ConnectionLimiter.admit(limiter, :client, pid)
        stop(pid)
      end

      assert {:error, :max_admissions_per_key} =
               ConnectionLimiter.admit(limiter, :client, connection())

      assert :ok = ConnectionLimiter.admit(limiter, :other, connection())
      assert {:error, :max_admissions} = ConnectionLimiter.admit(limiter, :third, connection())
    end
  end

  describe "tracked keys" do
    @describetag limiter: [max_tracked_keys: 1]

    test "admissions for new keys are refused when the rate table is full", %{limiter: limiter} do
      assert :ok = ConnectionLimiter.admit(limiter, :a, connection())
      assert {:error, :max_tracked_keys} = ConnectionLimiter.admit(limiter, :b, connection())
      assert :ok = ConnectionLimiter.admit(limiter, :a, connection())
    end
  end

  test "admitting the same owner twice holds one slot", %{limiter: limiter} do
    assert :ok = ConnectionLimiter.admit(limiter, :client)
    assert :ok = ConnectionLimiter.admit(limiter, :client)
    assert ConnectionLimiter.active(limiter, :client) == 1
  end

  test "release/2 frees the caller's slots early", %{limiter: limiter} do
    assert :ok = ConnectionLimiter.admit(limiter, :a)
    assert :ok = ConnectionLimiter.admit(limiter, :b)
    assert ConnectionLimiter.active(limiter) == 2

    assert :ok = ConnectionLimiter.release(limiter)

    assert ConnectionLimiter.active(limiter) == 0
  end

  test "start options are validated" do
    assert_raise ArgumentError, fn ->
      ConnectionLimiter.start_link(name: :palisade_bad_limiter, max_active: 0)
    end

    assert_raise ArgumentError, fn ->
      ConnectionLimiter.start_link(name: :palisade_bad_limiter, max_admissions: :lots)
    end
  end
end
