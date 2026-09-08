defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalMutationLockTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalMutationLock
  alias ServiceRadar.TestSupport.CanonicalMutationLockRepo

  @moduletag :db_free

  setup do
    on_exit(fn -> Process.delete({CanonicalMutationLockRepo, :query_result}) end)
    :ok
  end

  test "runs the canonical mutation while the shared advisory lock is available" do
    set_lock_result(true)

    assert {:ok, :written} =
             CanonicalMutationLock.try_run(
               fn ->
                 send(self(), :mutation_ran)
                 :written
               end,
               repo: CanonicalMutationLockRepo,
               timeout: 12_345
             )

    assert_received {:lock_transaction, [timeout: 12_345]}

    assert_received {:lock_query, "SELECT pg_try_advisory_xact_lock($1)", [1_104_202_506]}

    assert_received :mutation_ran
  end

  test "returns the caller's busy result without running a competing mutation" do
    set_lock_result(false)

    assert {:ok, {:skipped, :canonical_mutation_in_progress}} =
             CanonicalMutationLock.try_run(
               fn -> flunk("busy canonical mutation must not run") end,
               repo: CanonicalMutationLockRepo,
               busy_result: {:skipped, :canonical_mutation_in_progress}
             )
  end

  test "rolls back when advisory lock acquisition fails" do
    reason = %Postgrex.Error{message: "connection unavailable"}
    Process.put({CanonicalMutationLockRepo, :query_result}, {:error, reason})

    assert {:error, ^reason} =
             CanonicalMutationLock.try_run(fn -> :unreachable end,
               repo: CanonicalMutationLockRepo
             )
  end

  test "rolls back an unexpected advisory lock response" do
    Process.put(
      {CanonicalMutationLockRepo, :query_result},
      {:ok, %Postgrex.Result{rows: [[nil]]}}
    )

    assert {:error, :unexpected_lock_response} =
             CanonicalMutationLock.try_run(fn -> :unreachable end,
               repo: CanonicalMutationLockRepo
             )
  end

  defp set_lock_result(available?) when is_boolean(available?) do
    Process.put(
      {CanonicalMutationLockRepo, :query_result},
      {:ok, %Postgrex.Result{rows: [[available?]]}}
    )
  end
end
