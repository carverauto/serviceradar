defmodule ServiceRadar.Inventory.AdvisoryFeeds.CredentialResolverTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.CredentialResolver

  @secret_id "018f3f56-1111-7222-8333-123456789abc"

  test "core feeds resolve credential UUIDs through provider-scoped audited broker grants" do
    test_pid = self()
    for {resolve, provider, host, purpose} <- [
      {&CredentialResolver.resolve/2, "vulncheck", "api.vulncheck.com", "vulnerability_feed_download"},
      {&CredentialResolver.resolve_otx/2, "alienvault-otx-core", "otx.alienvault.com", "threat_intel_sync"}
    ] do
      issuer = fn attrs, _actor ->
        send(test_pid, {:grant_attrs, attrs})
        {:ok, Map.merge(attrs, %{id: "grant-1", status: :issued})}
      end
      resolver = fn grant, opts ->
        send(test_pid, {:resolve, grant, opts})
        {:ok, %{value: "  token-value  ", secret: %{provider: provider, credential_kind: :api_token}}}
      end
      assert {:ok, "token-value"} = resolve.(@secret_id, grant_issuer: issuer, secret_resolver: resolver)
      assert_received {:grant_attrs, %{secret_id: @secret_id, allowed_hosts: [^host],
        allowed_methods: ["GET"], allowed_ports: [443], purpose: ^purpose,
        consumer_kind: :service_monitoring, resolution_location: :control_plane}}
      assert_received {:resolve, %{secret_id: @secret_id}, opts}
      assert opts[:audit?]
      wrong_provider = fn _grant, _opts ->
        {:ok, %{value: "wrong-token", secret: %{provider: "proxmox", credential_kind: :api_token}}}
      end
      assert {:error, :invalid_vulncheck_credential} = resolve.(@secret_id, grant_issuer: issuer, secret_resolver: wrong_provider)
    end
  end

  test "accepts the retired producer's legacy network credential reference" do
    ref = "credentialref:network-credential-secret:#{@secret_id}"
    assert {:ok, @secret_id} = CredentialResolver.credential_secret_id(ref)
  end

  test "rejects plaintext and non-VulnCheck credentials" do
    assert {:error, :invalid_vulncheck_credential_ref} =
             CredentialResolver.resolve("plaintext-token")

    resolver = fn _grant, _opts ->
      {:ok, %{value: "secret", secret: %{provider: "proxmox", credential_kind: :api_token}}}
    end

    issuer = fn attrs, _actor -> {:ok, Map.put(attrs, :status, :issued)} end

    assert {:error, :invalid_vulncheck_credential} =
             CredentialResolver.resolve(@secret_id,
               grant_issuer: issuer,
               secret_resolver: resolver
             )
  end
end
