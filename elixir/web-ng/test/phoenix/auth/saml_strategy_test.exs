defmodule ServiceRadarWebNGWeb.Auth.SAMLStrategyTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.Auth.SAMLStrategy

  @moduletag :db_free

  setup do
    maybe_start_config_cache()

    on_exit(fn ->
      if :ets.whereis(ConfigCache) != :undefined do
        :ets.delete(ConfigCache, :auth_settings)
        ConfigCache.clear_cache()
      end
    end)

    :ok
  end

  test "rejects metadata with external entities" do
    malicious_xml = """
    <!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
    <md:EntityDescriptor xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata" entityID="&xxe;">
      <md:IDPSSODescriptor protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol" />
    </md:EntityDescriptor>
    """

    put_saml_settings(%{
      is_enabled: true,
      mode: :active_sso,
      provider_type: :saml,
      saml_sp_entity_id: "https://sp.example.com",
      saml_idp_metadata_xml: malicious_xml
    })

    assert {:error, :invalid_metadata} = SAMLStrategy.get_config()
  end

  test "accepts normal metadata and extracts the entity id" do
    xml = """
    <md:EntityDescriptor xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata" entityID="https://idp.example.com/metadata">
      <md:IDPSSODescriptor protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol" />
    </md:EntityDescriptor>
    """

    put_saml_settings(%{
      is_enabled: true,
      mode: :active_sso,
      provider_type: :saml,
      saml_sp_entity_id: "https://sp.example.com",
      saml_idp_metadata_xml: xml
    })

    assert {:ok, config} = SAMLStrategy.get_config()
    assert config.idp_entity_id == "https://idp.example.com/metadata"
  end

  # The database-free tier does not start the application, so the PubSub
  # server ConfigCache subscribes to may not exist yet.
  defp maybe_start_config_cache do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    if is_nil(Process.whereis(ServiceRadar.PubSub)) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    case Process.whereis(ConfigCache) do
      nil -> start_supervised!({ConfigCache, ttl_ms: 60_000})
      _pid -> :ok
    end
  end

  # AuthSettings carries every field; build_config/1 reads the optional ones.
  defp put_saml_settings(settings) do
    settings = Map.merge(%{claim_mappings: nil, saml_pinned_cert_fingerprints: nil}, settings)
    expires_at = System.monotonic_time(:millisecond) + to_timeout(minute: 5)
    :ets.insert(ConfigCache, {:auth_settings, settings, expires_at})
  end
end
