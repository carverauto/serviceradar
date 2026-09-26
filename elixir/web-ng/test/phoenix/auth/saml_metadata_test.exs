defmodule ServiceRadarWebNGWeb.Auth.SAMLMetadataTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.SAMLFixtures
  alias ServiceRadarWebNGWeb.Auth.SAMLMetadata

  @moduletag :db_free

  setup_all do
    %{idp: SAMLFixtures.idp(entity_id: "https://idp.example.com/metadata")}
  end

  test "reads the entity ID, redirect SSO URL and signing certificate", %{idp: idp} do
    metadata = SAMLFixtures.metadata(idp, sso_url: "https://idp.example.com/sso")

    assert {:ok, "https://idp.example.com/metadata"} = SAMLMetadata.entity_id(metadata)
    assert {:ok, "https://idp.example.com/sso"} = SAMLMetadata.sso_redirect_url(metadata)
    assert {:ok, [cert]} = SAMLMetadata.signing_certificates(metadata)
    assert cert == idp.cert_der
  end

  test "matches elements by namespace, whatever prefix the IdP uses", %{idp: idp} do
    metadata =
      idp
      |> SAMLFixtures.metadata(sso_url: "https://idp.example.com/sso")
      |> String.replace("md:", "saml2md:")
      |> String.replace("xmlns:md=", "xmlns:saml2md=")

    assert {:ok, "https://idp.example.com/metadata"} = SAMLMetadata.entity_id(metadata)
    assert {:ok, "https://idp.example.com/sso"} = SAMLMetadata.sso_redirect_url(metadata)
    assert {:ok, [_cert]} = SAMLMetadata.signing_certificates(metadata)
  end

  test "rejects metadata that declares a DTD" do
    metadata = """
    <!DOCTYPE md:EntityDescriptor [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
    <md:EntityDescriptor xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata" entityID="&xxe;">
      <md:IDPSSODescriptor protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol" />
    </md:EntityDescriptor>
    """

    assert {:error, :invalid_metadata} = SAMLMetadata.entity_id(metadata)
    assert {:error, :invalid_metadata} = SAMLMetadata.signing_certificates(metadata)
  end
end
