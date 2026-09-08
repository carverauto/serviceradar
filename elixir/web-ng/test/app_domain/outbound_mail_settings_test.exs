defmodule ServiceRadarWebNG.OutboundMailSettingsTest do
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Integrations.OutboundMailSettings
  alias ServiceRadar.OutboundMail

  test "stores local mail credentials encrypted and reloads them for delivery config" do
    {:ok, settings} = OutboundMailSettings.get_settings(actor: system_actor())

    assert {:ok, updated} =
             settings
             |> Ash.Changeset.for_update(
               :update,
               %{
                 enabled: true,
                 adapter: "smtp",
                 relay: "smtp.example.test",
                 port: 587,
                 username: "mailer",
                 password: "smtp-secret",
                 api_key: "provider-secret"
               },
               actor: system_actor()
             )
             |> Ash.update(actor: system_actor())

    assert updated.password == "smtp-secret"
    assert updated.api_key == "provider-secret"
    assert is_binary(Map.get(updated, :encrypted_password))
    assert is_binary(Map.get(updated, :encrypted_api_key))
    refute Map.get(updated, :encrypted_password) == "smtp-secret"
    refute Map.get(updated, :encrypted_api_key) == "provider-secret"

    {:ok, reloaded} = OutboundMailSettings.get_settings(actor: system_actor())
    assert reloaded.password == "smtp-secret"
    assert reloaded.api_key == "provider-secret"

    assert {:ok, config} = OutboundMail.config(reloaded)
    assert Keyword.fetch!(config, :password) == "smtp-secret"
    assert Keyword.fetch!(config, :api_key) == "provider-secret"
  end
end
