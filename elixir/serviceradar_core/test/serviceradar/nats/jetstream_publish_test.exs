defmodule ServiceRadar.NATS.JetStreamPublishTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NATS.JetStreamPublish

  defp replying(body) do
    fn subject, payload, opts ->
      send(self(), {:request, subject, payload, opts})
      {:ok, %{body: body}}
    end
  end

  test "succeeds only on a PubAck and sends the message id header" do
    request = replying(~s({"stream":"mtr_results","seq":7}))

    opts = [msg_id: "abc", request: request]

    assert :ok = JetStreamPublish.publish("mtr.results.ingest", "{}", opts)

    assert_received {:request, "mtr.results.ingest", "{}", opts}
    assert opts[:headers] == [{"Nats-Msg-Id", "abc"}]
    assert is_integer(opts[:receive_timeout])
  end

  test "a JetStream error reply is a failure" do
    request = replying(~s({"error":{"code":503,"description":"no stream"}}))

    assert {:error, {:jetstream, %{"code" => 503}}} =
             JetStreamPublish.publish("mtr.results.ingest", "{}", request: request)
  end

  test "an unexpected reply is a failure, not a success" do
    assert {:error, {:invalid_jetstream_ack, _}} =
             JetStreamPublish.publish("s", "{}", request: replying(~s({"ok":true})))
  end

  test "a request error is returned as is" do
    request = fn _subject, _payload, _opts -> {:error, :timeout} end

    assert {:error, :timeout} = JetStreamPublish.publish("s", "{}", request: request)
  end
end
