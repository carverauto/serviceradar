defmodule ServiceRadarWebNGWeb.Auth.SAMLResponse do
  @moduledoc """
  Verifies and reads an IdP `samlp:Response` delivered over the HTTP-POST
  binding.

  `decode/2`:

  1. base64-decodes the form value;
  2. parses it with `ServiceRadarWebNGWeb.Auth.SAMLXml` (no DTDs,
     namespace-conformant);
  3. verifies an XML signature with `:xmerl_dsig` against the signing
     certificates in the IdP metadata, honouring certificate pinning. The
     response must carry exactly one `saml:Assertion`, as a direct child of the
     root `samlp:Response`; a signature on that assertion is tried first, then
     one on the response itself;
  4. reads the assertion fields from the signed element only. The one field
     read from outside it is the response's own `InResponseTo`, which is only
     ever compared against, never trusted on its own.

  It does not decide whether the assertion is acceptable. Time window, issuer,
  audience, recipient, request binding and one-time use are enforced by
  `ServiceRadarWebNGWeb.Auth.SAMLAssertionValidator` and
  `ServiceRadarWebNGWeb.SAMLController`.
  """

  import SweetXml, only: [sigil_x: 2, add_namespace: 3, xpath: 2]

  alias ServiceRadarWebNGWeb.Auth.SAMLMetadata
  alias ServiceRadarWebNGWeb.Auth.SAMLXml

  require Logger

  @assertion_ns "urn:oasis:names:tc:SAML:2.0:assertion"
  @protocol_ns "urn:oasis:names:tc:SAML:2.0:protocol"
  @dsig_ns "http://www.w3.org/2000/09/xmldsig#"

  @xmerl_namespaces [
    {~c"samlp", String.to_charlist(@protocol_ns)},
    {~c"saml", String.to_charlist(@assertion_ns)},
    {~c"ds", String.to_charlist(@dsig_ns)}
  ]

  @doc """
  Decodes, verifies and parses a base64 `SAMLResponse` form value.

  Returns the assertion as a map with `:id`, `:issuer`, `:subject_name_id`,
  `:session_index`, `:attributes`, `:conditions`, `:subject_confirmation` and
  `:response_in_response_to`. Absent values are empty strings.
  """
  @spec decode(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def decode(saml_response_b64, %{idp_metadata: {:xml, metadata_xml}} = config)
      when is_binary(saml_response_b64) and is_binary(metadata_xml) do
    with {:ok, xml} <- decode_base64(saml_response_b64),
         {:ok, doc} <- parse_response(xml),
         {:ok, fingerprints} <- trusted_fingerprints(metadata_xml, config),
         {:ok, assertion_node} <- verified_assertion(doc, fingerprints) do
      parse_assertion(assertion_node, doc)
    end
  end

  def decode(_saml_response_b64, _config), do: {:error, :invalid_saml_response}

  @doc """
  SHA-256 fingerprint of a certificate, as colon-separated upper-case hex
  (`"AB:CD:..."`). This is the format of the pinned fingerprints in
  `AuthSettings.saml_pinned_cert_fingerprints`.
  """
  @spec certificate_fingerprint(binary()) :: String.t()
  def certificate_fingerprint(der) when is_binary(der) do
    :sha256
    |> :crypto.hash(der)
    |> Base.encode16(case: :upper)
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.join(":")
  end

  defp decode_base64(value) do
    case Base.decode64(value, ignore: :whitespace) do
      {:ok, xml} -> {:ok, xml}
      :error -> {:error, :invalid_base64}
    end
  end

  defp parse_response(xml) do
    case SAMLXml.parse(xml) do
      {:ok, doc} -> {:ok, doc}
      {:error, :invalid_xml} -> {:error, :invalid_saml_response}
    end
  end

  defp trusted_fingerprints(metadata_xml, config) do
    with {:ok, certs} <- SAMLMetadata.signing_certificates(metadata_xml),
         :ok <- require_certificates(certs),
         :ok <- validate_certificate_pinning(certs, config) do
      {:ok, build_trusted_fingerprints(certs)}
    end
  end

  defp require_certificates([]) do
    Logger.warning("No IdP signing certificates found for SAML signature validation")
    {:error, :missing_signing_certificates}
  end

  defp require_certificates(_certs), do: :ok

  # When fingerprints are pinned, at least one metadata certificate must match
  # one of them. With no pins, every signing certificate in the metadata is
  # trusted.
  defp validate_certificate_pinning(certs, config) do
    case Map.get(config, :pinned_cert_fingerprints) || [] do
      [] ->
        :ok

      pinned ->
        pinned = MapSet.new(pinned, &String.upcase/1)

        if Enum.any?(certs, &(certificate_fingerprint(&1) in pinned)) do
          :ok
        else
          Logger.error("SAML certificate pinning validation failed - no matching certificates")
          {:error, :certificate_pinning_failed}
        end
    end
  end

  # The three forms :xmerl_dsig.verify/2 compares the signing certificate with.
  defp build_trusted_fingerprints(certs) do
    certs
    |> Enum.flat_map(fn der ->
      sha = :crypto.hash(:sha, der)
      [sha, {:sha, sha}, {:sha256, :crypto.hash(:sha256, der)}]
    end)
    |> Enum.uniq()
  end

  defp verified_assertion(doc, fingerprints) do
    with {:ok, assertion} <- single_assertion(doc) do
      cond do
        signed?(assertion) and verify(assertion, fingerprints) == :ok ->
          {:ok, assertion}

        signed?(doc) and verify(doc, fingerprints) == :ok ->
          {:ok, assertion}

        signed?(assertion) or signed?(doc) ->
          Logger.warning("SAML signature verification failed")
          {:error, :invalid_signature}

        true ->
          Logger.warning("No signature found in SAML response or assertion")
          {:error, :no_signature}
      end
    end
  end

  # Exactly one assertion, directly under the root Response. Anything else --
  # no assertion, several, or a Response that is not the document root -- is
  # rejected rather than guessed at, so a wrapped or injected assertion cannot
  # be the one that gets read.
  defp single_assertion(doc) do
    case xmerl_xpath(~c"/samlp:Response/saml:Assertion", doc) do
      [assertion] -> {:ok, assertion}
      [] -> {:error, :no_assertion}
      _many -> {:error, :multiple_assertions}
    end
  end

  defp signed?(element), do: xmerl_xpath(~c"./ds:Signature", element) != []

  # :xmerl_dsig asserts the signature's shape with pattern matches, so a
  # malformed or unsupported signature raises instead of returning an error.
  defp verify(element, fingerprints) do
    :xmerl_dsig.verify(element, fingerprints)
  rescue
    _error in [MatchError, CaseClauseError, FunctionClauseError, ArgumentError, ErlangError] ->
      {:error, :malformed_signature}
  end

  defp xmerl_xpath(path, node), do: :xmerl_xpath.string(path, node, namespace: @xmerl_namespaces)

  defp parse_assertion(node, doc) do
    bearer =
      "./saml:Subject/saml:SubjectConfirmation" <>
        "[@Method='urn:oasis:names:tc:SAML:2.0:cm:bearer']/saml:SubjectConfirmationData"

    assertion = %{
      id: text(node, "./@ID"),
      issuer: text(node, "./saml:Issuer/text()"),
      subject_name_id: text(node, "./saml:Subject/saml:NameID/text()"),
      session_index: text(node, "./saml:AuthnStatement/@SessionIndex"),
      attributes: parse_attributes(node),
      conditions: %{
        not_before: text(node, "./saml:Conditions/@NotBefore"),
        not_on_or_after: text(node, "./saml:Conditions/@NotOnOrAfter"),
        audience: text(node, "./saml:Conditions/saml:AudienceRestriction/saml:Audience/text()")
      },
      subject_confirmation: %{
        recipient: first_text(node, bearer <> "/@Recipient"),
        in_response_to: first_text(node, bearer <> "/@InResponseTo"),
        not_on_or_after: first_text(node, bearer <> "/@NotOnOrAfter")
      },
      response_in_response_to: text(doc, "/samlp:Response/@InResponseTo")
    }

    if String.trim(assertion.subject_name_id) == "" do
      {:error, :no_subject}
    else
      {:ok, assertion}
    end
  end

  defp parse_attributes(node) do
    node
    |> xpath(spec("./saml:AttributeStatement/saml:Attribute", ~c"l"))
    |> Enum.reduce(%{}, fn attr, acc ->
      name = text(attr, "./@Name")
      value = text(attr, "./saml:AttributeValue/text()")

      if name == "", do: acc, else: Map.put(acc, name, value)
    end)
  end

  defp text(node, path), do: xpath(node, spec(path, ~c"s"))

  defp first_text(node, path), do: node |> xpath(spec(path, ~c"ls")) |> List.first("")

  defp spec(path, modifiers) do
    path
    |> sigil_x(modifiers)
    |> add_namespace("samlp", @protocol_ns)
    |> add_namespace("saml", @assertion_ns)
  end
end
