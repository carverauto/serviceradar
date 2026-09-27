defmodule ServiceRadar.NATS.DurablePublishTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NATS.DurablePublish

  defp after_publish(parent) do
    fn on_published, body -> send(parent, {:after_publish, on_published, body}) end
  end

  test "a stored publish runs the post-publish work once and is not queued" do
    parent = self()

    assert :ok =
             DurablePublish.publish("events.internal.jobs", ~s({"id":"a"}),
               msg_id: "a",
               on_published: :northbound_handlers,
               in_transaction?: fn -> false end,
               publish: fn _subject, _body, opts ->
                 send(parent, {:publish, opts})
                 :ok
               end,
               enqueue: fn _job -> flunk("a stored publish must not be queued") end,
               after_publish: after_publish(parent)
             )

    assert_received {:publish, [msg_id: "a"]}
    assert_received {:after_publish, :northbound_handlers, ~s({"id":"a"})}
  end

  test "a failed publish is queued with everything needed to repeat it, and runs nothing yet" do
    parent = self()

    assert {:ok, :enqueued} =
             DurablePublish.publish("logs.internal.health", "{}",
               msg_id: "b",
               on_published: :northbound_handlers,
               in_transaction?: fn -> false end,
               publish: fn _subject, _body, _opts -> {:error, :timeout} end,
               enqueue: fn job ->
                 send(parent, {:enqueued, job.changes.args})
                 {:ok, job}
               end,
               after_publish: after_publish(parent)
             )

    assert_received {:enqueued,
                     %{
                       "subject" => "logs.internal.health",
                       "body" => "{}",
                       "msg_id" => "b",
                       "on_published" => "northbound_handlers"
                     }}

    refute_received {:after_publish, _, _}
  end

  test "a publish that can be neither stored nor queued is an error" do
    assert {:error, {:publish_and_enqueue_failed, :oban_unavailable}} =
             DurablePublish.publish("events.internal.jobs", "{}",
               msg_id: "c",
               in_transaction?: fn -> false end,
               publish: fn _subject, _body, _opts -> {:error, :timeout} end,
               enqueue: fn _job -> {:error, :oban_unavailable} end
             )
  end

  test "messages with no post-publish work run nothing" do
    assert :ok = DurablePublish.run_on_published(nil, "{}")
  end

  # A change that may still roll back must not be announced: inside a
  # transaction the message is only stored as the retry job, which commits
  # with the caller and publishes after commit.
  test "inside a transaction the message is queued with the caller, not published" do
    parent = self()

    assert {:ok, :enqueued} =
             DurablePublish.publish("events.internal.credential", "{}",
               msg_id: "d",
               on_published: :northbound_handlers,
               in_transaction?: fn -> true end,
               publish: fn _subject, _body, _opts ->
                 flunk("must not publish inside a transaction")
               end,
               enqueue: fn job ->
                 send(parent, {:enqueued, job.changes.args})
                 {:ok, job}
               end,
               after_publish: after_publish(parent)
             )

    assert_received {:enqueued, %{"msg_id" => "d", "on_published" => "northbound_handlers"}}
    refute_received {:after_publish, _, _}
  end
end
