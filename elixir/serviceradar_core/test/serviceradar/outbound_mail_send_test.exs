defmodule ServiceRadar.OutboundMailSendTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Integrations.OutboundMailSettings
  alias ServiceRadar.OutboundMail
  alias Swoosh.Adapters.SMTP

  @moduletag :unit

  test "refuses Local because it never leaves the deployment" do
    settings = settings(adapter: "local")

    assert {:error, {:non_delivering_adapter, message}} =
             OutboundMail.send_test(settings, "ops@example.com")

    assert message =~ "Local"
  end

  test "refuses Test because it reports success and delivers nothing" do
    settings = settings(adapter: "test")

    assert {:error, {:non_delivering_adapter, message}} =
             OutboundMail.send_test(settings, "ops@example.com")

    assert message =~ "Test"
  end

  test "refuses a disabled settings row" do
    settings = settings(enabled: false, adapter: "smtp", relay: "smtp.example.com")

    assert {:error, {:disabled, message}} = OutboundMail.send_test(settings, "ops@example.com")
    assert message =~ "disabled"
  end

  test "refuses a blank or malformed recipient" do
    settings = settings(adapter: "smtp", relay: "smtp.example.com")

    assert {:error, {:invalid_recipient, _}} = OutboundMail.send_test(settings, "")
    assert {:error, {:invalid_recipient, _}} = OutboundMail.send_test(settings, "not-an-email")
  end

  test "sends through the saved SMTP config when diagnose is clean" do
    settings =
      settings(
        adapter: "smtp",
        relay: "smtp.example.com",
        from_name: "ServiceRadar Alerts",
        from_email: "alerts@example.com"
      )

    owner = self()

    assert {:ok, :accepted} =
             OutboundMail.send_test(settings, "ops@example.com",
               deliver: fn email, config ->
                 send(owner, {:mail, email, config})
                 {:ok, :accepted}
               end
             )

    assert_receive {:mail, email, config}
    assert email.to == [{"", "ops@example.com"}]
    assert email.from == {"ServiceRadar Alerts", "alerts@example.com"}
    assert email.subject == "ServiceRadar outbound mail test"
    assert email.text_body =~ "Adapter: smtp"
    assert Keyword.fetch!(config, :adapter) == SMTP
    assert Keyword.fetch!(config, :relay) == "smtp.example.com"
    assert Keyword.fetch!(config, :tls_options)[:verify] == :verify_peer
    assert is_list(Keyword.fetch!(config, :tls_options)[:cacerts])
    assert Keyword.fetch!(config, :tls_options)[:cacerts] != :undefined
  end

  test "uses SMTP hostname as the relay when relay is blank" do
    settings =
      settings(
        adapter: "smtp",
        relay: nil,
        hostname: "mail.serviceradar.cloud",
        from_email: "noreply@serviceradar.cloud"
      )

    owner = self()

    assert {:ok, :accepted} =
             OutboundMail.send_test(settings, "ops@example.com",
               deliver: fn email, config ->
                 send(owner, {:mail, email, config})
                 {:ok, :accepted}
               end
             )

    assert_receive {:mail, _email, config}
    assert Keyword.fetch!(config, :relay) == "mail.serviceradar.cloud"
  end

  test "translates a sender-ownership reject into an operator sentence" do
    settings =
      settings(
        adapter: "smtp",
        hostname: "mail.serviceradar.cloud",
        username: "farm01@serviceradar.cloud",
        from_email: "noreply@serviceradar.cloud"
      )

    assert {:error, {:delivery_failed, message}} =
             OutboundMail.send_test(settings, "ops@example.com",
               deliver: fn _email, _config ->
                 {:error,
                  {:send,
                   {:permanent_failure, ~c"23.138.124.21",
                    ~c"553 5.7.1 <noreply@serviceradar.cloud>: Sender address rejected: not owned by user farm01@serviceradar.cloud\r\n"}}}
               end
             )

    assert message =~ "553 5.7.1"
    assert message =~ "not owned by user farm01@serviceradar.cloud"
    assert message =~ "Set From email to farm01@serviceradar.cloud"
  end

  defp settings(overrides) do
    defaults = [
      enabled: true,
      adapter: "smtp",
      from_name: "ServiceRadar",
      from_email: "noreply@serviceradar.cloud",
      relay: nil,
      port: 587,
      hostname: nil,
      username: nil,
      password: nil,
      api_key: nil,
      auth: "if_available",
      tls: "if_available",
      ssl: false,
      retries: 1,
      provider_options: %{}
    ]

    struct!(OutboundMailSettings, Keyword.merge(defaults, overrides))
  end
end
