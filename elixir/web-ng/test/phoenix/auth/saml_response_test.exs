defmodule ServiceRadarWebNGWeb.Auth.SAMLResponseTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.SAMLFixtures
  alias ServiceRadarWebNGWeb.Auth.SAMLResponse

  @moduletag :db_free

  setup_all do
    idp = SAMLFixtures.idp()
    %{idp: idp, config: config(idp)}
  end

  describe "decode/2" do
    test "reads the signed assertion, including its ID and request binding", %{idp: idp, config: config} do
      saml_response =
        SAMLFixtures.response(idp,
          assertion_id: "_assertion-decode",
          in_response_to: "_req-decode",
          name_id: "saml-decode@example.com",
          email: "saml-decode@example.com"
        )

      assert {:ok, assertion} = SAMLResponse.decode(saml_response, config)

      assert assertion.id == "_assertion-decode"
      assert assertion.issuer == idp.entity_id
      assert assertion.subject_name_id == "saml-decode@example.com"
      assert assertion.attributes == %{"email" => "saml-decode@example.com"}
      assert assertion.conditions.audience == "https://sp.example.com"
      assert {:ok, _, _} = DateTime.from_iso8601(assertion.conditions.not_on_or_after)
      assert assertion.subject_confirmation.recipient == "https://sp.example.com/auth/saml/consume"
      assert assertion.subject_confirmation.in_response_to == "_req-decode"
      assert assertion.subject_confirmation.not_on_or_after == assertion.conditions.not_on_or_after
      assert assertion.response_in_response_to == "_req-decode"
    end

    test "accepts a signature on the Response instead of the assertion", %{idp: idp, config: config} do
      saml_response = SAMLFixtures.response(idp, sign: :response, assertion_id: "_assertion-response")

      assert {:ok, %{id: "_assertion-response"}} = SAMLResponse.decode(saml_response, config)
    end

    test "rejects a response signed by a key the metadata does not list", %{idp: idp, config: config} do
      saml_response = SAMLFixtures.response(idp, signer: SAMLFixtures.idp())

      assert {:error, :invalid_signature} = SAMLResponse.decode(saml_response, config)
    end

    test "rejects a signed assertion that was altered after signing", %{idp: idp, config: config} do
      tampered =
        idp
        |> SAMLFixtures.response(name_id: "saml-user@example.com")
        |> Base.decode64!()
        |> String.replace(
          "saml-user@example.com</saml:NameID>",
          "saml-admin@example.com</saml:NameID>"
        )
        |> Base.encode64()

      assert {:error, :invalid_signature} = SAMLResponse.decode(tampered, config)
    end

    test "rejects an unsigned response", %{idp: idp, config: config} do
      unsigned =
        idp
        |> SAMLFixtures.response()
        |> Base.decode64!()
        |> String.replace(~r{<ds:Signature.*</ds:Signature>}s, "")
        |> Base.encode64()

      assert {:error, :no_signature} = SAMLResponse.decode(unsigned, config)
    end

    test "honours certificate pinning", %{idp: idp, config: config} do
      saml_response = SAMLFixtures.response(idp)
      pin = SAMLResponse.certificate_fingerprint(idp.cert_der)
      other_pin = SAMLResponse.certificate_fingerprint(SAMLFixtures.idp().cert_der)

      assert {:ok, _assertion} =
               SAMLResponse.decode(saml_response, %{config | pinned_cert_fingerprints: [pin]})

      assert {:error, :certificate_pinning_failed} =
               SAMLResponse.decode(saml_response, %{config | pinned_cert_fingerprints: [other_pin]})
    end

    test "rejects documents that declare a DTD", %{config: config} do
      external_entity =
        Base.encode64("""
        <!DOCTYPE samlp:Response [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol">&xxe;</samlp:Response>
        """)

      internal_entity =
        Base.encode64("""
        <!DOCTYPE samlp:Response [<!ENTITY a "aaaaaaaaaa">]>
        <samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol">&a;&a;</samlp:Response>
        """)

      assert {:error, :invalid_saml_response} = SAMLResponse.decode(external_entity, config)
      assert {:error, :invalid_saml_response} = SAMLResponse.decode(internal_entity, config)
    end

    test "rejects input that is not base64", %{config: config} do
      assert {:error, :invalid_base64} = SAMLResponse.decode("not base64!", config)
    end
  end

  defp config(idp) do
    %{idp_metadata: {:xml, SAMLFixtures.metadata(idp)}, pinned_cert_fingerprints: []}
  end
end
