defmodule ServiceRadar.Plugins.CredentialBrokerDeliveryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Plugins.CredentialBrokerDelivery

  @secret_id "018f3f56-1111-7222-8333-123456789abc"
  @secret_ref "credentialref:network-credential-secret:" <> @secret_id

  defp grant_payload(expires_at, extras \\ %{}) do
    Map.merge(
      %{
        "schema" => "serviceradar.edge_credential_broker_grant.v1",
        "grant_id" => "grant-old",
        "grant_type" => "proxmox_api_token",
        "credential_secret_ref" => @secret_ref,
        "consumer" => %{
          "kind" => "plugin",
          "id" => "proxmox-inventory",
          "purpose" => "inventory_enrichment"
        },
        "target" => %{"agent_id" => "agent-sr-test-pve04"},
        "resolution_location" => "agent",
        "inject" => %{
          "type" => "http_header",
          "name" => "Authorization",
          "scheme" => "PVEAPIToken"
        },
        "allow" => %{"methods" => ["GET"], "paths" => ["/api2/json/nodes"]},
        "ttl_seconds" => 300,
        "expires_at" => DateTime.to_iso8601(expires_at)
      },
      extras
    )
  end

  defp issuer_returning(grant_holder \\ nil) do
    parent = self()

    fn attrs, _actor ->
      issued =
        attrs
        |> CredentialBrokerGrant.issue_attrs()
        |> Map.put(:id, "grant-new")
        |> Map.put(:status, :issued)

      send(parent, {:issued, attrs, issued})
      if grant_holder, do: send(grant_holder, {:issued, issued})
      {:ok, issued}
    end
  end

  defp refuse_loader, do: fn _grant_id, _actor -> {:error, :not_found} end

  test "params without a broker payload pass through untouched" do
    params = %{"api_token_secret_ref" => @secret_ref, "timeout_ms" => 1000}

    assert {^params, nil} = CredentialBrokerDelivery.refresh_embedded_grant(params)
  end

  test "expired embedded grant payload is re-minted before delivery" do
    expired = DateTime.add(DateTime.utc_now(), -3600, :second)

    params = %{
      "credential_broker" => grant_payload(expired, %{"auth_method" => "proxmox_api_token"}),
      "api_token_secret_ref" => @secret_ref
    }

    {refreshed, grant} =
      CredentialBrokerDelivery.refresh_embedded_grant(params,
        grant_issuer: issuer_returning(),
        grant_loader: refuse_loader()
      )

    assert_receive {:issued, attrs, _issued}
    assert attrs.secret_id == @secret_id
    assert attrs.secret_ref == @secret_ref
    assert attrs.consumer_kind == :plugin
    assert attrs.consumer_id == "proxmox-inventory"
    assert attrs.purpose == "inventory_enrichment"
    assert attrs.agent_id == "agent-sr-test-pve04"
    assert attrs.resolution_location == :agent
    assert attrs.allowed_methods == ["GET"]
    assert attrs.allowed_paths == ["/api2/json/nodes"]
    assert attrs.ttl_seconds == 300

    assert grant.id == "grant-new"

    delivered = refreshed["credential_broker"]
    assert delivered["grant_id"] == "grant-new"
    # never embed expired material: the re-minted expiry must be in the future
    assert {:ok, delivered_expiry, _offset} = DateTime.from_iso8601(delivered["expires_at"])
    assert DateTime.after?(delivered_expiry, DateTime.utc_now())
    # caller extras on the stored payload survive the re-mint
    assert delivered["auth_method"] == "proxmox_api_token"
    # untouched sibling fields stay
    assert refreshed["api_token_secret_ref"] == @secret_ref
  end

  test "fresh embedded grant is reused without re-minting" do
    future = DateTime.add(DateTime.utc_now(), 600, :second)
    payload = grant_payload(future)

    loaded_grant = %{
      id: "grant-old",
      status: :issued,
      secret_id: @secret_id,
      secret_ref: @secret_ref,
      agent_id: "agent-sr-test-pve04",
      resolution_location: :agent,
      expires_at: future
    }

    params = %{"credential_broker" => payload, "api_token_secret_ref" => @secret_ref}

    {refreshed, grant} =
      CredentialBrokerDelivery.refresh_embedded_grant(params,
        grant_issuer: fn _attrs, _actor -> flunk("must not re-mint a fresh grant") end,
        grant_loader: fn "grant-old", _actor -> {:ok, loaded_grant} end
      )

    assert refreshed["credential_broker"] == payload
    assert grant.id == "grant-old"
  end

  test "fresh payload whose persisted grant is missing or inactive is re-minted" do
    future = DateTime.add(DateTime.utc_now(), 600, :second)
    params = %{"credential_broker" => grant_payload(future)}

    {refreshed, grant} =
      CredentialBrokerDelivery.refresh_embedded_grant(params,
        grant_issuer: issuer_returning(),
        grant_loader: fn "grant-old", _actor ->
          {:ok, %{id: "grant-old", status: :revoked, expires_at: future}}
        end
      )

    assert grant.id == "grant-new"
    assert refreshed["credential_broker"]["grant_id"] == "grant-new"
  end

  test "broker payload nested under a plugin-inputs template is refreshed in place" do
    expired = DateTime.add(DateTime.utc_now(), -10, :second)

    params = %{
      "schema" => "serviceradar.plugin_inputs.v1",
      "agent_id" => "agent-sr-test-pve04",
      "inputs" => [],
      "template" => %{
        "credential_broker" => grant_payload(expired),
        "api_token_secret_ref" => @secret_ref
      }
    }

    {refreshed, grant} =
      CredentialBrokerDelivery.refresh_embedded_grant(params,
        grant_issuer: issuer_returning(),
        grant_loader: refuse_loader()
      )

    assert grant.id == "grant-new"
    assert refreshed["template"]["credential_broker"]["grant_id"] == "grant-new"
    assert refreshed["template"]["api_token_secret_ref"] == @secret_ref
    assert refreshed["inputs"] == []
  end

  test "broker payloads nested under controllers are refreshed independently" do
    expired = DateTime.add(DateTime.utc_now(), -10, :second)

    params = %{
      "controllers" => [
        %{
          "controller_id" => "ctrl-1",
          "credential_broker" => grant_payload(expired),
          "api_token_secret_ref" => @secret_ref
        },
        %{
          "controller_id" => "ctrl-2",
          "api_token_secret_ref" => @secret_ref
        }
      ]
    }

    {refreshed, grants} =
      CredentialBrokerDelivery.refresh_controller_grants(params,
        grant_issuer: issuer_returning(),
        grant_loader: refuse_loader()
      )

    assert [{0, %{id: "grant-new"}}] = grants

    assert refreshed["controllers"] |> hd() |> get_in(["credential_broker", "grant_id"]) ==
             "grant-new"

    assert refreshed["controllers"] |> Enum.at(1) |> Map.get("credential_broker") == nil
  end

  test "grant issuer failure leaves params untouched and yields no grant" do
    expired = DateTime.add(DateTime.utc_now(), -10, :second)
    params = %{"credential_broker" => grant_payload(expired)}

    assert {^params, nil} =
             CredentialBrokerDelivery.refresh_embedded_grant(params,
               grant_issuer: fn _attrs, _actor -> {:error, :broker_down} end,
               grant_loader: refuse_loader()
             )
  end

  test "payload without an expiry is treated as stale and re-minted" do
    payload =
      DateTime.utc_now()
      |> grant_payload()
      |> Map.delete("expires_at")

    {refreshed, grant} =
      CredentialBrokerDelivery.refresh_embedded_grant(%{"credential_broker" => payload},
        grant_issuer: issuer_returning(),
        grant_loader: refuse_loader()
      )

    assert grant.id == "grant-new"
    assert is_binary(refreshed["credential_broker"]["expires_at"])
  end

  test "broker_resolution_opts audits the resolution against the grant scope" do
    grant = %{
      id: "grant-new",
      agent_id: "agent-sr-test-pve04",
      resolution_location: :agent
    }

    opts = CredentialBrokerDelivery.broker_resolution_opts(grant)

    assert opts[:audit?] == true
    assert opts[:agent_id] == "agent-sr-test-pve04"
    assert opts[:resolution_location] == :agent
    assert %{role: :system} = opts[:actor]
  end
end
