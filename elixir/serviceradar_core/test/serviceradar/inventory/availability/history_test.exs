defmodule ServiceRadar.Inventory.Availability.HistoryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Availability.History

  @transition %{
    "uid" => "sr:00000000-0000-4000-8000-000000000001",
    "from" => "available",
    "to" => "unavailable",
    "from_since" => "2026-01-01T00:00:00.000000Z",
    "changed_at" => "2026-01-01T06:00:00.000000Z",
    "decided_by" => %{
      "authority_class" => "managing_controller",
      "source_kind" => "camera",
      "reporter_agent_id" => "agent-test01",
      "rule" => "highest_class"
    },
    "conflict" => true
  }

  test "a transition becomes the record of the interval it closes" do
    assert History.record(@transition) == %{
             "device_uid" => "sr:00000000-0000-4000-8000-000000000001",
             "from_state" => "available",
             "from_since" => "2026-01-01T00:00:00.000000Z",
             "to_state" => "unavailable",
             "changed_at" => "2026-01-01T06:00:00.000000Z",
             "authority_class" => "managing_controller",
             "source_kind" => "camera",
             "reporter_agent_id" => "agent-test01",
             "rule" => "highest_class",
             "conflict" => true
           }
  end

  # The message id is the record's storage identity (device, decision time, new state), so
  # a republish dedups and a different change does not collide with it.
  test "the message id is stable for one change and distinct across changes" do
    record = History.record(@transition)

    assert History.msg_id(record) == History.msg_id(History.record(@transition))

    for change <- [
          %{@transition | "to" => "unknown"},
          %{@transition | "changed_at" => "2026-01-01T06:00:01.000000Z"},
          %{@transition | "uid" => "sr:00000000-0000-4000-8000-000000000002"}
        ] do
      refute History.msg_id(History.record(change)) == History.msg_id(record)
    end
  end

  test "publishing stops at the first record that can be neither published nor queued" do
    parent = self()
    second = %{@transition | "changed_at" => "2026-01-01T07:00:00.000000Z"}

    assert {:error, {:publish_and_enqueue_failed, :oban_unavailable}} =
             History.publish([@transition, second],
               in_transaction?: fn -> false end,
               publish: fn subject, body, opts ->
                 send(parent, {:published, subject, Jason.decode!(body), opts[:msg_id]})
                 {:error, :timeout}
               end,
               enqueue: fn _job -> {:error, :oban_unavailable} end
             )

    record = History.record(@transition)
    msg_id = History.msg_id(record)
    assert_received {:published, "availability.transitions.device", ^record, ^msg_id}
    refute_received {:published, _, _, _}
  end
end
