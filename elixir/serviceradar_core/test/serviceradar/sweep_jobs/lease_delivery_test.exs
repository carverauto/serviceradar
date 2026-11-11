defmodule ServiceRadar.SweepJobs.LeaseDeliveryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.LeaseDelivery

  # :global exclusion works between processes (each serialize call locks as its own
  # pid); a second serialize from the SAME process would re-enter, so the holder and
  # the contender must be different processes.
  test "a held delivery lock aborts try-once instead of waiting" do
    test_pid = self()
    group = Ecto.UUID.generate()

    holder =
      Task.async(fn ->
        LeaseDelivery.serialize(group, "agent-busy", fn ->
          send(test_pid, :lock_held)
          Process.sleep(500)
          :holder_done
        end)
      end)

    assert_receive :lock_held, 5_000

    assert :aborted =
             LeaseDelivery.serialize(group, "agent-busy", fn ->
               flunk("ran under a held delivery lock")
             end)

    assert :holder_done = Task.await(holder, 5_000)
  end

  test "a logic error inside the lock propagates instead of reading as busy" do
    group = Ecto.UUID.generate()

    assert_raise RuntimeError, "boom", fn ->
      LeaseDelivery.serialize(group, "agent-raise", fn -> raise "boom" end)
    end
  end
end
