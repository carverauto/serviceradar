defmodule ServiceRadar.Observability.NetflowSettingsGeoipStatusTest do
  use ExUnit.Case, async: false

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.NetflowSettings
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

  test "admin can set and clear encrypted OTX API key" do
    system = SystemActor.system(:netflow_otx_settings_test_seed)
    settings = ensure_settings(system)
    admin = %{id: "user:admin", role: :admin, permissions: ["settings.netflow.manage"]}
    token = "otx_test_token_#{System.unique_integer([:positive])}"

    assert {:ok, %NetflowSettings{} = updated} =
             NetflowSettings.update_settings(
               settings,
               %{
                 otx_enabled: true,
                 otx_execution_mode: "core_worker",
                 otx_api_key: token,
                 otx_base_url: "https://otx.alienvault.com",
                 otx_retrohunt_window_seconds: 7_776_000
               },
               actor: admin
             )

    assert updated.otx_enabled == true
    assert updated.otx_execution_mode == "core_worker"
    assert updated.otx_api_key == token
    assert is_binary(updated.encrypted_otx_api_key)
    refute updated.encrypted_otx_api_key == token

    assert {:ok, %NetflowSettings{} = fetched} = NetflowSettings.get_settings(actor: admin)
    assert fetched.otx_api_key == token
    assert fetched.otx_api_key_present == true

    assert {:ok, %NetflowSettings{}} =
             NetflowSettings.update_settings(
               fetched,
               %{clear_otx_api_key: true},
               actor: admin
             )

    assert {:ok, %NetflowSettings{} = cleared} = NetflowSettings.get_settings(actor: admin)
    refute cleared.otx_api_key_present
    assert cleared.otx_api_key in [nil, ""]
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
