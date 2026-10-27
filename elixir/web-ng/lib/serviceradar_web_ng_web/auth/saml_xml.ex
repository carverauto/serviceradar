defmodule ServiceRadarWebNGWeb.Auth.SAMLXml do
  @moduledoc """
  The XML parser configurations used for SAML responses and IdP metadata.

  Neither a SAML response nor IdP metadata has any reason to carry a DTD, so
  documents are parsed with `dtd: :none`: an entity declaration is an error and
  external resources are never fetched. That closes XML external entity reads
  and entity-expansion bombs alike, which is what the `esaml` XXE advisory
  waiver in `.deps_audit_ignore` relies on -- `esaml` is used only for
  `:xmerl_dsig` over documents parsed here, never for its own decoding.

  Parsing is namespace-conformant so XPath queries built with
  `SweetXml.add_namespace/3` match on namespace URI, whatever prefix the IdP
  used.

  ## Responses are untrusted

  A `samlp:Response` reaches the ACS from an unauthenticated client and is
  parsed before its signature can be checked. `:xmerl_scan` interns every
  element name, attribute name, namespace prefix, namespace URI, processing
  instruction target, DTD name and encoding name it reads as a permanent atom.
  Atoms are never reclaimed, so parsing attacker-chosen names would let a few
  requests exhaust the atom table and abort the node.

  `parse_response/1` therefore scans the document first with
  `:xmerl_sax_parser`, which keeps names as strings, and hands it to
  `:xmerl_scan` only when every name it would intern is one this module
  already holds as an atom:

  - element and attribute names from the SAML 2.0 assertion and protocol, XML
    Signature, Exclusive Canonicalization and XML Encryption schemas, unprefixed
    or under one of the prefixes those specifications and common IdPs use;
  - namespace declarations binding one of those prefixes, or the default
    namespace, to one of those schemas' namespace URIs.

  A document type declaration, a processing instruction, an encoding other than
  UTF-8 and content after the root element are rejected outright, and the
  document is bounded in size and element count. An accepted document is parsed
  exactly as before, so signature verification is unchanged.

  Metadata is operator configuration rather than client input, and IdPs put
  vendor extensions in it, so `parse_metadata/1` keeps the general parser.
  """

  require Logger

  @max_response_bytes 1_048_576
  @max_response_elements 10_000

  @namespace_uris [
    "",
    "urn:oasis:names:tc:SAML:2.0:assertion",
    "urn:oasis:names:tc:SAML:2.0:protocol",
    "urn:oasis:names:tc:SAML:2.0:profiles:attribute:X500",
    "http://www.w3.org/2000/09/xmldsig#",
    "http://www.w3.org/2009/xmldsig11#",
    "http://www.w3.org/2001/10/xml-exc-c14n#",
    "http://www.w3.org/2001/04/xmlenc#",
    "http://www.w3.org/2009/xmlenc11#",
    "http://www.w3.org/2001/XMLSchema",
    "http://www.w3.org/2001/XMLSchema-instance"
  ]

  @prefixes ~w(saml saml2 samlp saml2p ds dsig ds11 ec xenc xenc11 xs xsd xsi x500) ++
              Enum.map(0..9, &"ns#{&1}")

  @element_names ~w(
    Response Status StatusCode StatusMessage StatusDetail Extensions
    Assertion EncryptedAssertion Issuer Subject NameID BaseID EncryptedID
    SubjectConfirmation SubjectConfirmationData Conditions Condition
    AudienceRestriction Audience OneTimeUse ProxyRestriction Advice
    AssertionIDRef AssertionURIRef Statement AuthnStatement SubjectLocality
    AuthnContext AuthnContextClassRef AuthnContextDecl AuthnContextDeclRef
    AuthenticatingAuthority AttributeStatement Attribute AttributeValue
    EncryptedAttribute AuthzDecisionStatement Action Evidence
    Signature SignedInfo CanonicalizationMethod SignatureMethod HMACOutputLength
    Reference Transforms Transform XPath DigestMethod DigestValue SignatureValue
    KeyInfo KeyName KeyValue RSAKeyValue Modulus Exponent DSAKeyValue P Q G Y J
    Seed PgenCounter ECKeyValue NamedCurve PublicKey RetrievalMethod X509Data
    X509IssuerSerial X509IssuerName X509SerialNumber X509SKI X509SubjectName
    X509Certificate X509CRL X509Digest Object Manifest SignatureProperties
    SignatureProperty InclusiveNamespaces
    EncryptedData EncryptedKey EncryptionMethod KeySize OAEPparams MGF
    CipherData CipherValue CipherReference EncryptionProperties
    EncryptionProperty ReferenceList DataReference KeyReference CarriedKeyName
  )

  @attribute_names ~w(
    ID Id Version IssueInstant Destination Consent InResponseTo Format
    NameQualifier SPNameQualifier SPProvidedID Method NotBefore NotOnOrAfter
    Recipient Address DNSName Count AuthnInstant SessionIndex
    SessionNotOnOrAfter Name NameFormat FriendlyName Resource Decision Namespace
    Value Algorithm URI Type MimeType Encoding PrefixList Target
    type nil lang space
  )

  # Every name `:xmerl_scan` can intern from an accepted response, held as atom
  # literals: they exist once this module is loaded, so accepting a response
  # interns nothing. Names are looked up with `:erlang.list_to_existing_atom/1`,
  # which never creates an atom.
  @response_elements MapSet.new(
                       for(prefix <- [nil | @prefixes], name <- @element_names, do: {prefix, name}),
                       fn
                         {nil, name} -> String.to_atom(name)
                         {prefix, name} -> String.to_atom(prefix <> ":" <> name)
                       end
                     )

  @response_attributes MapSet.new(
                         for(prefix <- [nil, "xml" | @prefixes], name <- @attribute_names, do: {prefix, name}),
                         fn
                           {nil, name} -> String.to_atom(name)
                           {prefix, name} -> String.to_atom(prefix <> ":" <> name)
                         end
                       )

  @response_namespace_declarations MapSet.new(["xmlns" | Enum.map(@prefixes, &("xmlns:" <> &1))], &String.to_atom/1)

  @response_namespace_uris MapSet.new(@namespace_uris, &String.to_atom/1)

  @doc """
  Parses an untrusted SAML response into an xmerl document, or returns
  `{:error, :invalid_xml}`.

  A document whose parse could intern an atom this module does not already hold
  is rejected without being parsed; see the module documentation.
  """
  @spec parse_response(String.t()) :: {:ok, tuple()} | {:error, :invalid_xml}
  def parse_response(xml) when is_binary(xml) do
    case check_response(xml) do
      :ok ->
        parse(xml)

      {:error, reason} ->
        Logger.warning("Rejected SAML response XML: #{reason}")
        {:error, :invalid_xml}
    end
  end

  def parse_response(_xml), do: {:error, :invalid_xml}

  @doc """
  Parses operator-supplied IdP metadata into an xmerl document, or returns
  `{:error, :invalid_xml}`.
  """
  @spec parse_metadata(String.t()) :: {:ok, tuple()} | {:error, :invalid_xml}
  def parse_metadata(xml) when is_binary(xml), do: parse(xml)
  def parse_metadata(_xml), do: {:error, :invalid_xml}

  defp parse(xml) do
    {:ok, SweetXml.parse(xml, dtd: :none, quiet: true, namespace_conformant: true)}
  rescue
    # `dtd: :none` raises on an entity declaration.
    _error in [RuntimeError] -> {:error, :invalid_xml}
  catch
    # xmerl reports malformed documents by exiting.
    :exit, _reason -> {:error, :invalid_xml}
  end

  # The byte checks run first, so the SAX scan never sees a DTD (whose external
  # identifiers it would resolve) or a document in another encoding.
  defp check_response(xml) do
    with :ok <- check_size(xml),
         :ok <- check_encoding(xml),
         :ok <- check_no_doctype(xml) do
      scan_names(xml)
    end
  end

  defp check_size(xml) when byte_size(xml) <= @max_response_bytes, do: :ok
  defp check_size(xml), do: {:error, "#{byte_size(xml)} bytes exceeds the #{@max_response_bytes}-byte limit"}

  # `:xmerl_scan` interns any declared encoding other than "utf-8". A NUL byte
  # is never valid XML, and is how a UTF-16 document looks when read as UTF-8.
  defp check_encoding(xml) do
    cond do
      not String.valid?(xml) -> {:error, "document is not UTF-8"}
      String.contains?(xml, <<0>>) -> {:error, "document contains a NUL byte"}
      declared_encoding(xml) not in [nil, "utf-8"] -> {:error, "document declares an encoding other than UTF-8"}
      true -> :ok
    end
  end

  defp declared_encoding(xml) do
    case Regex.run(~r/\A\x{FEFF}?<\?xml\s[^>]*?\bencoding\s*=\s*["']([^"']*)["']/u, xml) do
      [_, encoding] -> String.downcase(encoding)
      nil -> nil
    end
  end

  defp check_no_doctype(xml) do
    if String.contains?(xml, "<!DOCTYPE"), do: {:error, "document declares a DTD"}, else: :ok
  end

  defp scan_names(xml) do
    options = [{:event_fun, &scan_event/3}, {:event_state, 0}, :disallow_entities]

    case :xmerl_sax_parser.stream(xml, options) do
      {:ok, _elements, rest} ->
        if String.trim(rest) == "", do: :ok, else: {:error, "content after the root element"}

      {:reject, _location, reason, _end_tags, _elements} ->
        {:error, reason}

      _malformed ->
        {:error, "malformed XML"}
    end
  end

  # `:xmerl_sax_parser` stops on a `{tag, reason}` throw from the event
  # function and returns `{tag, location, reason, end_tags, state}`.
  defp scan_event({:startElement, _uri, _local, name, attributes}, _location, elements) do
    if elements >= @max_response_elements do
      throw({:reject, "more than #{@max_response_elements} elements"})
    end

    require_known(@response_elements, qualified(name), "element")

    Enum.each(attributes, fn {_uri, prefix, local, _value} ->
      require_known(@response_attributes, qualified({prefix, local}), "attribute")
    end)

    elements + 1
  end

  defp scan_event({:startPrefixMapping, prefix, uri}, _location, elements) do
    require_known(@response_namespace_declarations, qualified({~c"xmlns", prefix}), "namespace prefix")
    require_known(@response_namespace_uris, uri, "namespace")
    elements
  end

  defp scan_event({:processingInstruction, _target, _data}, _location, _elements) do
    throw({:reject, "document contains a processing instruction"})
  end

  defp scan_event({:startDTD, _name, _public_id, _system_id}, _location, _elements) do
    throw({:reject, "document declares a DTD"})
  end

  defp scan_event(_event, _location, elements), do: elements

  defp qualified({[], local}), do: local
  defp qualified({prefix, []}), do: prefix
  defp qualified({prefix, local}), do: prefix ++ [?: | local]

  defp require_known(known, name, kind) do
    if MapSet.member?(known, :erlang.list_to_existing_atom(name)), do: :ok, else: reject_name(kind, name)
  rescue
    # Not an existing atom, or longer than an atom can be.
    _error in [ArgumentError, SystemLimitError] -> reject_name(kind, name)
  end

  defp reject_name(kind, name) do
    throw({:reject, "unsupported #{kind} #{inspect(List.to_string(name), printable_limit: 80)}"})
  end
end
