defmodule ServiceRadar.OutboundMail.RuntimeConfigTest do
  @moduledoc """
  The mailer environment, tested as a pure function of an environment map.

  `config/runtime.exs` is the one place a deployment's mailer is decided and the
  one place that is hardest to test, so the decision lives here instead and both
  releases call it. Passing an explicit map rather than mutating `System.put_env`
  is what keeps this `async: true`.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.OutboundMail.RuntimeConfig
  alias Swoosh.Adapters.Local

  describe "adapter selection" do
    test "a relay host alone selects SMTP" do
      config = RuntimeConfig.mailer_config(%{"SMTP_RELAY_HOST" => "smtp.example.com"})

      assert config[:adapter] == Swoosh.Adapters.SMTP
      assert config[:relay] == "smtp.example.com"
      assert config[:port] == 587
    end

    test "an explicit adapter name wins" do
      env = %{
        "SERVICERADAR_MAILER_ADAPTER" => "sendgrid",
        "SMTP_RELAY_HOST" => "smtp.example.com"
      }

      assert RuntimeConfig.mailer_config(env)[:adapter] == Swoosh.Adapters.Sendgrid
    end

    test "the core-specific variable takes precedence over the shared one" do
      env = %{
        "SERVICERADAR_CORE_MAILER_ADAPTER" => "local",
        "SERVICERADAR_MAILER_ADAPTER" => "smtp"
      }

      assert RuntimeConfig.mailer_config(env)[:adapter] == Local
    end

    test "SERVICERADAR_LOCAL_MAILER still selects the development mailbox" do
      env = %{"SERVICERADAR_LOCAL_MAILER" => "true"}

      assert RuntimeConfig.mailer_config(env)[:adapter] == Local
      assert RuntimeConfig.local?(env)
    end

    test "nothing configured resolves to the test adapter, exactly as before" do
      assert RuntimeConfig.mailer_config(%{})[:adapter] == Swoosh.Adapters.Test
      refute RuntimeConfig.local?(%{})
    end

    # A typo here silently stops a deployment sending mail, so it fails to boot
    # instead - and the message lists what it would have accepted.
    test "an unknown adapter name raises rather than falling back" do
      env = %{"SERVICERADAR_MAILER_ADAPTER" => "Elixir.System"}

      assert_raise ArgumentError, ~r/not a supported outbound mail adapter/, fn ->
        RuntimeConfig.mailer_config(env)
      end
    end

    test "an adapter name is never turned into an atom" do
      env = %{
        "SERVICERADAR_MAILER_ADAPTER" => "definitely.not.a.module.#{System.unique_integer()}"
      }

      assert_raise ArgumentError, fn -> RuntimeConfig.mailer_config(env) end
    end
  end

  describe "SMTP relay options" do
    test "carries the full relay configuration" do
      env = %{
        "SMTP_RELAY_HOST" => "smtp.example.com",
        "SMTP_RELAY_PORT" => "465",
        "SMTP_RELAY_HOSTNAME" => "core.example.com",
        "SMTP_RELAY_USERNAME" => "serviceradar",
        "SMTP_RELAY_PASSWORD" => "s3cret-value",
        "SMTP_RELAY_AUTH" => "always",
        "SMTP_RELAY_TLS" => "never",
        "SMTP_RELAY_SSL" => "true",
        "SERVICERADAR_MAIL_FROM_NAME" => "NOC",
        "SERVICERADAR_MAIL_FROM_EMAIL" => "noc@example.com"
      }

      config = RuntimeConfig.mailer_config(env)

      assert config[:relay] == "smtp.example.com"
      assert config[:port] == 465
      assert config[:hostname] == "core.example.com"
      assert config[:username] == "serviceradar"
      assert config[:password] == "s3cret-value"
      assert config[:auth] == :always
      assert config[:tls] == :never
      assert config[:ssl] == true
      assert config[:from_name] == "NOC"
      assert config[:from_email] == "noc@example.com"
      assert config[:sockopts][:verify] == :verify_peer
      assert is_list(config[:sockopts][:cacerts])
      assert config[:sockopts][:cacerts] != []
    end

    test "STARTTLS relay configs include CA certs for verify_peer" do
      config = RuntimeConfig.mailer_config(%{"SMTP_RELAY_HOST" => "smtp.example.com"})

      assert config[:tls] == :if_available
      assert config[:tls_options][:verify] == :verify_peer
      assert is_list(config[:tls_options][:cacerts])
      assert config[:tls_options][:cacerts] != []
      refute Keyword.has_key?(config, :sockopts)
    end

    test "omits credentials that were not supplied" do
      config = RuntimeConfig.mailer_config(%{"SMTP_RELAY_HOST" => "smtp.example.com"})

      refute Keyword.has_key?(config, :username)
      refute Keyword.has_key?(config, :password)
    end

    test "a blank variable counts as absent" do
      env = %{"SMTP_RELAY_HOST" => "smtp.example.com", "SMTP_RELAY_USERNAME" => "   "}

      refute Keyword.has_key?(RuntimeConfig.mailer_config(env), :username)
    end

    test "an unparseable port falls back to the default rather than crashing the boot" do
      env = %{"SMTP_RELAY_HOST" => "smtp.example.com", "SMTP_RELAY_PORT" => "not-a-port"}

      assert RuntimeConfig.mailer_config(env)[:port] == 587
    end

    test "carries no relay options when the adapter is not SMTP" do
      env = %{"SERVICERADAR_MAILER_ADAPTER" => "local", "SMTP_RELAY_HOST" => "smtp.example.com"}

      refute Keyword.has_key?(RuntimeConfig.mailer_config(env), :relay)
    end
  end

  describe "the result is what OutboundMail.diagnose/1 judges" do
    test "a configured relay passes" do
      config = RuntimeConfig.mailer_config(%{"SMTP_RELAY_HOST" => "smtp.example.com"})

      assert :ok = ServiceRadar.OutboundMail.diagnose(config)
    end

    test "an unconfigured deployment is reported, not silently accepted" do
      config = RuntimeConfig.mailer_config(%{})

      assert {:error, {:non_delivering_adapter, message}} =
               ServiceRadar.OutboundMail.diagnose(config)

      assert message =~ "Settings > Mail"
    end
  end
end
