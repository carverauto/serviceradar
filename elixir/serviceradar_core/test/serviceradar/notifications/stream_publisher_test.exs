defmodule ServiceRadar.Notifications.StreamPublisherTest do
  @moduledoc """
  The durable half of the firehose (task 4.1.1).

  Every NATS call is injected, so these run with no broker and no connection
  process.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Notifications.StreamPublisher

  require Logger

  @envelope %{"schema" => "serviceradar.notification_envelope.v1", "alert_id" => "alert-1"}
  @pub_ack {:ok, %{"stream" => "NOTIFICATIONS", "seq" => 7}}

  defp recording_request(responses) do
    test = self()

    fn subject, payload ->
      send(test, {:request, subject, payload})

      n = :counters.get(responses.counter, 1)
      :counters.add(responses.counter, 1, 1)
      Enum.at(responses.list, n, List.last(responses.list))
    end
  end

  defp responses(list) do
    %{counter: :counters.new(1, []), list: list}
  end

  describe "subject/1" do
    test "translates the firehose topic into the notifications namespace" do
      assert StreamPublisher.subject("notifications:stream") == "notifications.stream"
    end

    test "keeps a topic suffix as a further subject token" do
      assert StreamPublisher.subject("notifications:stream:security") ==
               "notifications.stream.security"
    end

    test "keeps a topic that is not already rooted inside the namespace" do
      # A subject outside `notifications.>` is denied at the broker, so escaping
      # the namespace would mean silently dropping every envelope.
      assert StreamPublisher.subject("something:else") == "notifications.something.else"
      assert String.starts_with?(StreamPublisher.subject("whatever"), "notifications.")
    end

    test "sanitises tokens that would smuggle a separator or wildcard" do
      for hostile <- ["notifications:a.b", "notifications:a>b", "notifications:a*b"] do
        subject = StreamPublisher.subject(hostile)

        assert String.starts_with?(subject, "notifications.")
        refute String.contains?(subject, ">")
        refute String.contains?(subject, "*")
        assert length(String.split(subject, ".")) == 2
      end
    end

    test "falls back to the namespace root for an empty topic" do
      assert StreamPublisher.subject("") == "notifications"
    end
  end

  describe "publish/3" do
    test "returns ok when JetStream acknowledges persistence" do
      assert :ok =
               StreamPublisher.publish("notifications:stream", @envelope,
                 request: fn _subject, _payload -> @pub_ack |> elem(1) |> then(&{:ok, &1}) end
               )
    end

    test "publishes the encoded envelope to the translated subject" do
      test = self()

      assert :ok =
               StreamPublisher.publish("notifications:stream:ops", @envelope,
                 request: fn subject, payload ->
                   send(test, {:published, subject, payload})
                   {:ok, %{"stream" => "NOTIFICATIONS", "seq" => 1}}
                 end
               )

      assert_received {:published, "notifications.stream.ops", payload}
      assert Jason.decode!(payload) == @envelope
    end

    test "refuses an envelope that cannot be encoded" do
      assert {:error, {:envelope_not_encodable, _}} =
               StreamPublisher.publish("notifications:stream", %{"bad" => {:not, :encodable}},
                 request: fn _subject, _payload -> @pub_ack end
               )
    end

    test "treats an ack without a sequence as a failure" do
      # A response that is not a PubAck is not evidence of persistence, and
      # reporting it as success is how a dead firehose looks healthy.
      assert {:error, {:unexpected_publish_ack, _}} =
               StreamPublisher.publish("notifications:stream", @envelope,
                 request: fn _subject, _payload -> {:ok, %{"not" => "an ack"}} end
               )
    end

    test "creates the stream and retries once when nothing responds on the subject" do
      responses =
        responses([
          {:error, :timeout},
          {:ok, %{"created" => true}},
          @pub_ack |> elem(1) |> then(&{:ok, &1})
        ])

      assert :ok =
               StreamPublisher.publish("notifications:stream", @envelope,
                 reconcile_stream: false,
                 request: recording_request(responses)
               )

      assert_received {:request, "notifications.stream", _}
      assert_received {:request, "$JS.API.STREAM.CREATE.NOTIFICATIONS", create_payload}
      assert_received {:request, "notifications.stream", _}

      decoded = Jason.decode!(create_payload)
      assert decoded["name"] == "NOTIFICATIONS"
      assert decoded["subjects"] == ["notifications.>"]
    end

    test "reports stream_unavailable when the retry cannot create the stream" do
      responses =
        responses([{:error, :timeout}, {:error, %{"description" => "insufficient resources"}}])

      assert {:error, {:stream_unavailable, _}} =
               StreamPublisher.publish("notifications:stream", @envelope,
                 reconcile_stream: false,
                 request: recording_request(responses)
               )
    end

    test "reconciles the stream size once per node before its first publish" do
      # A max_bytes no other test uses, so the once-per-node memo is this test's.
      max_bytes = 734_003_200
      stream = notifications_stream(1_073_741_824)
      test = self()

      request = fn subject, payload ->
        send(test, {:request, subject, payload})

        case subject do
          "$JS.API.STREAM.INFO.NOTIFICATIONS" -> {:ok, stream}
          "$JS.API.STREAM.UPDATE.NOTIFICATIONS" -> {:ok, %{"config" => Jason.decode!(payload)}}
          _publish -> @pub_ack
        end
      end

      opts = [max_bytes: max_bytes, request: request]
      assert :ok = StreamPublisher.publish("notifications:stream", @envelope, opts)
      assert :ok = StreamPublisher.publish("notifications:stream", @envelope, opts)

      assert_received {:request, "$JS.API.STREAM.UPDATE.NOTIFICATIONS", update}
      assert Jason.decode!(update)["max_bytes"] == max_bytes
      refute_received {:request, "$JS.API.STREAM.UPDATE.NOTIFICATIONS", _}
      assert_received {:request, "$JS.API.STREAM.INFO.NOTIFICATIONS", _}
      refute_received {:request, "$JS.API.STREAM.INFO.NOTIFICATIONS", _}
    end

    test "fails open on a reconcile failure and does not repeat it within the retry interval" do
      # A max_bytes no other test uses, so the once-per-node memo is this test's.
      max_bytes = 314_159_265
      test = self()
      clock = :counters.new(1, [])

      request = fn subject, payload ->
        send(test, {:request, subject, payload})

        case subject do
          "$JS.API.STREAM.INFO.NOTIFICATIONS" -> {:error, :timeout}
          _publish -> @pub_ack
        end
      end

      opts = [
        max_bytes: max_bytes,
        request: request,
        clock: fn -> :counters.get(clock, 1) end
      ]

      log1 =
        capture_log(fn ->
          assert :ok = StreamPublisher.publish("notifications:stream", @envelope, opts)
        end)

      assert log1 =~ "not reconciled"
      assert_received {:request, "$JS.API.STREAM.INFO.NOTIFICATIONS", _}
      assert_received {:request, "notifications.stream", _}

      # Still inside the 5-minute retry window: the reconcile is not repeated,
      # and the publish itself still succeeds.
      :counters.add(clock, 1, 60_000)

      log2 =
        capture_log(fn ->
          assert :ok = StreamPublisher.publish("notifications:stream", @envelope, opts)
        end)

      refute log2 =~ "not reconciled"
      refute_received {:request, "$JS.API.STREAM.INFO.NOTIFICATIONS", _}
      assert_received {:request, "notifications.stream", _}

      # Past the retry window: the reconcile is retried once, and the publish
      # still succeeds.
      :counters.add(clock, 1, 300_000)

      log3 =
        capture_log(fn ->
          assert :ok = StreamPublisher.publish("notifications:stream", @envelope, opts)
        end)

      assert log3 =~ "not reconciled"
      assert_received {:request, "$JS.API.STREAM.INFO.NOTIFICATIONS", _}
      assert_received {:request, "notifications.stream", _}
    end

    test "does not attempt stream creation when the broker is unreachable" do
      # Retrying a connection error would call ensure_stream/1 over the same dead
      # connection and report :stream_unavailable, burying the real cause.
      test = self()

      assert {:error, {:nats_not_connected, :down}} =
               StreamPublisher.publish("notifications:stream", @envelope,
                 request: fn subject, _payload ->
                   send(test, {:request, subject})
                   {:error, {:nats_not_connected, :down}}
                 end
               )

      assert_received {:request, "notifications.stream"}
      refute_received {:request, "$JS.API.STREAM.CREATE.NOTIFICATIONS"}
    end

    test "does not retry when stream creation is disabled" do
      test = self()

      assert {:error, :timeout} =
               StreamPublisher.publish("notifications:stream", @envelope,
                 ensure_stream: false,
                 request: fn subject, _payload ->
                   send(test, {:request, subject})
                   {:error, :timeout}
                 end
               )

      refute_received {:request, "$JS.API.STREAM.CREATE.NOTIFICATIONS"}
    end
  end

  describe "ensure_stream/1" do
    test "creates the stream over the notifications namespace" do
      test = self()

      assert :ok =
               StreamPublisher.ensure_stream(
                 request: fn subject, payload ->
                   send(test, {:create, subject, payload})
                   {:ok, %{"created" => true}}
                 end
               )

      assert_received {:create, "$JS.API.STREAM.CREATE.NOTIFICATIONS", payload}
      decoded = Jason.decode!(payload)

      assert decoded["subjects"] == ["notifications.>"]
      # Interest retention would discard a message once every KNOWN consumer
      # acked it, which defeats replay for a consumer that was absent.
      assert decoded["retention"] == "limits"
      assert decoded["storage"] == "file"
    end

    test "treats a bare name collision as success so concurrent nodes can race" do
      # NATS 2.14 answers an identical create with an ordinary success, so this
      # branch only covers an older broker that reports the benign race as an
      # error. Verified against a live 2.14 broker: a repeated identical
      # STREAM.CREATE returns did_create: true.
      assert :ok =
               StreamPublisher.ensure_stream(
                 request: fn _subject, _payload ->
                   {:error, %{"description" => "stream name already in use"}}
                 end
               )
    end

    test "refuses a collision with a different configuration instead of swallowing it" do
      # This is the message a live broker actually returns (err_code 10058), and
      # it means the name is taken by a stream capturing other subjects - so
      # nothing captures notifications.> and every envelope is dropped. Reporting
      # it as success would leave the firehose dead and looking healthy.
      assert {:error, {:stream_config_conflict, description}} =
               StreamPublisher.ensure_stream(
                 request: fn _subject, _payload ->
                   {:error,
                    %{
                      "code" => 400,
                      "err_code" => 10_058,
                      "description" => "stream name already in use with a different configuration"
                    }}
                 end
               )

      assert description =~ "different configuration"
    end

    test "surfaces a creation error that is not a name collision" do
      assert {:error, "insufficient storage"} =
               StreamPublisher.ensure_stream(
                 request: fn _subject, _payload ->
                   {:error, %{"description" => "insufficient storage"}}
                 end
               )
    end
  end

  describe "reconcile_stream/1" do
    setup do
      # The before/after line is :info; mix test runs at :warning.
      Logger.put_process_level(self(), :info)
      :ok
    end

    test "shrinks the discard-old firehose to the configured size, logging before and after" do
      {log, updates} =
        reconcile(notifications_stream(1_073_741_824, stored: 900_000_000), 536_870_912)

      assert [%{"max_bytes" => 536_870_912, "discard" => "old"} = update] = updates
      assert update["subjects"] == ["notifications.>"]
      assert log =~ "max_bytes 1073741824 -> 536870912"
      assert log =~ "evicts the oldest messages"
    end

    test "keeps max_bytes of a discard-new stream that holds more than the cap" do
      stream = notifications_stream(1_073_741_824, stored: 900_000_000, discard: "new")
      {log, updates} = reconcile(stream, 536_870_912)

      assert updates == []
      assert log =~ "max_bytes left unchanged"
      assert log =~ "configured=536870912 stored=900000000 current=1073741824"
    end

    test "leaves a stream already at the configured size alone" do
      {_log, updates} = reconcile(notifications_stream(536_870_912), 536_870_912)

      assert updates == []
    end

    test "creates an absent stream with the configured size" do
      test = self()

      request = fn subject, payload ->
        send(test, {:request, subject, payload})

        case subject do
          "$JS.API.STREAM.INFO." <> _ -> {:error, %{"code" => 404, "err_code" => 10_059}}
          "$JS.API.STREAM.CREATE." <> _ -> {:ok, %{"did_create" => true}}
        end
      end

      assert :ok = StreamPublisher.reconcile_stream(request: request, max_bytes: 268_435_456)
      assert_received {:request, "$JS.API.STREAM.CREATE.NOTIFICATIONS", payload}
      assert Jason.decode!(payload)["max_bytes"] == 268_435_456
    end

    test "refuses a stream of that name that does not capture the firehose subjects" do
      stream = put_in(notifications_stream(1_073_741_824), ["config", "subjects"], ["other.>"])

      assert {:error, {:stream_config_conflict, _}} =
               StreamPublisher.reconcile_stream(
                 request: fn _subject, _payload -> {:ok, stream} end,
                 max_bytes: 536_870_912
               )
    end
  end

  describe "durable_consumer_opts/2" do
    test "names the same stream and subject the publisher writes to" do
      opts = StreamPublisher.durable_consumer_opts("web-ng-firehose")

      assert opts[:stream_name] == StreamPublisher.stream_name()
      assert opts[:filter_subject] == StreamPublisher.subject_wildcard()
      assert opts[:consumer_name] == "web-ng-firehose"
    end

    test "accepts a narrowed filter subject" do
      opts =
        StreamPublisher.durable_consumer_opts("ops", filter_subject: "notifications.stream.ops")

      assert opts[:filter_subject] == "notifications.stream.ops"
    end
  end

  # A STREAM.INFO reply for the firehose stream.
  defp notifications_stream(max_bytes, opts \\ []) do
    %{
      "config" => %{
        "name" => "NOTIFICATIONS",
        "subjects" => ["notifications.>"],
        "retention" => "limits",
        "storage" => "file",
        "discard" => Keyword.get(opts, :discard, "old"),
        "num_replicas" => 1,
        "max_age" => 86_400_000_000_000,
        "max_bytes" => max_bytes
      },
      "state" => %{"bytes" => Keyword.get(opts, :stored, 0)}
    }
  end

  # Runs reconcile_stream/1 against `stream`, returning the log and the
  # STREAM.UPDATE configs it sent.
  defp reconcile(stream, max_bytes) do
    test = self()

    request = fn subject, payload ->
      send(test, {:request, subject, payload})

      case subject do
        "$JS.API.STREAM.UPDATE." <> _name -> {:ok, %{"config" => Jason.decode!(payload)}}
        _info -> {:ok, stream}
      end
    end

    log =
      capture_log(fn ->
        assert :ok = StreamPublisher.reconcile_stream(request: request, max_bytes: max_bytes)
      end)

    {log, drain_updates([])}
  end

  defp drain_updates(acc) do
    receive do
      {:request, "$JS.API.STREAM.UPDATE.NOTIFICATIONS", payload} ->
        drain_updates([Jason.decode!(payload) | acc])

      {:request, _subject, _payload} ->
        drain_updates(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end
end
