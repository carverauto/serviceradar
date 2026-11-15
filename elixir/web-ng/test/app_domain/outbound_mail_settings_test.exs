defmodule ServiceRadarWebNG.OutboundMailSettingsTest do
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Integrations.OutboundMailSettings
  alias ServiceRadar.OutboundMail

  @moduletag :web_ng_shared_fixture_db

  # Whitespace at either end is part of a credential, so the values carry it to
  # prove they reach the relay exactly as entered.
  test "stores local mail credentials encrypted and reloads them for delivery config" do
    username = " mailer "
    password = "  smtp-secret\t"
    api_key = " provider-secret\n"

    # A missing settings row is "no operator override", not a failure, so the
    # test owns its row before exercising the update path.
    {:ok, settings} =
      case OutboundMailSettings.get_settings(actor: system_actor()) do
        {:ok, settings} -> {:ok, settings}
        {:error, _} -> OutboundMailSettings.create(%{}, actor: system_actor())
      end

    assert {:ok, updated} =
             settings
             |> Ash.Changeset.for_update(
               :update,
               %{
                 enabled: true,
                 adapter: "smtp",
                 relay: "smtp.example.test",
                 port: 587,
                 username: username,
                 password: password,
                 api_key: api_key
               },
               actor: system_actor()
             )
             |> Ash.update(actor: system_actor())

    assert updated.password == password
    assert updated.api_key == api_key
    assert is_binary(Map.get(updated, :encrypted_password))
    assert is_binary(Map.get(updated, :encrypted_api_key))
    refute Map.get(updated, :encrypted_password) == password
    refute Map.get(updated, :encrypted_api_key) == api_key

    {:ok, reloaded} = OutboundMailSettings.get_settings(actor: system_actor())
    assert reloaded.username == username
    assert reloaded.password == password
    assert reloaded.api_key == api_key

    assert {:ok, config} = OutboundMail.config(reloaded)
    assert Keyword.fetch!(config, :username) == username
    assert Keyword.fetch!(config, :password) == password
    assert Keyword.fetch!(config, :api_key) == api_key
  end
end
