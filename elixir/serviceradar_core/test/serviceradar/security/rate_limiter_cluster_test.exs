defmodule ServiceRadar.Security.RateLimiterClusterTest do
  @moduledoc """
  Multi-node tests for `ServiceRadar.Security.RateLimiter`.

  Brings up a 3-node `:peer` cluster, joins them via `Node.connect/1`,
  and exercises the Horde-discovered peer-broadcast convergence path.
  These tests are skipped when distribution cannot be enabled (e.g.,
  the test runner is not started as a distributed node).
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Security.RateLimiter

  @moduletag :cluster

  setup_all do
    case ensure_distributed_node() do
      :ok ->
        :ok

      {:error, reason} ->
        # Skip the suite if distribution cannot be enabled in this env.
        IO.puts("Skipping cluster tests: #{inspect(reason)}")
        :ignore
    end
  end

  setup do
    :ets.delete_all_objects(RateLimiter.__table__())
    :ok
  end

  test "increments at different nodes converge in the local ETS table" do
    {peer_a, _node_a} = start_peer(:rl_peer_a)
    {peer_b, _node_b} = start_peer(:rl_peer_b)

    on_exit(fn ->
      :peer.stop(peer_a)
      :peer.stop(peer_b)
    end)

    bucket = :cluster_test
    key = "shared-#{:rand.uniform(1_000_000)}"

    # Record at peer A
    :ok = rpc(peer_a, RateLimiter, :record, [bucket, key, [limit: 100, window_seconds: 60]])
    # Record at peer B
    :ok = rpc(peer_b, RateLimiter, :record, [bucket, key, [limit: 100, window_seconds: 60]])
    # Record locally
    :ok = RateLimiter.record(bucket, key, limit: 100, window_seconds: 60)

    # Allow broadcasts to settle.
    Process.sleep(100)

    # Each node should now have 3 attempts for this key.
    for node <- [peer_a, peer_b] do
      [{_, attempts}] =
        rpc(node, :ets, :lookup, [RateLimiter.__table__(), {bucket, key}])

      assert length(attempts) == 3,
             "expected 3 attempts on #{inspect(node)}, got #{length(attempts)}"
    end

    [{_, local_attempts}] = :ets.lookup(RateLimiter.__table__(), {bucket, key})
    assert length(local_attempts) == 3
  end

  test "a joining node bootstraps state from a peer snapshot" do
    {peer_a, _node_a} = start_peer(:rl_peer_seed)

    bucket = :snapshot_test
    key = "seeded-#{:rand.uniform(1_000_000)}"

    # Build up state at peer A before B joins.
    Enum.each(1..5, fn _ ->
      :ok = rpc(peer_a, RateLimiter, :record, [bucket, key, [limit: 100, window_seconds: 60]])
    end)

    Process.sleep(50)

    # Now start a third peer; it should bootstrap from A.
    {peer_b, _node_b} = start_peer(:rl_peer_late)

    on_exit(fn ->
      :peer.stop(peer_a)
      :peer.stop(peer_b)
    end)

    # Give the new peer's :nodeup handler time to run and merge the snapshot.
    Process.sleep(500)

    [{_, attempts}] =
      rpc(peer_b, :ets, :lookup, [RateLimiter.__table__(), {bucket, key}])

    assert length(attempts) == 5,
           "expected joining peer to have 5 attempts, got #{length(attempts)}"
  end

  ## Helpers

  defp ensure_distributed_node do
    if Node.alive?() do
      :ok
    else
      case Node.start(:"rl_primary@127.0.0.1", :shortnames) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp start_peer(name) do
    {:ok, _peer, node} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        args: [
          ~c"-setcookie",
          to_charlist(:erlang.get_cookie())
        ]
      })

    # Configure code paths and start the application on the peer.
    :ok = :rpc.call(node, :code, :add_paths, [:code.get_path()])
    {:ok, _} = :rpc.call(node, Application, :ensure_all_started, [:serviceradar_core])

    {node, node}
  rescue
    e ->
      flunk("could not start peer #{inspect(name)}: #{inspect(e)}")
  end

  defp rpc(node, mod, fun, args) do
    case :rpc.call(node, mod, fun, args) do
      {:badrpc, reason} ->
        flunk("rpc to #{inspect(node)}.#{mod}.#{fun} failed: #{inspect(reason)}")

      result ->
        result
    end
  end
end
