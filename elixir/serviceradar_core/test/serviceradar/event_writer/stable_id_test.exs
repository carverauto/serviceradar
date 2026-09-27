defmodule ServiceRadar.EventWriter.StableIdTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.StableId

  test "the same name always yields the same version-5 UUID, and different names differ" do
    id = StableId.uuid("log:seq:events:42:0")

    assert id == StableId.uuid("log:seq:events:42:0")
    refute id == StableId.uuid("log:seq:events:42:1")
    assert {:ok, uuid} = Ecto.UUID.load(id)
    assert String.at(uuid, 14) == "5"
  end

  test "a message's identity is its Nats-Msg-Id, in either header shape" do
    assert StableId.message_identity(%{headers: [{"Nats-Msg-Id", "evt-1"}]}) == "msg:evt-1"
    assert StableId.message_identity(%{headers: %{"nats-msg-id" => "evt-1"}}) == "msg:evt-1"
  end

  test "without a Nats-Msg-Id it is the stream position; without either it is nil" do
    ack = %{stream: "events", stream_sequence: 42}

    assert StableId.message_identity(%{headers: [], jetstream_ack: ack}) == "seq:events:42"
    assert StableId.message_identity(%{headers: [], jetstream_ack: nil}) == nil
    assert StableId.message_identity(%{}) == nil
  end
end
