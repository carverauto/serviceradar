defmodule ServiceRadar.OutboundMail.SmtpTlsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.OutboundMail.SmtpTls

  test "STARTTLS configs load the OS CA store so OTP 26+ will handshake" do
    config =
      SmtpTls.attach(
        relay: "smtp.example.com",
        tls: :if_available,
        ssl: false
      )

    tls_options = Keyword.fetch!(config, :tls_options)
    assert tls_options[:verify] == :verify_peer
    assert is_list(tls_options[:cacerts])
    assert tls_options[:cacerts] != []
    assert tls_options[:cacerts] != :undefined
    assert tls_options[:server_name_indication] == ~c"smtp.example.com"
    refute Keyword.has_key?(config, :sockopts)
  end

  test "implicit TLS also puts CA material on sockopts" do
    config = SmtpTls.attach(relay: "smtp.example.com", tls: :never, ssl: true)

    assert Keyword.fetch!(config, :tls_options)[:cacerts] != :undefined
    assert Keyword.fetch!(config, :sockopts)[:verify] == :verify_peer
    assert is_list(Keyword.fetch!(config, :sockopts)[:cacerts])
    assert Keyword.fetch!(config, :sockopts)[:cacerts] != []
  end

  test "plain SMTP without TLS does not inject SSL options" do
    config = SmtpTls.attach(relay: "smtp.example.com", tls: :never, ssl: false)

    refute Keyword.has_key?(config, :tls_options)
    refute Keyword.has_key?(config, :sockopts)
  end

  test "uses the HELO hostname for SNI when the relay is an IP" do
    config =
      SmtpTls.attach(
        relay: "23.138.124.21",
        hostname: "mail.serviceradar.cloud",
        tls: :always,
        ssl: false
      )

    assert Keyword.fetch!(config, :tls_options)[:server_name_indication] ==
             ~c"mail.serviceradar.cloud"
  end

  test "disables SNI when only an IP is configured" do
    config = SmtpTls.attach(relay: "23.138.124.21", tls: :always, ssl: false)

    assert Keyword.fetch!(config, :tls_options)[:server_name_indication] == :disable
    assert Keyword.fetch!(config, :tls_options)[:cacerts] != :undefined
  end
end
