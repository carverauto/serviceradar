defmodule ServiceRadar.Notifications.Callbacks.SlackTest do
  @moduledoc """
  Slack interactivity signature verification (tasks 4.3.4, 4.4.1).

  Most tests sign with `Slack.sign/3`, which keeps `verify/4` honest against
  `sign/3` - but note what that does NOT catch: both call `base_string/2`, so if
  the base string itself drifted (say, to northbound's `"<ts>.<body>"`), every
  one of those tests would keep passing while production traffic was rejected.

  Two tests exist specifically to close that hole, and they are the ones to keep
  if any are ever pruned: `base_string/2` is asserted against a written-out
  literal in Slack's documented FORMAT, and one `verify/4` test builds its
  expected signature from a literal base string and raw `:crypto`, touching no
  implementation helper at all.

  The fixtures are synthetic rather than copied from Slack's published example,
  because a documentation sample still trips secret scanning and none of the
  formats under test depend on the sample's values.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.Callbacks.Slack
  alias ServiceRadar.Notifications.Renderers.SlackBlocks

  # A synthetic signing secret. Deliberately not the literal from Slack's
  # published example: a doc sample still trips secret scanning, and the format
  # under test does not depend on its value.
  @secret "slack-signing-secret-for-tests-only"
  @now ~U[2026-08-10 12:00:00Z]
  # Derived, never restated: a hand-written epoch that drifts from @now makes
  # every valid-signature test fail as :stale_timestamp, which reads like a
  # verifier bug rather than a fixture one.
  @timestamp @now |> DateTime.to_unix() |> Integer.to_string()

  # A real interactivity POST body: form-encoded, JSON inside `payload`.
  @body "payload=%7B%22type%22%3A%22block_actions%22%2C%22user%22%3A%7B%22id%22%3A%22UA8RXUSPL%22%7D%7D"

  defp headers(overrides \\ %{}) do
    Map.merge(
      %{
        "x-slack-signature" => Slack.sign(@timestamp, @body, @secret),
        "x-slack-request-timestamp" => @timestamp
      },
      overrides
    )
  end

  describe "base_string/2" do
    test "uses colons, not the northbound period" do
      # Reusing northbound's "<ts>.<body>" builder here produces a digest that
      # never matches, and the symptom is indistinguishable from a wrong secret.
      assert Slack.base_string("1531420618", "team_id=T1DC2JH3J&channel_id=C2147483705") ==
               "v0:1531420618:team_id=T1DC2JH3J&channel_id=C2147483705"
    end
  end

  describe "verify/4" do
    test "accepts a signature Slack would have produced" do
      assert :ok = Slack.verify(@body, headers(), @secret, now: @now)
    end

    test "accepts a digest computed independently of the implementation" do
      # Deliberately touches no helper: the base string is written out literally
      # and the HMAC comes straight from :crypto. Every other verify test signs
      # via sign/3, which shares base_string/2 with verify/4 and would therefore
      # agree with a drifted separator instead of catching it.
      literal = "v0:" <> @timestamp <> ":" <> @body

      expected =
        "v0=" <>
          Base.encode16(:crypto.mac(:hmac, :sha256, @secret, literal), case: :lower)

      independent = %{
        "x-slack-signature" => expected,
        "x-slack-request-timestamp" => @timestamp
      }

      assert :ok = Slack.verify(@body, independent, @secret, now: @now)
    end

    test "accepts however the provider cased the header names" do
      cased = %{
        "X-Slack-Signature" => Slack.sign(@timestamp, @body, @secret),
        "X-Slack-Request-Timestamp" => @timestamp
      }

      assert :ok = Slack.verify(@body, cased, @secret, now: @now)
    end

    test "accepts headers as a keyword-style list, as Plug yields them" do
      list = [
        {"content-type", "application/x-www-form-urlencoded"},
        {"x-slack-signature", Slack.sign(@timestamp, @body, @secret)},
        {"x-slack-request-timestamp", @timestamp}
      ]

      assert :ok = Slack.verify(@body, list, @secret, now: @now)
    end

    test "rejects a signature made with a different secret" do
      forged = %{"x-slack-signature" => Slack.sign(@timestamp, @body, "not-the-secret")}

      assert {:error, :invalid_signature} =
               Slack.verify(@body, headers(forged), @secret, now: @now)
    end

    test "rejects a tampered body" do
      # The signature is valid for @body; the body presented is not @body.
      tampered = String.replace(@body, "UA8RXUSPL", "UEVILUSER")

      assert {:error, :invalid_signature} =
               Slack.verify(tampered, headers(), @secret, now: @now)
    end

    test "rejects a replay beyond the tolerance" do
      replayed_at = DateTime.add(@now, Slack.tolerance_seconds() + 1, :second)

      assert {:error, :stale_timestamp} =
               Slack.verify(@body, headers(), @secret, now: replayed_at)
    end

    test "rejects a future-dated timestamp beyond the tolerance" do
      # Clock drift runs both ways, and a one-sided check silently accepts a
      # replay presented from a fast clock.
      early = DateTime.add(@now, -(Slack.tolerance_seconds() + 1), :second)

      assert {:error, :stale_timestamp} = Slack.verify(@body, headers(), @secret, now: early)
    end

    test "accepts a timestamp at the edge of the tolerance" do
      edge = DateTime.add(@now, Slack.tolerance_seconds(), :second)

      assert :ok = Slack.verify(@body, headers(), @secret, now: edge)
    end

    test "rejects a missing signature and a missing timestamp distinctly" do
      assert {:error, :missing_signature} =
               Slack.verify(@body, Map.delete(headers(), "x-slack-signature"), @secret, now: @now)

      assert {:error, :missing_timestamp} =
               Slack.verify(
                 @body,
                 Map.delete(headers(), "x-slack-request-timestamp"),
                 @secret,
                 now: @now
               )
    end

    test "rejects an unparseable timestamp rather than treating it as epoch zero" do
      assert {:error, :invalid_timestamp} =
               Slack.verify(
                 @body,
                 headers(%{"x-slack-request-timestamp" => "yesterday"}),
                 @secret,
                 now: @now
               )
    end

    test "refuses a signature version it does not recognise" do
      # Slack documents v0 and does not promise it is the last version. Assuming
      # v0 and slicing three characters off a future v1= signature would compare
      # a truncated digest.
      future = %{"x-slack-signature" => "v1=" <> String.duplicate("a", 64)}

      assert {:error, :unsupported_signature_version} =
               Slack.verify(@body, headers(future), @secret, now: @now)
    end

    test "refuses a bare digest with no version prefix" do
      bare = %{"x-slack-signature" => String.duplicate("a", 64)}

      assert {:error, :unsupported_signature_version} =
               Slack.verify(@body, headers(bare), @secret, now: @now)
    end

    test "reports an unbuffered raw body as a distinct fault, not a bad signature" do
      # A route whose prefix is not registered with RawBodyReader yields "".
      # Reporting that as :invalid_signature would send an operator hunting a
      # secret that is perfectly correct.
      assert {:error, :raw_body_unavailable} =
               Slack.verify("", headers(), @secret, now: @now, content_length: 128)
    end

    test "refuses to verify with no key material rather than defaulting one" do
      assert {:error, :missing_key_material} = Slack.verify(@body, headers(), "", now: @now)
      assert {:error, :missing_key_material} = Slack.verify(@body, headers(), nil, now: @now)
    end
  end

  describe "decode_interaction/1 and capability/1" do
    defp interaction_json(overrides \\ %{}) do
      %{
        "type" => "block_actions",
        "api_app_id" => "A0123456789",
        "user" => %{"id" => "UA8RXUSPL"},
        "team" => %{"id" => "T1DC2JH3J"},
        "actions" => [
          %{
            "action_id" => "notification_acknowledge",
            "value" => "acknowledge:alert-1:delivery-1"
          }
        ]
      }
      |> Map.merge(overrides)
      |> Jason.encode!()
    end

    defp form_body(json), do: URI.encode_query(%{"payload" => json})

    test "reads the app id and the clicked action from a form-encoded payload" do
      assert {:ok, interaction} =
               Slack.decode_interaction(%{
                 params: %{"payload" => interaction_json()},
                 headers: %{},
                 raw_body: ""
               })

      assert interaction.app_id == "A0123456789"
      assert interaction.user_id == "UA8RXUSPL"
      assert interaction.value == "acknowledge:alert-1:delivery-1"
    end

    test "falls back to the raw body when the form parser has not run" do
      assert {:ok, interaction} =
               Slack.decode_interaction(%{
                 params: %{},
                 headers: %{},
                 raw_body: form_body(interaction_json())
               })

      assert interaction.app_id == "A0123456789"
    end

    test "refuses an interaction type it does not handle" do
      # A payload whose shape we did not anticipate is not one to guess an alert
      # id out of.
      json = interaction_json(%{"type" => "view_submission"})

      assert {:error, :unsupported_interaction_type} =
               Slack.decode_interaction(%{
                 params: %{"payload" => json},
                 headers: %{},
                 raw_body: ""
               })
    end

    test "refuses a payload with no app id, since nothing could select a secret" do
      json = interaction_json(%{"api_app_id" => ""})

      assert {:error, :missing_app_id} =
               Slack.decode_interaction(%{
                 params: %{"payload" => json},
                 headers: %{},
                 raw_body: ""
               })
    end

    test "refuses a missing or unparseable payload" do
      assert {:error, :missing_payload} =
               Slack.decode_interaction(%{params: %{}, headers: %{}, raw_body: ""})

      assert {:error, :invalid_payload} =
               Slack.decode_interaction(%{
                 params: %{"payload" => "{"},
                 headers: %{},
                 raw_body: ""
               })
    end

    test "parses the control value SlackBlocks wrote" do
      # Round trip against the writer rather than a restatement of the format:
      # the two must agree, and they stop agreeing when one is rewritten from
      # memory.
      value =
        SlackBlocks.control_value(%{
          action: :snooze,
          alert_id: "alert-1",
          delivery_id: "delivery-1",
          snooze_seconds: 900
        })

      json = interaction_json(%{"actions" => [%{"action_id" => "x", "value" => value}]})

      assert {:ok, interaction} =
               Slack.decode_interaction(%{
                 params: %{"payload" => json},
                 headers: %{},
                 raw_body: ""
               })

      assert {:ok, capability} = Slack.capability(interaction)
      assert capability.action == :snooze
      assert capability.alert_id == "alert-1"
      assert capability.delivery_id == "delivery-1"
      assert capability.snooze_seconds == 900
      assert capability.external_principal == "slack:UA8RXUSPL"
      assert capability.app_id == "A0123456789"
      assert capability.action_id == "x"
    end

    test "omits a snooze duration the value did not carry" do
      assert {:ok, interaction} =
               Slack.decode_interaction(%{
                 params: %{"payload" => interaction_json()},
                 headers: %{},
                 raw_body: ""
               })

      assert {:ok, capability} = Slack.capability(interaction)

      assert capability.action == :acknowledge
      assert is_nil(capability.snooze_seconds)
    end

    test "refuses a control value naming an action it does not know" do
      json =
        interaction_json(%{
          "actions" => [%{"action_id" => "x", "value" => "delete_everything:alert-1:delivery-1"}]
        })

      assert {:ok, interaction} =
               Slack.decode_interaction(%{
                 params: %{"payload" => json},
                 headers: %{},
                 raw_body: ""
               })

      assert {:error, :unknown_action} = Slack.capability(interaction)
    end

    test "refuses a control value it cannot parse" do
      json = interaction_json(%{"actions" => [%{"action_id" => "x", "value" => "garbage"}]})

      assert {:ok, interaction} =
               Slack.decode_interaction(%{
                 params: %{"payload" => json},
                 headers: %{},
                 raw_body: ""
               })

      assert {:error, :unparseable_control_value} = Slack.capability(interaction)
    end
  end

  describe "sign/3" do
    test "produces the v0= prefixed lower-case hex digest Slack sends" do
      signature = Slack.sign(@timestamp, @body, @secret)

      assert String.starts_with?(signature, "v0=")
      assert String.length(signature) == 3 + 64
      assert signature == String.downcase(signature)
    end
  end
end
