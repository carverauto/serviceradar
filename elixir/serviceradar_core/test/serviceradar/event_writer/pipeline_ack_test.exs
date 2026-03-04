defmodule ServiceRadar.EventWriter.PipelineAckTest do
  use ExUnit.Case, async: true

  alias Broadway.Message
  alias ServiceRadar.EventWriter.Pipeline

  test "ack/3 invokes ack and nack callbacks" do
    parent = self()

    ack_message = %Message{
      data: "",
      metadata: %{subject: "events.test", reply_to: "$JS.ACK.test"},
      acknowledger:
        {Pipeline, :ack_ref,
         %{
           ack_fun: fn
             :ack ->
               send(parent, :acked)
               :ok

             :nack ->
               send(parent, :nacked)
               :ok
           end
         }}
    }

    assert :ok == Pipeline.ack(:ack_ref, [ack_message], [ack_message])
    assert_receive :acked
    assert_receive :nacked
  end

  test "ack/3 does not crash when ack callback exits" do
    message = %Message{
      data: "",
      metadata: %{subject: "falco.test", reply_to: "$JS.ACK.falco"},
      acknowledger:
        {Pipeline, :ack_ref,
         %{
           ack_fun: fn _action ->
             exit(:noprocess)
           end
         }}
    }

    assert :ok == Pipeline.ack(:ack_ref, [message], [message])
  end
end
