defmodule ServiceRadar.Notifications.StreamPublisherTest do
  @moduledoc """
  The durable half of the firehose (task 4.1.1).

  Every NATS call is injected, so these run with no broker and no connection
  process.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.StreamPublisher

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
                 request: recording_request(responses)
               )
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
end
