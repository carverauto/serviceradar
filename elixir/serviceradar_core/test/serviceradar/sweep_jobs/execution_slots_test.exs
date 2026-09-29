defmodule ServiceRadar.SweepJobs.ExecutionSlotsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.ExecutionSlots

  describe "mint_id/1" do
    test "is a UUIDv7 whose time is the slot start" do
      slot_start = ~U[2026-10-01 12:30:15.250Z]

      raw = slot_start |> ExecutionSlots.mint_id() |> Ecto.UUID.dump!()

      assert <<ms::48, 7::4, _rand_a::12, 2::2, _rand_b::62>> = raw
      assert ms == DateTime.to_unix(slot_start, :millisecond)
    end

    test "mints a different id each time for the same slot" do
      slot_start = ~U[2026-10-01 12:30:15.250Z]

      refute ExecutionSlots.mint_id(slot_start) == ExecutionSlots.mint_id(slot_start)
    end

    test "orders by slot time" do
      earlier = ExecutionSlots.mint_id(~U[2026-10-01 12:00:00Z])
      later = ExecutionSlots.mint_id(~U[2026-10-01 12:05:00Z])

      assert earlier < later
    end
  end

  test "a slot whose window does not end after it starts is refused before anything is built" do
    assignment = %ServiceRadar.SweepJobs.SweepProducerAssignment{}
    at = ~U[2026-10-01 12:00:00Z]

    assert {:error, :invalid_window} = ExecutionSlots.schedule(assignment, at, at, [])

    assert {:error, :invalid_window} =
             ExecutionSlots.schedule(assignment, at, DateTime.add(at, -1), [])
  end
end
