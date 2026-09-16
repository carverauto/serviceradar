defmodule ServiceRadar.Inventory.Sync.BatchExecutorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Sync.BatchExecutor

  test "serial batches retain the caller's transaction ownership and process state" do
    owner = self()
    marker = make_ref()
    Process.put(:synthetic_transaction_owner, marker)

    assert :ok =
             BatchExecutor.run(
               [:first, :second, :third],
               fn batch ->
                 assert self() == owner
                 assert Process.get(:synthetic_transaction_owner) == marker
                 send(owner, {:processed, batch})
                 :ok
               end,
               1
             )

    assert_receive {:processed, :first}
    assert_receive {:processed, :second}
    assert_receive {:processed, :third}
  end

  test "serial failure stops later writes in the same transaction" do
    assert {:error, :synthetic_write_failure} =
             BatchExecutor.run(
               [:fail, :must_not_run],
               fn
                 :fail -> {:error, :synthetic_write_failure}
                 :must_not_run -> flunk("writes after a failed batch must not run")
               end,
               1
             )
  end

  test "ordinary multiple batches retain bounded parallel execution" do
    owner = self()

    assert :ok =
             BatchExecutor.run(
               [:first, :second],
               fn batch ->
                 send(owner, {:worker, batch, self()})
                 :ok
               end,
               2
             )

    assert_receive {:worker, :first, first}
    assert_receive {:worker, :second, second}
    assert first != owner and second != owner and first != second
  end

  test "a single ordinary batch still runs in the caller" do
    owner = self()

    assert :ok =
             BatchExecutor.run(
               [:only],
               fn :only ->
                 assert self() == owner
                 :ok
               end,
               4
             )
  end

  test "deferred batch effects retain input order and caller transaction ownership" do
    owner = self()

    assert {:ok, [%{batch: :first}, %{batch: :second}]} =
             BatchExecutor.collect([:first, :second], fn batch ->
               assert self() == owner
               {:ok, %{batch: batch}}
             end)

    assert {:ok, []} = BatchExecutor.collect([], fn _ -> flunk("no empty batch") end)
  end

  test "a failed deferred batch discards earlier effects and stops later batches" do
    assert {:error, :synthetic_write_failure} =
             BatchExecutor.collect([:first, :fail, :must_not_run], fn
               :first -> {:ok, %{batch: :first}}
               :fail -> {:error, :synthetic_write_failure}
               :must_not_run -> flunk("writes after a failed batch must not run")
             end)
  end
end
