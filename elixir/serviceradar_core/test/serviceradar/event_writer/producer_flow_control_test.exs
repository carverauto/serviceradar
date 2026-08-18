defmodule ServiceRadar.EventWriter.ProducerFlowControlTest do
  @moduledoc """
  Pure unit tests for the EventWriter producer's demand-based flow control.

  These exercise the GenStage callbacks directly (no NATS connection) to assert
  that the in-process buffer is bounded -- the regression that previously let the
  producer mailbox grow to 273k messages / 9.6GB refc binary and OOM-killed core.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Producer

  # A consumer reply_to subject so the producer treats it as a JetStream message
  # (the overflow NAK / drain paths are keyed on a non-empty reply_to).
  @reply_to "$JS.ACK.events.consumer.1.1.1.0.0"

  defp build_config(overrides) do
    base = %Config{
      enabled: false,
      nats: %{host: "localhost", port: 4222, tls: false},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      producer_name: nil,
      streams: [],
      consumer_pull_batch_size: 16,
      max_ack_pending: 8,
      processor_concurrency: 4,
      ack_wait_ns: 120_000_000_000,
      max_deliver: 5
    }

    struct(base, overrides)
  end

  defp init_state(config) do
    # init/1 sends itself :connect; drain it so it does not leak into later asserts.
    {:producer, state} = Producer.init(config)
    flush_mailbox()
    # Pretend we are connected without a real socket; conn=nil makes ack/nak a no-op.
    %{state | connected: true, conn: nil}
  end

  defp push_msg(state, body, subject \\ "events.test") do
    msg = %{body: body, topic: subject, reply_to: @reply_to, headers: %{}}

    {:noreply, emitted, new_state} =
      Producer.handle_info({:msg, msg}, state)

    {emitted, new_state}
  end

  defp push_n(state, n) do
    Enum.reduce(1..n, {[], state}, fn i, {_emitted, acc_state} ->
      push_msg(acc_state, "payload-#{i}")
    end)
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp attach_telemetry(events) do
    handler_id = "producer-flow-control-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "max_buffered/1" do
    test "derives the producer buffer ceiling from per-consumer max_ack_pending" do
      assert Producer.max_buffered(build_config(max_ack_pending: 256)) == 512
    end

    test "never drops below the floor" do
      assert Producer.max_buffered(build_config(max_ack_pending: 1)) == 64
    end

    test "falls back to the config default when max_ack_pending is nil" do
      assert Producer.max_buffered(build_config(max_ack_pending: nil)) ==
               max(64, Config.default_max_ack_pending())
    end
  end

  describe "in-flight buffer is capped at the configured bound" do
    test "buffer never exceeds max_buffered no matter how many messages are pushed" do
      attach_telemetry([
        [:serviceradar, :event_writer, :producer, :queue],
        [:serviceradar, :event_writer, :producer, :overflow]
      ])

      # max_ack_pending: 8 -> max_buffered = max(64, 16) = 64
      config = build_config(max_ack_pending: 8)
      state = init_state(config)
      bound = state.max_buffered

      # Push 10x the bound with zero downstream demand: a broken pipeline would
      # buffer all of them. The fix caps the buffer at `bound`.
      {emitted, state} = push_n(state, bound * 10)

      assert emitted == []
      assert state.pending_count == bound
      assert :queue.len(state.pending_messages) == bound
      # Everything beyond the bound was NAK'd back to the server, not retained.
      assert state.dropped_overflow == bound * 10 - bound

      assert_receive {:telemetry, [:serviceradar, :event_writer, :producer, :queue],
                      %{queue_depth: ^bound, demand: 0, pull_inflight: 0},
                      %{operation: :enqueue, subject_class: "events"}}

      assert_receive {:telemetry, [:serviceradar, :event_writer, :producer, :overflow],
                      %{count: 1}, %{max_buffered: ^bound}}

      assert_receive {:telemetry, [:serviceradar, :event_writer, :producer, :queue],
                      %{queue_depth: ^bound}, %{operation: :overflow, subject_class: "events"}}
    end

    test "demand drains the buffer and re-opens capacity for new pushes" do
      config = build_config(max_ack_pending: 8)
      state = init_state(config)
      bound = state.max_buffered

      {[], state} = push_n(state, bound)
      assert state.pending_count == bound

      # Broadway asks for half the buffer.
      take = div(bound, 2)
      {:noreply, drained, state} = Producer.handle_demand(take, state)

      assert length(drained) == take
      assert state.pending_count == bound - take

      # New pushes are accepted again up to the bound (no overflow yet).
      {[], state} = push_n(state, take)
      assert state.pending_count == bound
    end

    test "preserves FIFO arrival order when draining" do
      config = build_config(max_ack_pending: 8)
      state = init_state(config)

      {[], state} = push_n(state, 5)
      {:noreply, drained, _state} = Producer.handle_demand(5, state)

      bodies = Enum.map(drained, & &1.data)
      assert bodies == ["payload-1", "payload-2", "payload-3", "payload-4", "payload-5"]
    end

    test "messages arriving under standing demand are emitted immediately, not buffered" do
      config = build_config(max_ack_pending: 8)
      state = init_state(config)

      # Standing demand of 3.
      {:noreply, [], state} = Producer.handle_demand(3, state)
      assert state.demand == 3

      {emitted, state} = push_msg(state, "live")
      assert Enum.map(emitted, & &1.data) == ["live"]
      assert state.pending_count == 0
      assert state.demand == 2
    end

    test "emitted messages include JetStream delivery metadata and max_deliver" do
      config =
        build_config(
          max_ack_pending: 8,
          streams: [
            %{
              name: "EVENTS",
              stream_name: "events",
              subject: "events.>",
              consumer_max_deliver: 9
            }
          ]
        )

      state = init_state(config)

      {:noreply, [], state} = Producer.handle_demand(1, state)
      {[message], _state} = push_msg(state, "live")

      assert message.metadata.jetstream_ack == %{
               stream: "events",
               consumer: "consumer",
               delivery_count: 1,
               stream_sequence: 1,
               consumer_sequence: 1,
               timestamp: 0,
               pending: 0
             }

      assert message.metadata.max_deliver == 9
    end

    test "max_deliver resolution uses subject filters when streams share a JetStream stream" do
      config =
        build_config(
          max_ack_pending: 8,
          streams: [
            %{
              name: "EVENTS",
              stream_name: "events",
              subject: "events.>",
              consumer_max_deliver: 9
            },
            %{
              name: "ANALYTICS_PREDICTIONS",
              stream_name: "events",
              subject: "signals.analytics.predictions.>",
              consumer_max_deliver: 3
            }
          ]
        )

      state = init_state(config)

      {:noreply, [], state} = Producer.handle_demand(1, state)
      {[message], _state} = push_msg(state, "live", "signals.analytics.predictions.test")

      assert message.metadata.max_deliver == 3
    end

    test "max_deliver subject filter tail wildcard requires a trailing token" do
      config =
        build_config(
          max_ack_pending: 8,
          max_deliver: 11,
          streams: [
            %{
              name: "EVENTS",
              stream_name: "events",
              subject: "events.>",
              consumer_max_deliver: 3
            }
          ]
        )

      state = init_state(config)

      {:noreply, [], state} = Producer.handle_demand(1, state)
      {[message], _state} = push_msg(state, "live", "events")

      assert message.metadata.max_deliver == 11
    end

    test "pull request sizing is bounded by available demand and configured batch size" do
      assert Producer.pull_request_batch_size(0, 16) == 0
      assert Producer.pull_request_batch_size(3, 16) == 3
      assert Producer.pull_request_batch_size(100, 16) == 16

      assert Producer.pull_request_batch_size(100, nil) ==
               Config.default_consumer_pull_batch_size()
    end

    test "empty pull status clears in-flight accounting without emitting" do
      attach_telemetry([[:serviceradar, :event_writer, :producer, :queue]])

      config = build_config(max_ack_pending: 8)
      state = init_state(config)

      pull_subject = "_INBOX.serviceradar.event_writer.pull.test.metrics"

      state = %{
        state
        | pull_inflight: 8,
          pull_inflight_by_subject: %{pull_subject => 8},
          pull_subjects: MapSet.new([pull_subject])
      }

      {:noreply, emitted, state} =
        Producer.handle_info({:msg, %{body: "", topic: pull_subject, reply_to: nil}}, state)

      assert emitted == []
      assert state.pull_inflight == 0

      assert_receive {:telemetry, [:serviceradar, :event_writer, :producer, :queue],
                      %{queue_depth: 0, pull_inflight: 0},
                      %{operation: :pull_status, subject_class: "other"}}
    end
  end

  describe "pull inflight accounting keyed by sid" do
    test "exactly-full data batch clears inbox inflight via sid mapping" do
      pull_subject = "_INBOX.serviceradar.event_writer.pull.test.netflow"
      data_subject = "flows.raw.netflow"
      sid = 42
      batch = 4

      config =
        build_config(
          max_ack_pending: 64,
          pull_expires_ns: 1_000_000_000,
          consumer_pull_batch_size: batch,
          streams: [
            %{
              name: "NETFLOW_RAW",
              stream_name: "flows",
              subject: data_subject,
              consumer_pull_batch_size: batch
            }
          ]
        )

      state = init_state(config)

      # demand: 0 so messages buffer without calling JetstreamConsumerApi.repull
      state = %{
        state
        | demand: 0,
          pull_inflight: batch,
          pull_inflight_by_subject: %{pull_subject => batch},
          pull_subjects: MapSet.new([pull_subject]),
          sid_to_pull_subject: %{sid => pull_subject},
          consumer_context: %{
            consumers: [
              %{
                stream: "flows",
                durable: "test-consumer-NETFLOW_RAW",
                sid: sid,
                subject: data_subject,
                pull_subject: pull_subject,
                pull_batch_size: batch
              }
            ],
            pull_subjects: MapSet.new([pull_subject]),
            sid_to_pull_subject: %{sid => pull_subject}
          }
      }

      # Exactly-full batch: data msgs use original JetStream topic + Gnat sid,
      # with no trailing empty status. Inflight must clear via sid→inbox mapping.
      state =
        Enum.reduce(1..batch, state, fn i, acc ->
          msg = %{
            body: "payload-#{i}",
            topic: data_subject,
            reply_to: @reply_to,
            headers: %{},
            sid: sid
          }

          {:noreply, emitted, next} = Producer.handle_info({:msg, msg}, acc)
          assert emitted == []
          next
        end)

      assert state.pending_count == batch
      assert state.pull_inflight == 0
      assert state.pull_inflight_by_subject == %{}
      # outstanding > 0 guard must not block future pulls for this durable
      assert Map.get(state.pull_inflight_by_subject, pull_subject, 0) == 0
    end

    test "exactly-full batch without sid would stall if keyed only by topic" do
      # Documents the regression: decrementing by data topic leaves inbox inflight.
      pull_subject = "_INBOX.serviceradar.event_writer.pull.test.netflow"
      data_subject = "flows.raw.netflow"
      batch = 2

      config = build_config(max_ack_pending: 64, pull_expires_ns: 1_000_000_000)
      state = init_state(config)

      state = %{
        state
        | demand: 0,
          pull_inflight: batch,
          pull_inflight_by_subject: %{pull_subject => batch},
          pull_subjects: MapSet.new([pull_subject]),
          # Empty sid map forces fallback; with multi-key fallback uses topic.
          sid_to_pull_subject: %{},
          consumer_context: %{
            consumers: [],
            pull_subjects: MapSet.new([pull_subject]),
            sid_to_pull_subject: %{}
          }
      }

      # Single outstanding subject still resolves via the sole inflight key.
      state =
        Enum.reduce(1..batch, state, fn i, acc ->
          msg = %{
            body: "payload-#{i}",
            topic: data_subject,
            reply_to: @reply_to,
            headers: %{}
          }

          {:noreply, _, next} = Producer.handle_info({:msg, msg}, acc)
          next
        end)

      assert state.pull_inflight == 0
      assert state.pull_inflight_by_subject == %{}
    end

    test "empty status on no_wait shared producer does not immediate-repull" do
      pull_subject = "_INBOX.serviceradar.event_writer.pull.test.metrics"

      # Shared pipeline: pull_expires_ns 0 => no_wait path.
      config = build_config(max_ack_pending: 8, pull_expires_ns: 0)
      state = init_state(config)

      state = %{
        state
        | connected: true,
          demand: 16,
          pull_inflight: 8,
          pull_inflight_by_subject: %{pull_subject => 8},
          pull_subjects: MapSet.new([pull_subject]),
          conn: nil,
          consumer_context: %{
            consumers: [
              %{
                stream: "events",
                durable: "test-consumer-METRICS",
                sid: 7,
                subject: "metrics.>",
                pull_subject: pull_subject,
                pull_batch_size: 16
              }
            ],
            pull_subjects: MapSet.new([pull_subject]),
            sid_to_pull_subject: %{7 => pull_subject}
          }
      }

      {:noreply, emitted, state} =
        Producer.handle_info(
          {:msg, %{body: "", topic: pull_subject, reply_to: nil, sid: 7}},
          state
        )

      assert emitted == []
      # Status cleared inflight but must NOT re-arm a no_wait pull (would
      # re-bump pull_inflight). Shared idle consumers wait for the 100ms tick.
      assert state.pull_inflight == 0
      assert state.pull_inflight_by_subject == %{}
    end
  end

  describe "setup failure cleanup" do
    test "safe_stop_conn unlinks before exit so caller is not killed" do
      # Spawn a linked child that traps exits poorly — the Producer path must
      # unlink Gnat before stopping it. We simulate with a plain process.
      parent = self()

      {:ok, child} =
        Task.start_link(fn ->
          receive do
            {:stop_me, reply_to} ->
              # Mimic setup failure cleanup from the parent side.
              send(reply_to, :child_alive_before)

              receive do
                :go -> :ok
              end
          end
        end)

      # Parent is linked to child. Stopping child with :kill without unlink kills parent.
      # __safe_stop_conn_for_test__ must unlink first.
      send(child, {:stop_me, parent})
      assert_receive :child_alive_before, 500

      # Should not kill this test process.
      assert Process.alive?(child)
      assert :ok = Producer.__safe_stop_conn_for_test__(child)

      # Allow the DOWN to settle.
      Process.sleep(50)
      refute Process.alive?(child)
      assert Process.alive?(self())
    end

    test "durable_source_name drives durable_name for drain consumers" do
      # Config.durable_name must match the pre-cutover events durable.
      assert Config.durable_name("serviceradar-event-writer", "NETFLOW_RAW") ==
               "serviceradar-event-writer-netflow-raw"

      # Drain stream names differ for pull-inbox uniqueness only.
      assert Config.durable_name("serviceradar-event-writer", "NETFLOW_RAW_EVENTS_DRAIN") !=
               Config.durable_name("serviceradar-event-writer", "NETFLOW_RAW")
    end
  end

  describe "stale pull-inflight expiry" do
    @stale_netflow "_INBOX.serviceradar.event_writer.pull.test.netflow_raw"
    @fresh_sflow "_INBOX.serviceradar.event_writer.pull.test.sflow_raw"

    test "long-poll timeout is pull_expires plus slack" do
      assert Producer.stale_pull_timeout_ms(build_config(pull_expires_ns: 2_000_000_000)) ==
               7_000
    end

    test "no_wait timeout is the shared-pipeline deadline" do
      assert Producer.stale_pull_timeout_ms(build_config(pull_expires_ns: 0)) == 5_000
      assert Producer.stale_pull_timeout_ms(build_config(pull_expires_ns: nil)) == 5_000
    end

    test "fetch expires lost long-polls so a durable can pull again" do
      attach_telemetry([[:serviceradar, :event_writer, :producer, :stale_pull]])

      config = build_config(max_ack_pending: 64, pull_expires_ns: 2_000_000_000)
      now = 50_000
      timeout = Producer.stale_pull_timeout_ms(config)

      state =
        config
        |> init_state()
        |> Map.merge(%{
          demand: 0,
          pull_inflight: 26,
          pull_inflight_by_subject: %{@stale_netflow => 4, @fresh_sflow => 22},
          pull_inflight_started_at: %{
            @stale_netflow => now - timeout - 1,
            @fresh_sflow => now - 10
          },
          pull_subjects: MapSet.new([@stale_netflow, @fresh_sflow])
        })

      {:noreply, emitted, state} = Producer.handle_info({:fetch, now}, state)

      assert emitted == []
      assert state.pull_inflight == 22
      assert state.pull_inflight_by_subject == %{@fresh_sflow => 22}
      assert Map.get(state.pull_inflight_started_at, @stale_netflow) == nil
      assert Map.get(state.pull_inflight_started_at, @fresh_sflow) == now - 10
      assert Map.get(state.pull_inflight_by_subject, @stale_netflow, 0) == 0

      assert_receive {:telemetry, [:serviceradar, :event_writer, :producer, :stale_pull],
                      %{count: 1, expired_inflight: 4, age_ms: age_ms}, %{subject_class: "other"}}

      assert age_ms > timeout
    end

    test "fetch does not expire a pull that is still within the deadline" do
      config = build_config(max_ack_pending: 8, pull_expires_ns: 2_000_000_000)
      now = 20_000

      state =
        config
        |> init_state()
        |> Map.merge(%{
          demand: 0,
          pull_inflight: 8,
          pull_inflight_by_subject: %{@stale_netflow => 8},
          pull_inflight_started_at: %{@stale_netflow => now - 100},
          pull_subjects: MapSet.new([@stale_netflow])
        })

      {:noreply, [], state} = Producer.handle_info({:fetch, now}, state)

      assert state.pull_inflight == 8
      assert state.pull_inflight_by_subject == %{@stale_netflow => 8}
    end

    test "empty status clears started_at so a later pull is not treated as stale" do
      config = build_config(max_ack_pending: 8, pull_expires_ns: 2_000_000_000)
      now = 10_000

      state =
        config
        |> init_state()
        |> Map.merge(%{
          pull_inflight: 8,
          pull_inflight_by_subject: %{@stale_netflow => 8},
          pull_inflight_started_at: %{@stale_netflow => now - 100},
          pull_subjects: MapSet.new([@stale_netflow])
        })

      {:noreply, [], state} =
        Producer.handle_info(
          {:msg, %{body: "", topic: @stale_netflow, reply_to: nil}},
          state
        )

      assert state.pull_inflight == 0
      assert state.pull_inflight_by_subject == %{}
      assert state.pull_inflight_started_at == %{}
    end
  end
end
