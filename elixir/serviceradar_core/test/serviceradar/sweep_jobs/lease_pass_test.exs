defmodule ServiceRadar.SweepJobs.LeasePassTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.LeasePass
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
end
