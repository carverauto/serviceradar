defmodule ServiceRadar.Notifications.Transports.StreamTest do
  @moduledoc """
  The built-in `:stream` provider (design D10).

  `async: true`, no PubSub process, no broker: publishing goes through
  `opts[:broadcast]`, which these tests replace with a function that forwards to
  the test process. Envelope construction is pure and separately callable, so
  most of the shape assertions do not publish anything at all.

  The load-bearing test in this file is the design D7 / C2 one: a firehose
  envelope must never carry an acknowledgement capability token, because the
  firehose is a broadcast and a capability token is a single-use credential.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Notifications.Transport.Request
  alias ServiceRadar.Notifications.Transport.Result
  alias ServiceRadar.Notifications.Transports.Registry
  alias ServiceRadar.Notifications.Transports.Stream

  @moduletag :capture_log

  @capability_token "cap_7f3b9a1e5d2c4806b1a3e5f7d9c2b4a6"
  @now ~U[2026-08-09 12:00:00.000000Z]

  @payload %{
    "subject" => "Interface down on core-sw-01",
    "body" => "Gi0/1 went down",
    "severity" => "critical",
    "alert_id" => "33333333-3333-3333-3333-333333333333"
  }

  describe "contract" do
    test "conforms to the Transport behaviour and is on the registry allowlist" do
      assert Registry.conforms?(Stream)
      assert Registry.allowed?("ServiceRadar.Notifications.Transports.Stream")
    end

    test "declares both required capabilities, like every other tier" do
      assert :send in Stream.capabilities()
      assert :test in Stream.capabilities()
    end
  end

  describe "envelope/2 carries no acknowledgement capability (design D7, C2)" do
    test "strips the links list the :json renderer emits" do
      payload =
        Map.put(@payload, "links", [
          %{"action" => "acknowledge", "label" => "Acknowledge", "url" => ack_url()},
          %{"action" => "snooze", "label" => "Snooze 1h", "url" => ack_url()},
          %{"action" => "resolve", "label" => "Resolve", "url" => ack_url()},
          %{
            "action" => "alert",
            "label" => "View alert",
            "url" => "https://sr.example.com/alerts/33333333"
          }
        ])

      envelope = Stream.envelope(request(payload), now: @now)

      assert [%{"action" => "alert"}] = envelope["payload"]["links"]
      refute encoded(envelope) =~ @capability_token
    end

    test "strips a links map keyed by action" do
      payload =
        Map.put(@payload, "links", %{
          "acknowledge" => ack_url(),
          "snooze" => ack_url(),
          "resolve" => ack_url(),
          "alert" => "https://sr.example.com/alerts/33333333"
        })

      envelope = Stream.envelope(request(payload), now: @now)

      assert envelope["payload"]["links"] == %{
               "alert" => "https://sr.example.com/alerts/33333333"
             }

      refute encoded(envelope) =~ @capability_token
    end

    test "strips flat action-link keys wherever they are nested" do
      payload =
        Map.merge(@payload, %{
          "acknowledge_url" => ack_url(),
          "snooze_url" => ack_url(),
          "resolve_url" => ack_url(),
          "attachments" => [%{"title" => "actions", "acknowledge_url" => ack_url()}]
        })

      envelope = Stream.envelope(request(payload), now: @now)

      refute Map.has_key?(envelope["payload"], "acknowledge_url")
      refute Map.has_key?(envelope["payload"], "snooze_url")
      refute Map.has_key?(envelope["payload"], "resolve_url")
      assert envelope["payload"]["attachments"] == [%{"title" => "actions"}]
      refute encoded(envelope) =~ @capability_token
    end

    test "redacts credential-named keys through ActionRedaction" do
      payload =
        Map.merge(@payload, %{
          "token" => @capability_token,
          "nested" => %{"api_key" => "abc123456789"}
        })

      envelope = Stream.envelope(request(payload), now: @now)

      assert envelope["payload"]["token"] == "[REDACTED]"
      assert envelope["payload"]["nested"]["api_key"] == "[REDACTED]"
      refute encoded(envelope) =~ @capability_token
    end

    test "keeps the plain alert deep link, which carries no token" do
      payload = Map.put(@payload, "alert_url", "https://sr.example.com/alerts/33333333")

      envelope = Stream.envelope(request(payload), now: @now)

      assert envelope["payload"]["alert_url"] == "https://sr.example.com/alerts/33333333"
    end
  end

  describe "envelope/2 shape" do
    test "carries the identifiers a subscriber resolves through the authenticated API" do
      envelope = Stream.envelope(request(@payload), now: @now)

      assert envelope["schema"] == Stream.envelope_schema()
      assert envelope["emitted_at"] == "2026-08-09T12:00:00.000000Z"
      assert envelope["delivery_id"] == "11111111-1111-1111-1111-111111111111"
      assert envelope["alert_id"] == "33333333-3333-3333-3333-333333333333"
      assert envelope["channel_id"] == "22222222-2222-2222-2222-222222222222"
      assert envelope["payload_format"] == "json"
      assert envelope["is_test"] == false
      assert envelope["attempt"] == 1
    end

    test "marks a test dispatch so a subscriber can filter it without guessing" do
      envelope = Stream.envelope(request(@payload, is_test: true), now: @now)

      assert envelope["is_test"] == true
    end

    test "omits the payload when the channel asks for identifiers only" do
      request = request(@payload, config: %{"include_payload" => false})

      assert Stream.envelope(request, now: @now)["payload"] == nil
    end
  end

  describe "topic/1" do
    test "defaults to the firehose" do
      assert Stream.topic(%{}) == Stream.firehose_topic()
      assert Stream.firehose_topic() == "notifications:stream"
    end

    test "scopes to a configured suffix" do
      assert Stream.topic(%{"topic" => "noc"}) == "notifications:stream:noc"
      assert Stream.topic(%{topic: "NOC"}) == "notifications:stream:noc"
    end

    test "falls back to the firehose rather than using an unvalidated topic name" do
      assert Stream.topic(%{"topic" => "noc/*"}) == "notifications:stream"
      assert Stream.topic(%{"topic" => 12}) == "notifications:stream"
      assert Stream.topic(nil) == "notifications:stream"
    end
  end

  describe "deliver/2" do
    test "publishes the envelope to the firehose topic and reports delivered" do
      result = Stream.deliver(request(@payload), broadcast: broadcast(), now: @now)

      assert %Result{disposition: :delivered} = result
      assert result.result_summary["topic"] == "notifications:stream"
      assert result.result_summary["envelope_schema"] == Stream.envelope_schema()
      assert Result.outcome(result, true) == :sent

      assert_received {:published, "notifications:stream", envelope}
      assert envelope["schema"] == Stream.envelope_schema()
    end

    test "publishes to the configured scoped topic" do
      request = request(@payload, config: %{"topic" => "noc"})

      Stream.deliver(request, broadcast: broadcast(), now: @now)

      assert_received {:published, "notifications:stream:noc", _envelope}
    end

    test "test/2 publishes the same envelope on the same topic" do
      Stream.test(request(@payload, is_test: true), broadcast: broadcast(), now: @now)

      assert_received {:published, "notifications:stream", envelope}
      assert envelope["is_test"] == true
    end

    test "a publish error is retryable" do
      result =
        Stream.deliver(request(@payload),
          broadcast: fn _topic, _envelope -> {:error, :no_such_server} end
        )

      assert %Result{disposition: :retryable_failure, error_class: "stream_publish_failed"} =
               result

      assert Result.outcome(result, true) == :retry
    end

    test "a raising seam becomes a result, never an exception out of deliver/2" do
      result =
        Stream.deliver(request(@payload),
          broadcast: fn _topic, _envelope -> raise "pubsub down" end
        )

      assert %Result{disposition: :retryable_failure, error_class: "transport_exception"} = result
    end

    test "anything that is not a Request is a permanent failure rather than a crash" do
      assert %Result{disposition: :permanent_failure, error_class: "invalid_request"} =
               Stream.deliver(%{not: :a_request}, [])
    end

    test "an invalid configuration fails permanently and publishes nothing" do
      request = request(@payload, config: %{"topic" => "NOC/prod"})

      result = Stream.deliver(request, broadcast: broadcast())

      assert %Result{disposition: :permanent_failure, error_class: "invalid_config"} = result
      assert result.error_message =~ "topic"
      refute_received {:published, _topic, _envelope}
    end

    test "refuses to publish when a value the caller marked sensitive survived" do
      # Deliberately shorter than the scrubber's minimum replaceable length, so
      # this exercises the fail-closed check rather than the scrubber.
      short = "pw12"
      request = request(Map.put(@payload, "note", "credential #{short} rotated"))

      log =
        capture_log(fn ->
          result = Stream.deliver(request, broadcast: broadcast(), sensitive_values: [short])

          assert %Result{disposition: :permanent_failure, error_class: "envelope_leak"} = result
        end)

      refute_received {:published, _topic, _envelope}
      refute log =~ short
    end

    test "scrubs a long sensitive value out of the envelope and still publishes" do
      secret = "wh-live-9a8b7c6d5e4f3g2h1i0j"
      request = request(Map.put(@payload, "note", "sent with #{secret}"))

      result = Stream.deliver(request, broadcast: broadcast(), sensitive_values: [secret])

      assert %Result{disposition: :delivered} = result
      assert_received {:published, _topic, envelope}
      refute encoded(envelope) =~ secret
      assert envelope["payload"]["note"] =~ "[REDACTED]"
    end
  end

  describe "validate_config/1" do
    test "accepts an empty configuration - the firehose needs none" do
      assert :ok = Stream.validate_config(%{})
    end

    test "accepts a valid topic suffix and include_payload" do
      assert :ok = Stream.validate_config(%{"topic" => "noc", "include_payload" => false})
    end

    test "rejects a topic suffix that could smuggle a separator or wildcard" do
      for topic <- ["noc/prod", "noc *", "noc.prod", "-noc", String.duplicate("a", 65)] do
        assert {:error, [%{field: "topic"}]} = Stream.validate_config(%{"topic" => topic})
      end
    end

    test "rejects a non-string topic and a non-boolean include_payload" do
      assert {:error, [%{field: "topic"}]} = Stream.validate_config(%{"topic" => 12})

      assert {:error, [%{field: "include_payload"}]} =
               Stream.validate_config(%{"include_payload" => "yes"})
    end

    test "rejects a configuration that is not a map" do
      assert {:error, [%{field: nil}]} = Stream.validate_config("notifications:stream")
    end
  end

  describe "default_broadcast/2" do
    test "returns an error instead of raising when PubSub is not running" do
      assert {:error, message} = Stream.default_broadcast("notifications:stream", %{})
      assert is_binary(message)
    end
  end

  describe "strip_action_links/1" do
    test "leaves a payload with no action links untouched" do
      assert Stream.strip_action_links(@payload) == @payload
    end
  end

  # --- helpers --------------------------------------------------------------

  defp request(payload, overrides \\ []) do
    struct!(
      %Request{
        delivery_id: "11111111-1111-1111-1111-111111111111",
        alert_id: "33333333-3333-3333-3333-333333333333",
        channel_id: "22222222-2222-2222-2222-222222222222",
        provider_key: "stream",
        payload_format: :json,
        payload: payload,
        config: %{}
      },
      overrides
    )
  end

  defp broadcast do
    test_pid = self()

    fn topic, envelope ->
      send(test_pid, {:published, topic, envelope})
      :ok
    end
  end

  defp ack_url do
    "https://sr.example.com/notifications/actions/acknowledge?token=#{@capability_token}"
  end

  defp encoded(envelope), do: Jason.encode!(envelope)
end
