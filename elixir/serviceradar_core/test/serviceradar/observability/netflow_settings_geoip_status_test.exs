defmodule ServiceRadar.Observability.NetflowSettingsGeoipStatusTest do
  use ServiceRadar.DataCase, async: true

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Observability.NetflowSettings
  alias ServiceRadar.Repo.Migrations.MoveCoreOtxCredentialToInventory
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "system actor can persist enrichment status fields" do
    actor = SystemActor.system(:netflow_geoip_test)
    settings = ensure_settings(actor)

    now = DateTime.truncate(DateTime.utc_now(), :second)

    assert {:ok, %NetflowSettings{} = updated} =
             NetflowSettings.update_enrichment_status(
               settings,
               %{geolite_mmdb_last_attempt_at: now, geolite_mmdb_last_error: "boom"},
               actor: actor
             )

    assert updated.geolite_mmdb_last_attempt_at
    assert updated.geolite_mmdb_last_error == "boom"

    assert {:ok, %NetflowSettings{} = fetched} = NetflowSettings.get_settings(actor: actor)
    assert fetched.geolite_mmdb_last_attempt_at
    assert fetched.geolite_mmdb_last_error == "boom"
  end

  test "admin with permission can read/update settings but cannot update enrichment status" do
    system = SystemActor.system(:netflow_geoip_test_seed)
    settings = ensure_settings(system)

    admin = %{id: "user:admin", role: :admin, permissions: ["settings.netflow.manage"]}

    assert {:ok, %NetflowSettings{} = fetched} = NetflowSettings.get_settings(actor: admin)
    assert fetched.id == settings.id

    # Admin updates normal settings.
    assert {:ok, %NetflowSettings{} = updated} =
             NetflowSettings.update_settings(fetched, %{geoip_enabled: false}, actor: admin)

    assert updated.geoip_enabled == false

    # Only system actors may write status fields.
    assert {:error, %Forbidden{}} =
             NetflowSettings.update_enrichment_status(
               updated,
               %{ip_enrichment_last_error: "nope"},
               actor: admin
             )
  end

  test "legacy OTX ciphertext migrates to a guarded reusable credential without key re-entry" do
    actor = SystemActor.system(:otx_credential_upgrade_test)
    settings = ensure_settings(actor)
    token = "invented-otx-upgrade-token"
    ciphertext = AshCloak.do_encrypt(NetflowSettings, :otx_api_key, token)

    ServiceRadar.Repo.query!(
      "UPDATE platform.netflow_settings SET encrypted_otx_api_key = $1, otx_credential_secret_id = NULL WHERE id = $2",
      [ciphertext, Ecto.UUID.dump!(settings.id)]
    )

    Code.require_file(
      "../../../priv/repo/migrations/20261005150102_move_core_otx_credential_to_inventory.exs",
      __DIR__
    )

    MoveCoreOtxCredentialToInventory.migrate_legacy_tokens(ServiceRadar.Repo)
    MoveCoreOtxCredentialToInventory.migrate_legacy_tokens(ServiceRadar.Repo)

    assert {:ok, %NetflowSettings{} = migrated} = NetflowSettings.get_settings(actor: actor)
    assert migrated.encrypted_otx_api_key == nil
    assert migrated.otx_api_key_present

    assert {:ok, secret} =
             NetworkCredentialSecret.get_by_id(migrated.otx_credential_secret_id, actor: actor)

    assert {:error, deletion_error} =
             secret
             |> Ash.Changeset.for_destroy(:destroy_permanently, %{confirm_secret_id: secret.id})
             |> Ash.destroy(actor: actor)

    assert Exception.message(deletion_error) =~ "credential_in_use"

    assert {:ok, ^token} =
             ServiceRadar.Inventory.AdvisoryFeeds.CredentialResolver.resolve_otx(
               migrated.otx_credential_secret_id
             )

    assert {:ok, usage} =
             ServiceRadar.Credentials.CredentialUsage.for_secret(
               migrated.otx_credential_secret_id,
               actor: actor
             )

    assert Enum.any?(usage.consumers, &(&1.kind == :otx_settings and &1.id == settings.id))

    manager = %{
      id: "credential-manager",
      role: :admin,
      permissions: ["settings.netflow.manage", "settings.credentials.manage"]
    }

    assert {:ok, %NetflowSettings{} = cleared} =
             NetflowSettings.update_settings(migrated, %{otx_credential_secret_id: nil},
               actor: manager
             )

    assert cleared.otx_credential_secret_id == nil

    assert {:ok, %NetflowSettings{} = refetched} = NetflowSettings.get_settings(actor: manager)
    refute refetched.otx_api_key_present
    # Clearing the consumer reference never deletes or decrypts the inventory credential.
    assert {:ok, %{id: id}} =
             NetworkCredentialSecret.get_by_id(migrated.otx_credential_secret_id, actor: manager)

    assert id == migrated.otx_credential_secret_id
  end

  test "actor without settings permission cannot read settings" do
    system = SystemActor.system(:netflow_geoip_test_seed)
    _settings = ensure_settings(system)

    viewer = %{id: "user:viewer", role: :viewer, permissions: []}

    assert_denied(NetflowSettings.get_settings(actor: viewer))
  end

  defp ensure_settings(actor) do
    case NetflowSettings.get_settings(actor: actor) do
      {:ok, %NetflowSettings{} = s} ->
        s

      _ ->
        case NetflowSettings.create(%{}, actor: actor) do
          {:ok, %NetflowSettings{} = s} -> s
          other -> flunk("failed to create netflow settings: #{inspect(other)}")
        end
    end
  end

  defp assert_denied({:error, %Forbidden{}}), do: :ok

  # Ash policies may "filter" rather than raise forbidden for reads, which results in NotFound.
  defp assert_denied({:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}}),
    do: :ok

  defp assert_denied(other), do: flunk("expected access denied, got: #{inspect(other)}")
end
