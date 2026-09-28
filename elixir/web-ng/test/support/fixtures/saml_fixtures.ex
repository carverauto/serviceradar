defmodule ServiceRadarWebNG.SAMLFixtures do
  @moduledoc """
  A synthetic SAML identity provider for tests.

  `idp/1` mints a fresh RSA key and self-signed certificate per call, so no key
  material is committed. `metadata/2` renders IdP metadata for it and
  `response/2` produces a base64 `SAMLResponse` signed with its key, the way an
  IdP posts one to the assertion consumer service. Every identifier is invented
  (`example.com` hosts, random IDs).
  """

  @default_sp_entity_id "https://sp.example.com"
  @default_acs_url "https://sp.example.com/auth/saml/consume"

  @doc "Returns a new signing identity for a synthetic IdP."
  def idp(opts \\ []) do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    %{cert: cert_der} = :public_key.pkix_test_root_cert(~c"SAML Test IdP", key: key)

    %{
      entity_id: Keyword.get(opts, :entity_id, "https://idp.example.com/metadata"),
      key: key,
      cert_der: cert_der
    }
  end

  @doc "Renders IdP metadata advertising `idp`'s signing certificate."
  def metadata(idp, opts \\ []) do
    sso_url = Keyword.get(opts, :sso_url, "https://idp.example.com/sso")

    """
    <md:EntityDescriptor xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata" entityID="#{idp.entity_id}">
      <md:IDPSSODescriptor protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">
        <md:KeyDescriptor use="signing">
          <ds:KeyInfo xmlns:ds="http://www.w3.org/2000/09/xmldsig#">
            <ds:X509Data>
              <ds:X509Certificate>#{Base.encode64(idp.cert_der)}</ds:X509Certificate>
            </ds:X509Data>
          </ds:KeyInfo>
        </md:KeyDescriptor>
        <md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect" Location="#{sso_url}" />
      </md:IDPSSODescriptor>
    </md:EntityDescriptor>
    """
  end

  @doc """
  Builds a base64 `SAMLResponse` signed by `idp`.

  Options (all optional):

    * `:assertion_id` - the assertion `ID` (random by default)
    * `:in_response_to` - `SubjectConfirmationData/@InResponseTo`; `nil` omits it
    * `:response_in_response_to` - `Response/@InResponseTo`; defaults to
      `:in_response_to`, `nil` omits it
    * `:name_id`, `:email` - the subject
    * `:issuer`, `:audience`, `:recipient`
    * `:not_before`, `:not_on_or_after` - `DateTime`s for `Conditions`
    * `:sign` - `:assertion` (default) or `:response`
    * `:signer` - an `idp/1` identity to sign with instead of `idp`
  """
  def response(idp, opts \\ []) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    in_response_to = Keyword.get(opts, :in_response_to)

    fields = %{
      assertion_id: Keyword.get_lazy(opts, :assertion_id, &random_id/0),
      response_id: random_id(),
      in_response_to: in_response_to,
      response_in_response_to: Keyword.get(opts, :response_in_response_to, in_response_to),
      name_id: Keyword.get(opts, :name_id, "saml-user@example.com"),
      email: Keyword.get(opts, :email, "saml-user@example.com"),
      issuer: Keyword.get(opts, :issuer, idp.entity_id),
      audience: Keyword.get(opts, :audience, @default_sp_entity_id),
      recipient: Keyword.get(opts, :recipient, @default_acs_url),
      issue_instant: iso(now),
      not_before: iso(Keyword.get(opts, :not_before, DateTime.add(now, -30, :second))),
      not_on_or_after: iso(Keyword.get(opts, :not_on_or_after, DateTime.add(now, 120, :second)))
    }

    signer = Keyword.get(opts, :signer, idp)

    xml =
      case Keyword.get(opts, :sign, :assertion) do
        :assertion ->
          signed_assertion = fields |> assertion_xml() |> sign(signer)
          response_xml(fields, signed_assertion)

        :response ->
          fields |> response_xml(assertion_xml(fields)) |> sign(signer)
      end

    Base.encode64(xml)
  end

  defp assertion_xml(fields) do
    subject_confirmation_data =
      ~s(<saml:SubjectConfirmationData NotOnOrAfter="#{fields.not_on_or_after}" ) <>
        ~s(Recipient="#{fields.recipient}"#{attr("InResponseTo", fields.in_response_to)}/>)

    ~s(<saml:Assertion xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" ) <>
      ~s(ID="#{fields.assertion_id}" Version="2.0" IssueInstant="#{fields.issue_instant}">) <>
      ~s(<saml:Issuer>#{fields.issuer}</saml:Issuer>) <>
      ~s(<saml:Subject>) <>
      ~s(<saml:NameID Format="urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress">) <>
      ~s(#{fields.name_id}</saml:NameID>) <>
      ~s(<saml:SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer">) <>
      subject_confirmation_data <>
      ~s(</saml:SubjectConfirmation></saml:Subject>) <>
      ~s(<saml:Conditions NotBefore="#{fields.not_before}" ) <>
      ~s(NotOnOrAfter="#{fields.not_on_or_after}">) <>
      ~s(<saml:AudienceRestriction><saml:Audience>#{fields.audience}</saml:Audience>) <>
      ~s(</saml:AudienceRestriction></saml:Conditions>) <>
      ~s(<saml:AuthnStatement AuthnInstant="#{fields.issue_instant}" SessionIndex="_session1">) <>
      ~s(<saml:AuthnContext><saml:AuthnContextClassRef>) <>
      ~s(urn:oasis:names:tc:SAML:2.0:ac:classes:PasswordProtectedTransport) <>
      ~s(</saml:AuthnContextClassRef></saml:AuthnContext></saml:AuthnStatement>) <>
      ~s(<saml:AttributeStatement><saml:Attribute Name="email">) <>
      ~s(<saml:AttributeValue>#{fields.email}</saml:AttributeValue>) <>
      ~s(</saml:Attribute></saml:AttributeStatement>) <>
      ~s(</saml:Assertion>)
  end

  defp response_xml(fields, assertion_xml) do
    ~s(<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" ) <>
      ~s(ID="#{fields.response_id}" Version="2.0" IssueInstant="#{fields.issue_instant}" ) <>
      ~s(Destination="#{fields.recipient}"#{attr("InResponseTo", fields.response_in_response_to)}>) <>
      ~s(<saml:Issuer xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion">#{fields.issuer}</saml:Issuer>) <>
      ~s(<samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/>) <>
      ~s(</samlp:Status>) <>
      assertion_xml <>
      ~s(</samlp:Response>)
  end

  # Signs the document's root element (enveloped signature, RSA-SHA256) and
  # serializes it without a prolog so it can be embedded in a parent document.
  defp sign(xml, signer) do
    {element, _rest} =
      xml
      |> String.to_charlist()
      |> :xmerl_scan.string(quiet: true, namespace_conformant: true)

    signed = :xmerl_dsig.sign(element, signer.key, signer.cert_der, :rsa_sha256)

    [signed]
    |> :xmerl.export_simple(:xmerl_xml, prolog: [])
    |> IO.chardata_to_string()
  end

  defp attr(_name, nil), do: ""
  defp attr(name, value), do: ~s( #{name}="#{value}")

  defp iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp random_id, do: "_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
