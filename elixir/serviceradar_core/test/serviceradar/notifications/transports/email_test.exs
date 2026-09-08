defmodule ServiceRadar.Notifications.Transports.EmailTestMailer do
  @moduledoc """
  Stands in for `ServiceRadar.OutboundMail` in its module form.

  It exists to prove the second argument: the transport diagnoses a mailer
  configuration and then sends through *that* configuration, rather than
  resolving the settings row and its credentials a second time and possibly
  getting a different answer.
  """

  def deliver(email, config) do
    send(self(), {:mail, email, config})
    {:ok, %{id: "module-seam"}}
  end
end

defmodule ServiceRadar.Notifications.Transports.EmailTest do
  @moduledoc """
  Database-free, network-free email transport tests.

  Two seams replace the two things this transport cannot own in a unit test:

    * `opts[:mailer]` - a one-argument function standing in for
      `ServiceRadar.OutboundMail.deliver/1`. It receives the assembled
      `Swoosh.Email`, so a test that asserts on the mail is asserting on exactly
      the struct production would hand to swoosh, and no socket is opened.
    * `opts[:mailer_config]` / `opts[:mailer_diagnostic]` - the resolved
      deployment mailer. Without these the transport reads the real one, which
      is what the "a deployment with no mailer cannot save an email channel"
      test relies on.

  Everything else is the production code path: the same address validation, the
  same payload handling, the same failure classification.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.Transport
  alias ServiceRadar.Notifications.Transport.Request
  alias ServiceRadar.Notifications.Transport.Result
  alias ServiceRadar.Notifications.Transports.Email
  alias ServiceRadar.Notifications.Transports.Registry
  alias ServiceRadar.OutboundMail
  # A relay that would work, so a configuration test fails for the reason it
  # names rather than because the mailer happens to be unusable.
  alias Swoosh.Adapters.Local
  alias Swoosh.Adapters.SMTP
  alias Swoosh.Adapters.Test

  @working_mailer [adapter: SMTP, relay: "smtp.example.com", port: 587]
  @working_opts [mailer_config: @working_mailer]

  @relay_password "sup3r-s3cr3t-relay-password"

  describe "contract" do
    test "declares the mandatory capabilities and conforms to the behaviour" do
      assert :send in Email.capabilities()
      assert :test in Email.capabilities()
      assert Transport.declares_required_capabilities?(Email.capabilities())
      assert Registry.conforms?(Email)
    end

    test "is reachable through the compile-time allowlist" do
      assert {:ok, Email} = Registry.resolve("ServiceRadar.Notifications.Transports.Email")
    end

    test "does not export the legacy send/2 spelling" do
      refute function_exported?(Email, :send, 2)
    end
  end

  describe "validate_config/2 - addressing" do
    test "accepts a minimal configuration" do
      assert :ok = Email.validate_config(%{"to" => ["noc@example.com"]}, @working_opts)
    end

    test "treats blank cc and bcc as omitted, not as required addresses" do
      for blank <- ["", "   ", [], [""], [nil], [%{"email" => ""}], [%{"email" => "   "}]] do
        config = %{"to" => ["noc@example.com"], "cc" => blank, "bcc" => blank}

        assert :ok = Email.validate_config(config, @working_opts),
               "expected blank cc/bcc #{inspect(blank)} to be accepted"
      end
    end

    test "accepts names, cc, bcc, a from override, and a subject prefix" do
      config = %{
        "to" => [%{"name" => "NOC", "email" => "noc@example.com"}, "oncall@example.com"],
        "cc" => ["audit@example.com"],
        "bcc" => ["archive@example.com"],
        "from" => %{"name" => "ServiceRadar", "email" => "alerts@example.com"},
        "subject_prefix" => "[ServiceRadar]"
      }

      assert :ok = Email.validate_config(config, @working_opts)
    end

    test "rejects a missing or empty recipient list" do
      assert {:error, errors} = Email.validate_config(%{}, @working_opts)
      assert Enum.any?(errors, &(&1.field == "to"))

      assert {:error, errors} = Email.validate_config(%{"to" => []}, @working_opts)
      assert Enum.any?(errors, &(&1.field == "to"))
    end

    test "rejects an address that is not an address" do
      for bad <- ["not-an-address", "@example.com", "noc@", "noc@localhost", "a b@example.com"] do
        assert {:error, errors} = Email.validate_config(%{"to" => [bad]}, @working_opts),
               "expected #{inspect(bad)} to be rejected"

        assert Enum.any?(errors, &(&1.field == "to"))
      end
    end

    test "rejects a carriage return or line feed in an address or a display name" do
      injected = "noc@example.com\r\nBcc: attacker@example.com"

      assert {:error, errors} = Email.validate_config(%{"to" => [injected]}, @working_opts)
      assert Enum.any?(errors, &(&1.field == "to"))

      named = %{"name" => "NOC\r\nBcc: attacker@example.com", "email" => "noc@example.com"}

      assert {:error, errors} = Email.validate_config(%{"to" => [named]}, @working_opts)
      assert Enum.any?(errors, &(&1.field == "to"))
    end

    test "rejects a line break in the subject prefix" do
      config = %{"to" => ["noc@example.com"], "subject_prefix" => "[SR]\nX-Injected: 1"}

      assert {:error, errors} = Email.validate_config(config, @working_opts)
      assert Enum.any?(errors, &(&1.field == "subject_prefix"))
    end

    test "rejects an invalid from address" do
      config = %{"to" => ["noc@example.com"], "from" => "nope"}

      assert {:error, errors} = Email.validate_config(config, @working_opts)
      assert Enum.any?(errors, &(&1.field == "from"))
    end

    test "rejects deployment mail settings on a channel" do
      for key <- ~w(relay port hostname adapter username password api_key) do
        config = %{"to" => ["noc@example.com"], key => "anything"}

        assert {:error, errors} = Email.validate_config(config, @working_opts),
               "expected #{key} to be rejected"

        message = Enum.map_join(errors, " ", & &1.message)
        assert message =~ "deployment mail configuration"
      end
    end

    test "rejects a configuration that is not a map" do
      assert {:error, [%{field: nil}]} = Email.validate_config("nope", @working_opts)
    end
  end

  describe "validate_config/2 - the mailer must actually deliver" do
    test "the test adapter is refused with a diagnostic naming the variable to set" do
      opts = [mailer_config: [adapter: Test]]

      assert {:error, errors} = Email.validate_config(%{"to" => ["noc@example.com"]}, opts)

      message = mailer_message(errors)
      assert message =~ "Swoosh.Adapters.Test"
      assert message =~ "delivers nothing"
      assert message =~ "Settings > Mail"
      assert message =~ "SMTP"
    end

    test "the local development mailbox is refused with its own diagnostic" do
      opts = [mailer_config: [adapter: Local]]

      assert {:error, errors} = Email.validate_config(%{"to" => ["noc@example.com"]}, opts)

      message = mailer_message(errors)
      assert message =~ "Swoosh.Adapters.Local"
      assert message =~ "Settings > Mail"
    end

    test "an SMTP adapter with no relay names Settings > Mail" do
      opts = [mailer_config: [adapter: SMTP]]

      assert {:error, errors} = Email.validate_config(%{"to" => ["noc@example.com"]}, opts)
      assert mailer_message(errors) =~ "Settings > Mail"
      assert mailer_message(errors) =~ "relay"
    end

    test "an API adapter with no API key is refused" do
      opts = [mailer_config: [adapter: Swoosh.Adapters.Sendgrid]]

      assert {:error, errors} = Email.validate_config(%{"to" => ["noc@example.com"]}, opts)
      assert mailer_message(errors) =~ "API key"
    end

    test "an adapter that is not in the release is refused" do
      opts = [mailer_config: [adapter: Swoosh.Adapters.NotAThing]]

      assert {:error, errors} = Email.validate_config(%{"to" => ["noc@example.com"]}, opts)
      assert mailer_message(errors) =~ "not part of this release"
    end

    test "a mailer that cannot be resolved at all is reported, not assumed working" do
      opts = [mailer_diagnostic: {:error, {:mail_settings_unavailable, "broker unreachable"}}]

      assert {:error, errors} = Email.validate_config(%{"to" => ["noc@example.com"]}, opts)
      assert mailer_message(errors) =~ "broker unreachable"
    end

    # The failure this whole task exists to prevent: an email channel that saves
    # cleanly on a deployment where mail goes nowhere, and then reports every
    # delivery as sent.
    test "validate_config/1 never returns :ok on a deployment with no proven mailer" do
      assert {:error, errors} = Email.validate_config(%{"to" => ["noc@example.com"]})
      assert Enum.any?(errors, &(&1.field == nil))
      refute mailer_message(errors) == ""
    end
  end

  describe "OutboundMail.diagnose/1" do
    test "accepts a configured SMTP relay" do
      assert :ok = OutboundMail.diagnose(@working_mailer)
    end

    test "gen_smtp is present, so the SMTP adapter is usable" do
      assert Code.ensure_loaded?(:gen_smtp_client),
             "gen_smtp must be a dependency or Swoosh.Adapters.SMTP cannot send"
    end

    test "names the non-delivering adapters explicitly" do
      assert Test in OutboundMail.non_delivering_adapters()
      assert Local in OutboundMail.non_delivering_adapters()
    end

    test "reports a missing adapter" do
      assert {:error, {:mailer_not_configured, message}} = OutboundMail.diagnose([])
      assert message =~ "Settings > Mail"
    end
  end

  describe "deliver/2 - the happy path" do
    test "ships an html payload as the html body and reports delivered" do
      request =
        request(
          payload_format: :html,
          payload: %{
            "subject" => "Disk usage high",
            "body" => "<p>92%</p>",
            "html" => "<h2>Disk usage high</h2><p>92%</p>"
          },
          config: %{
            "to" => ["noc@example.com"],
            "cc" => [%{"name" => "Audit", "email" => "audit@example.com"}],
            "bcc" => ["archive@example.com"],
            "from" => %{"name" => "ServiceRadar", "email" => "alerts@example.com"},
            "subject_prefix" => "[ServiceRadar]"
          }
        )

      assert %Result{disposition: :delivered} = result = deliver(request, {:ok, %{id: "abc123"}})

      assert result.external_correlation_id == "abc123"
      assert result.result_summary["transport"] == "email"
      assert result.result_summary["recipients"] == 1

      assert_receive {:mail, email}
      assert email.to == [{"", "noc@example.com"}]
      assert email.cc == [{"Audit", "audit@example.com"}]
      assert email.bcc == [{"", "archive@example.com"}]
      assert email.from == {"ServiceRadar", "alerts@example.com"}
      assert email.subject == "[ServiceRadar] Disk usage high"
      assert email.html_body == "<h2>Disk usage high</h2><p>92%</p>"
    end

    test "ships a plain payload as the text body" do
      request =
        request(
          payload_format: :plain,
          payload: %{"subject" => "Link down", "body" => "eth0", "text" => "Link down\n\neth0"}
        )

      assert %Result{disposition: :delivered} = deliver(request, {:ok, %{}})

      assert_receive {:mail, email}
      assert email.text_body == "Link down\n\neth0"
      assert is_nil(email.html_body)
      assert email.subject == "Link down"
    end

    test "accepts a markdown payload's text" do
      request = request(payload_format: :markdown, payload: %{"text" => "**Link down**"})

      assert %Result{disposition: :delivered} = deliver(request, {:ok, %{}})
      assert_receive {:mail, email}
      assert email.text_body == "**Link down**"
    end

    test "falls back to the deployment From: when the channel does not set one" do
      request = request(config: %{"to" => ["noc@example.com"]})

      assert %Result{disposition: :delivered} = deliver(request, {:ok, %{}})

      assert_receive {:mail, email}
      assert {_name, address} = email.from
      assert address =~ "@"
    end

    test "stamps a Message-ID derived from the delivery and uses it when the provider returns none" do
      request = request(delivery_id: "delivery-42")

      assert %Result{disposition: :delivered} = result = deliver(request, {:ok, "queued as 9F2A"})

      assert_receive {:mail, email}
      message_id = email.headers["Message-ID"]
      assert message_id =~ "delivery-42@"
      assert result.external_correlation_id == message_id
    end

    test "prefers the provider's message id when there is one" do
      request = request(delivery_id: "delivery-42")

      assert %Result{external_correlation_id: "provider-7"} =
               deliver(request, {:ok, %{id: "provider-7"}})
    end

    test "strips control characters out of a rendered subject" do
      request = request(subject: "Disk\r\nBcc: attacker@example.com")

      assert %Result{disposition: :delivered} = deliver(request, {:ok, %{}})

      assert_receive {:mail, email}
      refute email.subject =~ "\r"
      refute email.subject =~ "\n"
    end

    test "sends through the mailer configuration it diagnosed, not a second resolution" do
      result =
        Email.deliver(request(),
          mailer_config: @working_mailer,
          mailer: ServiceRadar.Notifications.Transports.EmailTestMailer
        )

      assert %Result{disposition: :delivered, external_correlation_id: "module-seam"} = result

      assert_receive {:mail, _email, config}
      assert config == @working_mailer
    end

    test "test/2 marks the delivery as a test send" do
      request = request()

      assert %Result{disposition: :delivered} = result = test_send(request, {:ok, %{}})
      assert result.result_summary["test"] == true
    end
  end

  describe "deliver/2 - configuration failures are permanent" do
    test "a non-delivering adapter fails permanently and never reaches the mailer" do
      request = request()

      result =
        Email.deliver(request,
          mailer_config: [adapter: Test],
          mailer: fn _email -> send(self(), :should_not_happen) end
        )

      assert %Result{disposition: :permanent_failure} = result
      assert result.error_class == "email_non_delivering_adapter"
      assert result.error_message =~ "Settings > Mail"
      refute_received :should_not_happen
    end

    test "an unresolvable mailer is retryable, not terminal" do
      result =
        Email.deliver(request(),
          mailer_diagnostic: {:error, {:mail_settings_unavailable, "broker unreachable"}},
          mailer: fn _email -> {:ok, %{}} end
        )

      assert %Result{disposition: :retryable_failure} = result
      assert result.error_class == "email_mail_settings_unavailable"
    end

    test "a missing recipient list fails permanently" do
      request = request(config: %{})

      assert %Result{disposition: :permanent_failure, error_class: "email_invalid_config"} =
               deliver(request, {:ok, %{}})
    end

    test "a relay override on the channel fails permanently" do
      request = request(config: %{"to" => ["noc@example.com"], "relay" => "10.0.0.1"})

      assert %Result{disposition: :permanent_failure} = result = deliver(request, {:ok, %{}})
      assert result.error_message =~ "deployment mail configuration"
    end

    test "an unsupported payload format fails permanently" do
      request = request(payload_format: :slack_blocks, payload: %{"blocks" => []})

      assert %Result{disposition: :permanent_failure, error_class: "email_unsupported_payload"} =
               deliver(request, {:ok, %{}})
    end

    test "a payload with no body at all fails permanently" do
      request = request(payload_format: :plain, payload: %{"subject" => "only a subject"})

      assert %Result{disposition: :permanent_failure, error_class: "email_unsupported_payload"} =
               deliver(request, {:ok, %{}})
    end

    test "a value that is not a request fails permanently instead of raising" do
      assert %Result{disposition: :permanent_failure, error_class: "invalid_request"} =
               Email.deliver(:nonsense, [])

      assert %Result{disposition: :permanent_failure, error_class: "invalid_request"} =
               Email.test(:nonsense, [])
    end
  end

  describe "deliver/2 - failure classification" do
    test "an API adapter's 5xx is retryable" do
      assert %Result{disposition: :retryable_failure, error_class: "http_503"} =
               deliver(request(), {:error, {503, %{"message" => "unavailable"}}})
    end

    test "an API adapter's 429 is retryable" do
      assert %Result{disposition: :retryable_failure, error_class: "http_429"} =
               deliver(request(), {:error, {429, %{"message" => "slow down"}}})
    end

    test "an API adapter's 400 is permanent" do
      assert %Result{disposition: :permanent_failure, error_class: "http_400"} =
               deliver(request(), {:error, {400, %{"message" => "bad request"}}})
    end

    test "a timeout is retryable" do
      failure = {:error, {:network_failure, ~c"smtp.example.com", {:error, :timeout}}}

      assert %Result{disposition: :retryable_failure} = result = deliver(request(), failure)
      assert result.error_class == "email_network_failure"
    end

    test "a 4xx SMTP reply is retryable" do
      failure = {:error, {:temporary_failure, ~c"smtp.example.com", ~c"451 4.3.0 try later"}}

      assert %Result{disposition: :retryable_failure, error_class: "smtp_451"} =
               deliver(request(), failure)
    end

    test "a 5xx SMTP reply is permanent" do
      failure = {:error, {:permanent_failure, ~c"smtp.example.com", ~c"550 5.1.1 User unknown"}}

      assert %Result{disposition: :permanent_failure, error_class: "smtp_550"} =
               deliver(request(), failure)
    end

    test "an authentication failure is permanent" do
      failure =
        {:error, {:permanent_failure, ~c"smtp.example.com", ~c"535 5.7.8 Bad credentials"}}

      assert %Result{disposition: :permanent_failure, error_class: "smtp_535"} =
               deliver(request(), failure)

      assert %Result{disposition: :permanent_failure, error_class: "email_auth_failed"} =
               deliver(request(), {:error, :auth_failed})
    end

    test "an unclassified failure is retryable rather than terminal" do
      assert %Result{disposition: :retryable_failure, error_class: "email_delivery_failed"} =
               deliver(request(), {:error, :something_new})
    end

    test "an unexpected mailer answer is retryable and only its shape is reported" do
      assert %Result{disposition: :retryable_failure} = result = deliver(request(), :surprise)
      assert result.error_class == "email_unexpected_mailer_result"
      assert result.error_message =~ ":surprise"
    end

    test "a raising mailer does not take the dispatcher down" do
      result =
        Email.deliver(request(), mailer_config: @working_mailer, mailer: fn _ -> raise "boom" end)

      assert %Result{disposition: :retryable_failure, error_class: "transport_exception"} = result
      refute result.error_message =~ "boom"
    end

    test "the C7 table holds: retryable keeps the delivery pending, permanent is terminal" do
      retryable = deliver(request(), {:error, {503, %{}}})
      permanent = deliver(request(), {:error, {400, %{}}})

      assert Result.outcome(retryable, true) == :retry
      assert Result.outcome(retryable, false) == :failed
      assert Result.outcome(permanent, true) == :failed
    end
  end

  describe "secrets" do
    test "a resolved secret never appears in any returned value" do
      request = request(secrets: %{"password" => @relay_password})

      failure =
        {:error,
         {:permanent_failure, ~c"smtp.example.com",
          ~c"535 5.7.8 authentication failed for password " ++ String.to_charlist(@relay_password)}}

      result = deliver(request, failure)

      assert %Result{disposition: :permanent_failure} = result
      refute inspect(result) =~ @relay_password
      assert result.error_message =~ "[REDACTED]"
    end

    test "a delivered result carries no secret either" do
      request = request(secrets: %{"password" => @relay_password})

      result = deliver(request, {:ok, %{id: "abc"}})

      refute inspect(result) =~ @relay_password
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp deliver(request, answer) do
    Email.deliver(request, mailer_config: @working_mailer, mailer: mailer(answer))
  end

  defp test_send(request, answer) do
    Email.test(request, mailer_config: @working_mailer, mailer: mailer(answer))
  end

  # The seam. It captures the assembled `Swoosh.Email` so tests can assert on
  # the exact struct swoosh would have been handed, and answers with whatever
  # the test wants swoosh to have answered.
  defp mailer(answer) do
    owner = self()

    fn email ->
      send(owner, {:mail, email})
      answer
    end
  end

  defp request(overrides \\ []) do
    defaults = [
      delivery_id: "delivery-1",
      channel_id: "channel-1",
      payload_format: :plain,
      payload: %{"subject" => "Test alert", "body" => "body", "text" => "Test alert\n\nbody"},
      subject: nil,
      config: %{"to" => ["noc@example.com"], "from" => "alerts@example.com"},
      secrets: %{}
    ]

    struct!(Request, Keyword.merge(defaults, overrides))
  end

  defp mailer_message(errors) do
    errors
    |> Enum.filter(&(&1.field == nil))
    |> Enum.map_join(" ", & &1.message)
  end
end
