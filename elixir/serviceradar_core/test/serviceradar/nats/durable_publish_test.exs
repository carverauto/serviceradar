defmodule ServiceRadar.NATS.DurablePublishTest do
  use ExUnit.Case, async: false

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

  defmodule CapturePublisher do
    @moduledoc false
    def publish(subject, body, opts) do
      send(ServiceRadar.NATS.DurablePublishTest, {:retried, subject, body, opts})
      :ok
    end
  end

  # A binary body (an encoded protobuf MetricBatch) must survive the JSON job args and be
  # republished byte for byte.
  test "a failed binary publish is retried with the exact bytes" do
    parent = self()
    body = <<10, 0, 255, 128, 0, 1>>

    assert {:ok, :enqueued} =
             DurablePublish.publish("metrics.sweep.sweep.sweep_host_available", body,
               msg_id: "f",
               in_transaction?: fn -> false end,
               publish: fn _subject, _body, _opts -> {:error, :timeout} end,
               enqueue: fn job ->
                 send(parent, {:enqueued, job.changes.args})
                 {:ok, job}
               end
             )

    assert_received {:enqueued, args}
    stored = args |> Jason.encode!() |> Jason.decode!()

    previous = Application.fetch_env(:serviceradar_core, :internal_telemetry_publisher)
    Application.put_env(:serviceradar_core, :internal_telemetry_publisher, CapturePublisher)
    Process.register(self(), __MODULE__)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:serviceradar_core, :internal_telemetry_publisher, value)

        :error ->
          Application.delete_env(:serviceradar_core, :internal_telemetry_publisher)
      end
    end)

    assert :ok = ServiceRadar.NATS.DurablePublishWorker.perform(%Oban.Job{args: stored})
    assert_received {:retried, "metrics.sweep.sweep.sweep_host_available", ^body, [msg_id: "f"]}
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

  test "returns {:error, :repo_unavailable} instead of raising when the repo is disabled" do
    previous_repo_enabled = Application.fetch_env(:serviceradar_core, :repo_enabled)
    Application.put_env(:serviceradar_core, :repo_enabled, false)

    on_exit(fn ->
      case previous_repo_enabled do
        {:ok, value} -> Application.put_env(:serviceradar_core, :repo_enabled, value)
        :error -> Application.delete_env(:serviceradar_core, :repo_enabled)
      end
    end)

    assert {:error, :repo_unavailable} =
             DurablePublish.publish("logs.internal.audit", "{}",
               msg_id: "e",
               publish: fn _subject, _body, _opts ->
                 flunk("must not publish when repo is unavailable")
               end
             )
  end
end
