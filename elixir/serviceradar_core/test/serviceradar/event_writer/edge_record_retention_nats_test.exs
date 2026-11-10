defmodule ServiceRadar.EventWriter.EdgeRecordRetentionNatsTest do
  @moduledoc """
  The edge-record source stream retention on a real, disposable JetStream broker.

  The source streams hold only records EventWriter has not written yet: `WorkQueue`
  retention removes a record when its owning durable ACKs it, so `DiscardNew`
  refuses new publishes only when the unwritten backlog fills `MaxBytes`. Under
  the previous `Limits` retention, ACKed records lingered until `MaxAge` and a
  caught-up consumer still filled the cap (demo held 918 MiB with nothing able
  to age out for 48h).
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.ConsumerReconciler
  alias ServiceRadar.EventWriter.EdgeRecordStreamCutover
  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.EventWriter.Producer
  alias ServiceRadar.NATS.JetstreamConsumer
  alias ServiceRadar.TestSupport.ExposureBroker

  @moduletag :db_free
  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  @stream "TELEMETRY_EDGE_RECORD_V1_BULK"
  @source_subject "telemetry.edge-record.v1.bulk.p07"

  defmodule AckSink do
    @moduledoc false
    # Stands in for the edge-record batcher whose projector succeeds: every delivery is
    # acknowledged through the pipeline's real ack callback once "written".
    use GenStage

    def start_link({producer, owner}), do: GenStage.start_link(__MODULE__, {producer, owner})

    @impl true
    def init({producer, owner}) do
      {:consumer, owner, subscribe_to: [{producer, max_demand: 4, min_demand: 0}]}
    end

    @impl true
    def handle_events(events, _from, owner) do
      Enum.each(events, fn event ->
        send(owner, {:acked, event.metadata.jetstream_ack.stream_sequence})

        event
        |> Pipeline.transform([])
        |> then(&Pipeline.ack(:ack_ref, [&1], []))
      end)

      {:noreply, [], owner}
    end
  end

  test "retention cannot change in place to or from workqueue, so upgrades cut over",
       ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, port ->
      config = config(port)

      legacy = %{
        production_shape()
        | stream_replicas: 1,
          stream_max_bytes: 16_777_216,
          stream_retention: "limits",
          stream_max_age: 86_400_000_000_000
      }

      assert :ok = ConsumerReconciler.ensure_stream(conn, config, legacy)

      assert %{"config" => %{"retention" => "limits"}} =
               api(conn, "STREAM.INFO.#{@stream}", "")

      # Records published before any durable exists are retained (the install case).
      for n <- 1..3 do
        assert %{"stream" => @stream, "seq" => ^n} = publish!(conn, "synthetic-install-#{n}")
      end

      workqueue = %{
        production_shape()
        | stream_replicas: 1,
          stream_max_bytes: 16_777_216,
          stream_retention: "workqueue",
          stream_max_age: 0
      }

      # The broker refuses the in-place retention change (NATS 2.14): the stream
      # keeps its shape and every stored record, so the upgrade path cuts over
      # to a new stream behind a drain barrier instead of updating in place.
      assert {:error, %{"description" => description}} =
               ConsumerReconciler.ensure_stream(conn, config, workqueue)

      assert description =~ "can not change retention policy"

      assert %{
               "config" => %{"retention" => "limits"},
               "state" => %{"messages" => 3, "first_seq" => 1, "last_seq" => 3}
             } = api(conn, "STREAM.INFO.#{@stream}", "")
    end)
  end

  test "a caught-up consumer is never refused past one cap of total traffic", ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, port ->
      config = config(port)
      shape = %{production_shape() | stream_replicas: 1, stream_max_bytes: 1_024}
      assert :ok = ConsumerReconciler.ensure_stream(conn, config, shape)

      assert %{"config" => %{"max_bytes" => 1_024}} =
               api(conn, "STREAM.INFO.#{@stream}", "")

      # Phase 1: no consumer drains, so DiscardNew refuses once the backlog fills the cap.
      {accepted, _refusal} = publish_until_refused(conn, 40)

      assert accepted > 0

      assert %{"state" => %{"messages" => ^accepted, "first_seq" => 1}} =
               api(conn, "STREAM.INFO.#{@stream}", "")

      # Phase 2: the owning durable drains and ACKs everything it was owed.
      producer = start_supervised!({Producer, %{config | streams: [shape]}})
      start_supervised!({AckSink, {producer, self()}})
      await_ready(:edge_retention_producer)
      await_settled(conn, durable(config))

      # Every ACKed record left the stream: the backlog is empty although total
      # published traffic already exceeds the cap.
      assert %{"state" => %{"messages" => 0}} = api(conn, "STREAM.INFO.#{@stream}", "")

      # Phase 3: publishing twice the cap again is never refused while the
      # consumer keeps up. Each publish settles before the next, so the backlog
      # never spans more than one record even though total traffic is triple
      # the cap.
      for n <- 1..(2 * accepted) do
        ack = publish!(conn, "synthetic-caught-up-#{n}")
        assert %{"stream" => @stream} = ack
        refute Map.has_key?(ack, "error")
        await_settled(conn, durable(config))
      end

      assert %{"state" => %{"messages" => 0}} = api(conn, "STREAM.INFO.#{@stream}", "")
    end)
  end

  test "a stopped consumer is refused at capacity with 10077 and nothing is evicted", ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, port ->
      config = config(port)
      shape = %{production_shape() | stream_replicas: 1, stream_max_bytes: 1_024}
      assert :ok = ConsumerReconciler.ensure_stream(conn, config, shape)

      assert %{"config" => %{"max_bytes" => 1_024}} =
               api(conn, "STREAM.INFO.#{@stream}", "")

      {accepted, refusal} = publish_until_refused(conn, 40)

      assert accepted > 0
      assert %{"error" => %{"err_code" => 10_077}} = refusal

      assert %{
               "state" => %{"messages" => ^accepted, "first_seq" => 1, "last_seq" => ^accepted}
             } = api(conn, "STREAM.INFO.#{@stream}", "")
    end)
  end

  test "a sealed stream refuses publishes while its durable still drains, and a drained stream deletes cleanly",
       ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, port ->
      config = config(port)

      legacy = %{
        production_shape()
        | stream_replicas: 1,
          stream_max_bytes: 16_777_216,
          stream_retention: "limits",
          stream_max_age: 86_400_000_000_000
      }

      assert :ok = ConsumerReconciler.ensure_stream(conn, config, legacy)

      for n <- 1..3 do
        assert %{"stream" => @stream, "seq" => ^n} = publish!(conn, "synthetic-seal-#{n}")
      end

      # Sealing pauses publishers at the broker: new publishes are refused with
      # a retryable error the gateway maps to spool-retaining backpressure.
      assert %{"config" => %{"sealed" => true}} = seal_stream(conn, true)
      refused = publish!(conn, "synthetic-sealed-1")
      assert %{"error" => _} = refused

      # The seal does not stop the owning durable: it still receives, ACKs, and
      # drains everything published before the seal.
      producer = start_supervised!({Producer, %{config | streams: [legacy]}})
      start_supervised!({AckSink, {producer, self()}})
      await_ready(:edge_retention_producer)
      await_settled(conn, durable(config))

      assert %{
               "config" => %{"sealed" => true},
               "state" => %{"messages" => 3, "first_seq" => 1, "last_seq" => 3}
             } = api(conn, "STREAM.INFO.#{@stream}", "")

      # Drained means nothing owed: deleting loses no records, and the name and
      # subject are immediately reusable for the WorkQueue replacement.
      assert %{"success" => true} = api(conn, "STREAM.DELETE.#{@stream}", "")

      assert %{"error" => %{"code" => 404}} =
               api(conn, "STREAM.INFO.#{@stream}", "")

      workqueue = %{
        production_shape()
        | stream_replicas: 1,
          stream_max_bytes: 16_777_216,
          stream_retention: "workqueue",
          stream_max_age: 0
      }

      assert :ok = ConsumerReconciler.ensure_stream(conn, config, workqueue)

      assert %{
               "config" => %{"retention" => "workqueue", "sealed" => false},
               "state" => %{"messages" => 0}
             } = api(conn, "STREAM.INFO.#{@stream}", "")

      assert %{"stream" => @stream, "seq" => 1} =
               publish!(conn, "synthetic-recreated-1")
    end)
  end

  test "cutover converts a limits stream to workqueue without losing records", ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, port ->
      config = config(port)

      legacy = %{
        production_shape()
        | stream_replicas: 1,
          stream_max_bytes: 16_777_216,
          stream_retention: "limits",
          stream_max_age: 86_400_000_000_000
      }

      assert :ok = ConsumerReconciler.ensure_stream(conn, config, legacy)

      for n <- 1..3 do
        assert %{"stream" => @stream, "seq" => ^n} = publish!(conn, "synthetic-cutover-#{n}")
      end

      # The owning durable drains everything published before the cutover.
      producer = start_supervised!({Producer, %{config | streams: [legacy]}})
      start_supervised!({AckSink, {producer, self()}})
      await_ready(:edge_retention_producer)
      await_settled(conn, durable(config))

      request = fn topic, payload ->
        case Gnat.request(conn, topic, payload, receive_timeout: 5_000) do
          {:ok, %{body: body}} -> {:ok, Jason.decode!(body)}
          {:error, reason} -> {:error, reason}
        end
      end

      target = %{
        production_shape()
        | stream_replicas: 1,
          stream_max_bytes: 16_777_216
      }

      # Seal, drain, delete: every pre-cutover record is already written, and
      # publishers refused during the cutover keep their bytes in agent spool.
      assert {:draining, cutover} = EdgeRecordStreamCutover.start(request, config, target)
      assert :cut_over = EdgeRecordStreamCutover.poll(request, cutover)

      assert :absent = JetstreamConsumer.stream_info(request, @stream, nil)

      # The reconcile path recreates the stream with the production shape.
      assert :ok = ConsumerReconciler.ensure_stream(conn, config, target)

      assert %{
               "config" => %{"retention" => "workqueue", "max_age" => 0, "sealed" => false},
               "state" => %{"messages" => 0}
             } = api(conn, "STREAM.INFO.#{@stream}", "")

      assert %{"stream" => @stream, "seq" => 1} =
               publish!(conn, "synthetic-post-cutover-1")
    end)
  end

  test "reconciling twice keeps exactly one owning durable", ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, port ->
      config = config(port)
      shape = %{production_shape() | stream_replicas: 1, stream_max_bytes: 16_777_216}
      assert :ok = ConsumerReconciler.ensure_stream(conn, config, shape)
      assert :ok = ConsumerReconciler.ensure_stream(conn, config, shape)

      # The reconciler never creates a second durable for the same stream entry:
      # the single-durable rule is enforced by construction, not by the broker
      # (the broker itself permits overlapping durables on any retention).
      assert %{"consumers" => [only]} =
               api(conn, "CONSUMER.NAMES.#{@stream}", Jason.encode!(%{}))

      assert only == durable(config)
    end)
  end

  # The production stream shape under test: `Config.edge_record_stream/0` as the
  # reconciler ensures it. The retention/max_age under test come from this shape,
  # so these tests fail while production still declares `Limits`.
  defp production_shape, do: Config.edge_record_stream()

  defp durable(config), do: Config.durable_name(config.consumer_name, "EDGE_RECORD")

  defp config(port) do
    %Config{
      enabled: true,
      producer_name: :edge_retention_producer,
      nats: %{
        host: "127.0.0.1",
        port: port,
        tls: false,
        user: nil,
        password: nil,
        jwt: nil,
        nkey_seed: nil,
        creds_file: nil
      },
      consumer_name: "synthetic-writer",
      max_ack_pending: 32,
      consumer_pull_batch_size: 4,
      workers: 1,
      retired_consumers: [],
      streams: []
    }
  end

  defp publish!(conn, msg_id, payload \\ String.duplicate("r", 128)) do
    {:ok, %{body: body}} =
      Gnat.request(conn, @source_subject, payload,
        headers: [{"Nats-Msg-Id", msg_id}],
        receive_timeout: 5_000
      )

    Jason.decode!(body)
  end

  # Publishes until the stream refuses (DiscardNew at MaxBytes). Returns
  # `{accepted_count, refusal_body}`.
  defp publish_until_refused(conn, limit) do
    1..limit
    |> Enum.reduce_while(0, fn n, accepted ->
      # A refusal can carry the targeted stream alongside the error, so the
      # error arm must come first.
      case publish!(conn, "synthetic-fill-#{n}") do
        %{"error" => _} = refusal -> {:halt, {accepted, refusal}}
        %{"stream" => @stream} -> {:cont, accepted + 1}
      end
    end)
    |> case do
      {accepted, refusal} when is_map(refusal) ->
        {accepted, refusal}

      accepted ->
        info = api(conn, "STREAM.INFO.#{@stream}", "")

        flunk(
          "stream never refused after #{accepted} publishes: " <>
            inspect(%{
              max_bytes: get_in(info, ["config", "max_bytes"]),
              retention: get_in(info, ["config", "retention"]),
              discard: get_in(info, ["config", "discard"]),
              state: info["state"]
            })
        )
    end
  end

  # Stream updates carry the full config: a partial body would wipe the rest.
  defp seal_stream(conn, sealed) do
    %{"config" => current} = api(conn, "STREAM.INFO.#{@stream}", "")

    {:ok, %{body: body}} =
      Gnat.request(
        conn,
        "$JS.API.STREAM.UPDATE.#{@stream}",
        Jason.encode!(Map.put(current, "sealed", sealed)),
        receive_timeout: 5_000
      )

    Jason.decode!(body)
  end

  defp await_settled(conn, durable_name, attempts \\ 100) do
    info = api(conn, "CONSUMER.INFO.#{@stream}.#{durable_name}", "")

    cond do
      match?(%{"num_pending" => 0, "num_ack_pending" => 0}, info) ->
        :ok

      attempts == 0 ->
        flunk("durable never settled: #{inspect(info)}")

      true ->
        Process.sleep(100)
        await_settled(conn, durable_name, attempts - 1)
    end
  end

  defp await_ready(name, attempts \\ 200) do
    cond do
      Producer.status(name).ready ->
        :ok

      attempts == 0 ->
        flunk("producer not ready: #{inspect(Producer.status(name))}")

      true ->
        Process.sleep(50)
        await_ready(name, attempts - 1)
    end
  end

  defp api(conn, api, body) do
    {:ok, %{body: reply}} = Gnat.request(conn, "$JS.API." <> api, body, receive_timeout: 5_000)
    Jason.decode!(reply)
  end
end
