defmodule ServiceRadarWebNGWeb.Settings.NotificationsTestSendTest do
  @moduledoc """
  Test-send payload assembly for secretRef providers.

  Discord (and Slack) persist `webhook_url` as a credential reference. The
  editor test path used to drop a just-typed URL into `Request.secrets` and
  then call `validate_config/1` on the remaining document, which reports
  "webhook_url is required" even though the operator just typed one.
  """

  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.TestSend

  @moduletag :db_free

  @discord_module "ServiceRadar.Notifications.Transports.Discord"
  @public_webhook "https://93.184.216.34/api/webhooks/1234567890/abcdefghijklmnopqrstuvwxyz012345"
  @loopback_webhook "https://127.0.0.1/api/webhooks/1234567890/abcdefghijklmnopqrstuvwxyz012345"
  @stored_ref "credentialref:network-credential-secret:cred-123"

  defp discord_provider do
    %{
      provider_type: :native,
      provider_key: "discord",
      implementation_module: @discord_module,
      payload_formats: [:discord_embed, :markdown, :plain],
      definition_version: 1
    }
  end

  test "a just-typed Discord webhook is not rejected as a missing credential reference" do
    assert {:error, outcome} =
             TestSend.run(discord_provider(), %{}, %{"webhook_url" => @loopback_webhook})

    refute outcome.detail =~ "is required"
    refute outcome.headline == "Configuration is not valid"
    assert outcome.headline == "Outbound URL refused"
    assert outcome.detail =~ "webhook_url: the host is not allowed"
  end

  test "a stored credential reference is not treated as an outbound URL" do
    # public_base_url/0 falls back to Endpoint.url/0. That raises when the
    # endpoint is not started; bazel unit_tests_phoenix_live runs --no-start.
    assert {:error, outcome} =
             TestSend.run(discord_provider(), %{"webhook_url" => @stored_ref}, %{})

    refute outcome.headline == "Outbound URL refused"
    refute outcome.headline == "Configuration is not valid"
    refute outcome.headline == "The test notification could not be rendered"
    assert outcome.detail =~ "webhook_url"
  end

  test "a public typed webhook proceeds past persist-time config validation" do
    # No broker stub: resolution fails after validate_config accepts the stand-in
    # reference. That is the contract this test locks - not a live Discord post.
    assert {:error, outcome} =
             TestSend.run(discord_provider(), %{}, %{"webhook_url" => @public_webhook})

    refute outcome.headline == "Configuration is not valid"
    refute outcome.headline == "Provider transport unavailable"
    refute outcome.detail =~ "is required and must be a stored credential reference"
  end
end
