defmodule ServiceRadar.SweepJobs.LeasePassTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.LeasePass
  alias ServiceRadar.SweepJobs.LeaseSchedule
  alias ServiceRadar.SweepJobs.SweepProducerAssignment

  @id "0192a4a0-0005-7000-8000-000000000005"

  test "a lease id is a version 8 UUID fixed by the assignment and its epoch" do
    at_one = LeasePass.lease_id(%SweepProducerAssignment{id: @id, authority_epoch: 1})

    assert at_one == LeasePass.lease_id(%SweepProducerAssignment{id: @id, authority_epoch: 1})
    assert <<_::48, 8::4, _::12, 2::2, _::62>> = Ecto.UUID.dump!(at_one)

    refute at_one == LeasePass.lease_id(%SweepProducerAssignment{id: @id, authority_epoch: 2})

    refute at_one ==
             LeasePass.lease_id(%SweepProducerAssignment{
               id: "0192a4a0-0006-7000-8000-000000000006",
               authority_epoch: 1
             })
  end

  test "a failed scope or settings read is not a decision to drop the lease" do
    now = ~U[2026-01-01 00:00:00Z]
    schedule = {:interval, 900}
    on = {:ok, %{enabled?: true, horizon_seconds: 3_600}}
    off = {:ok, %{enabled?: false, horizon_seconds: 3_600}}

    assert :not_leased =
             LeasePass.classify_lease(
               {:error, :partition_not_found},
               {:error, :timeout},
               schedule,
               now
             )

    assert {:failed, :timeout} =
             LeasePass.classify_lease({:error, :timeout}, :unread, schedule, now)

    assert {:failed, :unavailable} =
             LeasePass.classify_lease({:ok, "scope-1"}, {:error, :unavailable}, schedule, now)

    assert :not_leased = LeasePass.classify_lease({:ok, "scope-1"}, off, schedule, now)

    assert {:leased, %{scope_id: "scope-1", slots: [_ | _]}} =
             LeasePass.classify_lease({:ok, "scope-1"}, on, schedule, now)

    assert {:ok, cron} =
             LeaseSchedule.parse(%{schedule_type: :cron, cron_expression: "* * * * *"})

    assert :not_leased = LeasePass.classify_lease({:ok, "scope-1"}, on, cron, now)
  end
end
