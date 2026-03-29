defmodule ServiceRadarWebNGWeb.SAMLControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  alias ServiceRadarWebNGWeb.Auth.ConfigCache

  setup do
    maybe_start_config_cache()
    clear_auth_cache()

    put_saml_settings(%{
      is_enabled: true,
      mode: :active_sso,
      provider_type: :saml,
      saml_idp_metadata_xml: saml_metadata("https://127.0.0.1/sso"),
      saml_sp_entity_id: "https://demo.serviceradar.cloud"
    })

    on_exit(fn ->
      clear_auth_cache()
    end)

    :ok
  end

  test "rejects SAML login initiation when metadata-derived SSO URL violates outbound policy", %{
    conn: conn
  } do
    conn = get(conn, ~p"/auth/saml")

    assert redirected_to(conn) == ~p"/users/log-in"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "SAML authentication is not properly configured."
  end

  defp maybe_start_config_cache do
    case Process.whereis(ConfigCache) do
      nil -> start_supervised!({ConfigCache, ttl_ms: 60_000})
      _pid -> :ok
    end
  end

  defp clear_auth_cache do
    if :ets.whereis(ConfigCache) != :undefined do
      :ets.delete(ConfigCache, :auth_settings)
      ConfigCache.clear_cache()
    end
  end

  defp put_saml_settings(settings) when is_map(settings) do
    expires_at = System.monotonic_time(:millisecond) + to_timeout(minute: 5)
    :ets.insert(ConfigCache, {:auth_settings, settings, expires_at})
  end

  defp saml_metadata(sso_url) do
    """
    <md:EntityDescriptor xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata" entityID="https://idp.example.com">
      <md:IDPSSODescriptor protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">
        <md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect" Location="#{sso_url}" />
      </md:IDPSSODescriptor>
    </md:EntityDescriptor>
    """
  end
end
