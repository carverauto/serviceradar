defmodule ServiceRadar.Notifications.Callbacks.PagerDutyTest do
  @moduledoc """
  PagerDuty v3 webhook verification and event mapping (tasks 4.3.3, 4.4.1).

  The signature test that matters most builds its expected digest from raw
  `:crypto` over the literal body, touching no helper - because PagerDuty signs
  the body ALONE, and a test that signed through the implementation would agree
  with a base-string mistake instead of catching it. That is the exact hole found
  in the Slack suite.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.Callbacks.PagerDuty

  @secret "pagerduty-signing-secret-for-tests-only"
  @subscription "PWEV1TW"
  @now ~U[2026-08-10 12:00:00Z]

  defp body(overrides \\ %{}) do
    event =
      Map.merge(
        %{
          "id" => "01BWDWL3NYY7LUFPZCC28QUCMK",
          "event_type" => "incident.acknowledged",
          "resource_type" => "incident",
          "occurred_at" => DateTime.to_iso8601(@now),
          "agent" => %{"id" => "PLH1HKV", "type" => "user_reference"},
          "data" => %{
            "id" => "PGR0VU2",
            "type" => "incident",
            "status" => "acknowledged",
            "incident_key" => "0198f0aa-1111-7000-8000-000000000001"
          }
        },
        overrides
      )

    Jason.encode!(%{"event" => event})
  end

  defp headers(raw_body, overrides \\ %{}) do
    Map.merge(
      %{
        "x-pagerduty-signature" => PagerDuty.sign(raw_body, @secret),
        "x-webhook-subscription" => @subscription,
        "content-type" => "application/json"
      },
      overrides
    )
  end

  defp request(raw_body, header_overrides \\ %{}) do
    %{params: %{}, headers: headers(raw_body, header_overrides), raw_body: raw_body}
  end

  describe "verify/4" do
    test "accepts a digest computed independently over the body alone" do
      raw = body()

      expected =
        "v1=" <> Base.encode16(:crypto.mac(:hmac, :sha256, @secret, raw), case: :lower)

      assert :ok =
               PagerDuty.verify(raw, %{"x-pagerduty-signature" => expected}, @secret, now: @now)
    end

    test "signs the body with no timestamp and no separator" do
      # Copying northbound's "<ts>.<body>" or Slack's "v0:<ts>:<body>" here
      # produces a digest that never matches.
      raw = body()

      refute PagerDuty.sign(raw, @secret) ==
               "v1=" <>
                 Base.encode16(:crypto.mac(:hmac, :sha256, @secret, "x." <> raw), case: :lower)

      assert :ok = PagerDuty.verify(raw, headers(raw), @secret, now: @now)
    end

    test "accepts when any element of a rotated signature list matches" do
      raw = body()

      rotating = %{
        "x-pagerduty-signature" =>
          Enum.join([PagerDuty.sign(raw, "the-old-secret"), PagerDuty.sign(raw, @secret)], ",")
      }

      assert :ok = PagerDuty.verify(raw, rotating, @secret, now: @now)
    end

    test "skips an unrecognised version element instead of failing on it" do
      # Forward compatibility: a future v2= alongside a valid v1= must still
      # verify, or PagerDuty rolling out a new scheme takes the integration down.
      raw = body()

      mixed = %{
        "x-pagerduty-signature" =>
          Enum.join(["v2=" <> String.duplicate("a", 64), PagerDuty.sign(raw, @secret)], ", ")
      }

      assert :ok = PagerDuty.verify(raw, mixed, @secret, now: @now)
    end

    test "refuses a header carrying no v1 element at all" do
      raw = body()
      only_future = %{"x-pagerduty-signature" => "v2=" <> String.duplicate("a", 64)}

      assert {:error, :unsupported_signature_version} =
               PagerDuty.verify(raw, only_future, @secret, now: @now)
    end

    test "rejects a wrong secret and a tampered body" do
      raw = body()

      assert {:error, :invalid_signature} =
               PagerDuty.verify(raw, headers(raw), "not-the-secret", now: @now)

      tampered = String.replace(raw, "PLH1HKV", "PEVIL42")

      assert {:error, :invalid_signature} =
               PagerDuty.verify(tampered, headers(raw), @secret, now: @now)
    end

    test "bounds replay on the signed occurred_at, generously" do
      # There is no timestamp header, so this is the only clock in the signed
      # material. The bound is wide because PagerDuty retries over ~20 minutes
      # and a tighter window rejects its own retries.
      raw = body()

      assert :ok =
               PagerDuty.verify(raw, headers(raw), @secret,
                 now: DateTime.add(@now, PagerDuty.occurred_at_tolerance_seconds(), :second)
               )

      assert {:error, :stale_timestamp} =
               PagerDuty.verify(raw, headers(raw), @secret,
                 now: DateTime.add(@now, PagerDuty.occurred_at_tolerance_seconds() + 1, :second)
               )
    end

    test "accepts an authentic body whose occurred_at cannot be parsed" do
      # A signed body is authentic whatever its shape. Refusing it would reject a
      # future payload PagerDuty signed correctly.
      raw = body(%{"occurred_at" => nil})

      assert :ok = PagerDuty.verify(raw, headers(raw), @secret, now: @now)
    end

    test "reports an unbuffered raw body distinctly" do
      assert {:error, :raw_body_unavailable} =
               PagerDuty.verify("", headers(body()), @secret, now: @now, content_length: 512)
    end
  end

  describe "decode_interaction/1 and capability/1" do
    test "reads the subscription from the header, not the body" do
      raw = body()

      assert {:ok, event} = PagerDuty.decode_interaction(request(raw))
      assert event.app_id == @subscription
      assert event.event_id == "01BWDWL3NYY7LUFPZCC28QUCMK"
      assert event.incident_key == "0198f0aa-1111-7000-8000-000000000001"
    end

    test "maps acknowledged and resolved onto the alert transitions" do
      for {event_type, action} <- [
            {"incident.acknowledged", :acknowledge},
            {"incident.resolved", :resolve}
          ] do
        raw = body(%{"event_type" => event_type})

        assert {:ok, event} = PagerDuty.decode_interaction(request(raw))
        assert {:ok, capability} = PagerDuty.capability(event)

        assert capability.action == action
        # incident_key is our own dedup_key, which the shipping document sets to
        # the alert id - read back rather than looked up over the API.
        assert capability.alert_id == "0198f0aa-1111-7000-8000-000000000001"
        assert capability.external_principal == "pagerduty:PLH1HKV"
        assert capability.app_id == @subscription
      end
    end

    test "refuses the two event types that have no inverse, specifically" do
      # Subscribing to an event whose handler silently drops it is how an
      # operator concludes the integration works when half of it does not.
      for event_type <- ["incident.unacknowledged", "incident.reopened"] do
        raw = body(%{"event_type" => event_type})

        assert {:ok, event} = PagerDuty.decode_interaction(request(raw))
        assert {:error, :event_type_has_no_inverse} = PagerDuty.capability(event)
      end
    end

    test "refuses an event type it does not recognise at all" do
      raw = body(%{"event_type" => "incident.escalated"})

      assert {:ok, event} = PagerDuty.decode_interaction(request(raw))
      assert {:error, :unsupported_event_type} = PagerDuty.capability(event)
    end

    test "carries the event id so a redelivery can be deduped" do
      # PagerDuty has no transport-level replay defence, so its own event id is
      # the only thing that makes a redelivery idempotent rather than a second
      # audit row.
      raw = body()

      assert {:ok, event} = PagerDuty.decode_interaction(request(raw))
      assert {:ok, capability} = PagerDuty.capability(event)

      assert capability.event_id == "01BWDWL3NYY7LUFPZCC28QUCMK"
    end

    test "refuses an incident ServiceRadar did not open" do
      # No incident_key means the incident was not created from a ServiceRadar
      # alert, so there is nothing to correlate and nothing to guess.
      raw = body(%{"data" => %{"id" => "PGR0VU2", "type" => "incident"}})

      assert {:ok, event} = PagerDuty.decode_interaction(request(raw))
      assert {:error, :missing_incident_key} = PagerDuty.capability(event)
    end

    test "refuses a payload that is not a v3 envelope" do
      assert {:error, :invalid_payload} =
               PagerDuty.decode_interaction(%{params: %{}, headers: %{}, raw_body: "{}"})

      assert {:error, :missing_event_id} =
               PagerDuty.decode_interaction(%{
                 params: %{},
                 headers: %{},
                 raw_body: Jason.encode!(%{"event" => %{"event_type" => "incident.resolved"}})
               })
    end
  end
end
