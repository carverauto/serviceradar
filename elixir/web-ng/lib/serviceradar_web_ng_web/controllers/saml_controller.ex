defmodule ServiceRadarWebNGWeb.SAMLController do
  @moduledoc """
  Controller for SAML 2.0 authentication flow.

  Handles:
  - SP-initiated SSO (redirect to IdP)
  - ACS endpoint for SAML assertions
  - SP metadata endpoint for IdP configuration

  ## Flow

  1. User clicks "Sign in with SSO" on login page
  2. App redirects to `/auth/saml` which redirects to IdP
  3. User authenticates at IdP
  4. IdP POSTs SAML assertion to `/auth/saml/consume`
  5. App validates assertion and creates session
  6. User is redirected to the application

  ## Security

  - SAML assertions are validated using the IdP's certificate
  - Assertions are checked for expiration and audience
  - Replay attacks are prevented using assertion IDs
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.Audit.UserAuthEvents
  alias ServiceRadarWebNG.Auth.Hooks
  alias ServiceRadarWebNGWeb.Auth.OutboundURLPolicy
  alias ServiceRadarWebNGWeb.Auth.RateLimiter
  alias ServiceRadarWebNGWeb.Auth.SAMLAssertionValidator
  alias ServiceRadarWebNGWeb.Auth.SAMLStrategy
  alias ServiceRadarWebNGWeb.Auth.SSOProvisioning
  alias ServiceRadarWebNGWeb.ClientIP
  alias ServiceRadarWebNGWeb.UserAuth

  require Logger

  plug :fetch_session
  plug :check_rate_limit when action == :consume

  # Rate limit: 20 attempts per minute per IP for ACS callbacks
  @callback_rate_limit 20
  @callback_rate_window 60

  defp check_rate_limit(conn, _opts) do
    client_ip = get_client_ip(conn)

    case RateLimiter.check_rate_limit_and_record("saml_consume", client_ip,
           limit: @callback_rate_limit,
           window_seconds: @callback_rate_window
         ) do
      :ok ->
        conn

      {:error, retry_after} ->
        Logger.warning("SAML ACS rate limited for IP: #{client_ip}")

        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_flash(
          :error,
          "Too many authentication attempts. Please wait #{retry_after} seconds."
        )
        |> redirect(to: ~p"/users/log-in")
        |> halt()
    end
  end

  defp get_client_ip(conn) do
    ClientIP.get(conn)
  end

  @doc """
  Initiates SAML authentication by redirecting to the IdP.

  Generates a CSRF token stored in session and passed via RelayState
  to prevent cross-site request forgery attacks.
  """
  def request(conn, _params) do
    if SAMLStrategy.enabled?() do
      # Generate CSRF token for RelayState
      csrf_token = generate_csrf_token()

      case get_saml_request_url(csrf_token) do
        {:ok, url} ->
          conn
          |> put_session(:saml_csrf_token, csrf_token)
          |> redirect(external: url)

        {:error, reason} ->
          Logger.error("Failed to initiate SAML auth: #{inspect(reason)}")

          conn
          |> put_flash(:error, "SAML authentication is not properly configured.")
          |> redirect(to: ~p"/users/log-in")
      end
    else
      conn
      |> put_flash(:error, "SAML authentication is not enabled.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  defp generate_csrf_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @doc """
  Assertion Consumer Service (ACS) endpoint.

  Receives and validates SAML assertions from the IdP.
  Validates CSRF token from RelayState before processing.
  """
  def consume(conn, params) do
    saml_response = params["SAMLResponse"]
    relay_state = params["RelayState"]
    stored_csrf_token = get_session(conn, :saml_csrf_token)

    # Clear CSRF token from session
    conn = delete_session(conn, :saml_csrf_token)

    # Parse RelayState to extract CSRF token and return URL
    {csrf_token, return_to} = parse_relay_state(relay_state)

    cond do
      !valid_saml_csrf_token?(csrf_token, stored_csrf_token) ->
        Logger.warning("SAML CSRF token mismatch")

        Hooks.on_auth_failed(:csrf_validation_failed, %{
          method: :saml,
          ip: get_client_ip(conn)
        })

        conn
        |> put_flash(:error, "Authentication failed: invalid request. Please try again.")
        |> redirect(to: ~p"/users/log-in")

      !saml_response ->
        Hooks.on_auth_failed(:no_saml_response, %{
          method: :saml,
          ip: get_client_ip(conn)
        })

        conn
        |> put_flash(:error, "No SAML response received.")
        |> redirect(to: ~p"/users/log-in")

      true ->
        case validate_saml_response(saml_response) do
          {:ok, assertion} ->
            handle_successful_assertion(conn, assertion, return_to)

          {:error, reason} ->
            Logger.warning("SAML assertion validation failed: #{inspect(reason)}")

            Hooks.on_auth_failed(reason, %{
              method: :saml,
              ip: get_client_ip(conn),
              user_agent: conn |> get_req_header("user-agent") |> List.first()
            })

            conn
            |> put_flash(:error, "Authentication failed. Please try again.")
            |> redirect(to: ~p"/users/log-in")
        end
    end
  end

  # Parse RelayState to extract CSRF token and optional return URL
  # Format: "csrf_token" or "csrf_token|return_url"
  defp parse_relay_state(nil), do: {nil, nil}
  defp parse_relay_state(""), do: {nil, nil}

  defp parse_relay_state(relay_state) do
    case String.split(relay_state, "|", parts: 2) do
      [token, return_url] -> {token, return_url}
      [token] -> {token, nil}
    end
  end

  defp valid_saml_csrf_token?(csrf_token, stored_csrf_token)
       when is_binary(csrf_token) and is_binary(stored_csrf_token) do
    Plug.Crypto.secure_compare(csrf_token, stored_csrf_token)
  end

  defp valid_saml_csrf_token?(_csrf_token, _stored_csrf_token), do: false

  @doc """
  SP Metadata endpoint.

  Returns XML metadata for configuring the IdP.
  """
  def metadata(conn, _params) do
    metadata_xml = generate_sp_metadata()

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, metadata_xml)
  end

  # Private functions

  defp get_saml_request_url(csrf_token) do
    with {:ok, config} <- SAMLStrategy.get_config(),
         {:xml, xml} <- config.idp_metadata,
         {:ok, sso_url} <- extract_sso_url_from_metadata(xml),
         :ok <- validate_sso_redirect_url(sso_url) do
      # Build AuthnRequest URL
      sp_entity_id = config.sp_entity_id
      acs_url = config.acs_url

      # Build the AuthnRequest
      authn_request = build_authn_request(sp_entity_id, acs_url)
      encoded_request = Base.encode64(authn_request)

      # Include CSRF token in RelayState
      relay_state = csrf_token

      url =
        "#{sso_url}?SAMLRequest=#{URI.encode(encoded_request)}&RelayState=#{URI.encode(relay_state)}"

      {:ok, url}
    else
      {:url, _url} -> {:error, :invalid_metadata}
      {:error, :invalid_sso_url} -> {:error, :invalid_metadata}
      error -> error
    end
  end

  # Parse IdP metadata to extract SSO URL
  defp extract_sso_url_from_metadata(xml) do
    import SweetXml

    # Use safe parser
    doc = safe_sweetxml_parse(xml)

    sso_url =
      xpath(doc, ~x"//md:SingleSignOnService[@Binding='urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect']/@Location"s,
        namespace_conformant: true,
        namespaces: [md: "urn:oasis:names:tc:SAML:2.0:metadata"]
      )

    if sso_url && sso_url != "" do
      {:ok, sso_url}
    else
      # Try without namespace prefix
      sso_url_alt =
        xpath(doc, ~x"//SingleSignOnService[@Binding='urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect']/@Location"s)

      if sso_url_alt && sso_url_alt != "" do
        {:ok, sso_url_alt}
      else
        {:error, :sso_url_not_found}
      end
    end
  rescue
    e ->
      Logger.error("Failed to parse IdP metadata: #{inspect(e)}")
      {:error, :metadata_parse_failed}
  end

  defp validate_sso_redirect_url(url) when is_binary(url) do
    case OutboundURLPolicy.validate(url) do
      {:ok, _uri} -> :ok
      {:error, _reason} -> {:error, :invalid_sso_url}
    end
  end

  defp validate_sso_redirect_url(_url), do: {:error, :invalid_sso_url}

  defp build_authn_request(sp_entity_id, acs_url) do
    # Build a minimal SAML AuthnRequest
    request_id = "_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    issue_instant = DateTime.to_iso8601(DateTime.utc_now())

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <samlp:AuthnRequest
      xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol"
      xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion"
      ID="#{request_id}"
      Version="2.0"
      IssueInstant="#{issue_instant}"
      AssertionConsumerServiceURL="#{acs_url}"
      ProtocolBinding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST">
      <saml:Issuer>#{sp_entity_id}</saml:Issuer>
      <samlp:NameIDPolicy
        Format="urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"
        AllowCreate="true"/>
    </samlp:AuthnRequest>
    """
    |> String.trim()
    |> :zlib.compress()
  end

  defp validate_saml_response(saml_response_b64) do
    with {:ok, saml_response_xml} <- Base.decode64(saml_response_b64),
         {:ok, config} <- SAMLStrategy.get_config(),
         {:ok, verified_element} <- validate_xml_signature(saml_response_xml, config),
         {:ok, assertion} <- parse_saml_assertion(verified_element),
         :ok <- SAMLAssertionValidator.validate(assertion, config) do
      {:ok, assertion}
    else
      :error ->
        {:error, :invalid_base64}

      {:error, reason} = error ->
        Logger.warning("SAML response validation failed: #{inspect(reason)}")
        error
    end
  end

  # Validate the XML signature on the SAML response/assertion
  defp validate_xml_signature(xml, config) do
    with {:ok, certs} when certs != [] <- get_idp_certificates(config),
         :ok <- validate_certificate_pinning(certs, config),
         fingerprints = build_trusted_fingerprints(certs),
         {:ok, verified_element} <- validate_signature_with_fingerprints(xml, fingerprints) do
      {:ok, verified_element}
    else
      {:ok, []} ->
        Logger.warning("No IdP certificates found for signature validation")
        {:error, :missing_signing_certificates}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Validate that at least one certificate matches pinned fingerprints
  defp validate_certificate_pinning(certs, config) do
    pinned_fingerprints = Map.get(config, :pinned_cert_fingerprints, [])

    if Enum.empty?(pinned_fingerprints) do
      # No pinning configured, allow any valid cert
      :ok
    else
      # Compute fingerprints of current certificates
      current_fingerprints =
        certs
        |> Enum.map(&compute_cert_fingerprint/1)
        |> Enum.filter(&(&1 != nil))

      # Check if any current cert matches a pinned fingerprint
      matching =
        Enum.any?(current_fingerprints, fn fp ->
          Enum.member?(pinned_fingerprints, fp)
        end)

      if matching do
        :ok
      else
        Logger.error("SAML certificate pinning validation failed - no matching certificates")
        {:error, :certificate_pinning_failed}
      end
    end
  end

  @doc """
  Compute SHA256 fingerprint of a certificate in DER format.
  Returns the fingerprint as a hex string with colons (e.g., "AB:CD:EF:...")
  """
  def compute_cert_fingerprint(cert) do
    # If it's an Erlang certificate record, encode to DER
    der =
      case cert do
        {:Certificate, _, _, _} ->
          :public_key.der_encode(:Certificate, cert)

        binary when is_binary(binary) ->
          binary

        _ ->
          nil
      end

    if der do
      :sha256
      |> :crypto.hash(der)
      |> Base.encode16(case: :upper)
      |> String.graphemes()
      |> Enum.chunk_every(2)
      |> Enum.join(":")
    end
  rescue
    _ -> nil
  end

  @doc """
  Extract and compute fingerprints for all certificates in IdP metadata.
  Used by the admin UI to display available certificates for pinning.
  """
  def get_idp_certificate_fingerprints do
    case SAMLStrategy.get_config() do
      {:ok, config} ->
        {:ok, certs} = get_idp_certificates(config)

        fingerprints =
          certs
          |> Enum.map(&compute_cert_fingerprint/1)
          |> Enum.filter(&(&1 != nil))

        {:ok, fingerprints}

      error ->
        error
    end
  end

  defp get_idp_certificates(config) do
    {:xml, metadata_xml} = config.idp_metadata
    extract_certificates_from_metadata(metadata_xml)
  end

  defp extract_certificates_from_metadata(xml) do
    import SweetXml

    # Use safe parser
    doc = safe_sweetxml_parse(xml)

    # Extract X509 certificates from IdP metadata
    # These are typically in ds:X509Certificate elements
    certs =
      xpath(doc, ~x"//md:KeyDescriptor[@use='signing']/ds:KeyInfo/ds:X509Data/ds:X509Certificate/text()"ls,
        namespace_conformant: true,
        namespaces: [md: "urn:oasis:names:tc:SAML:2.0:metadata", ds: "http://www.w3.org/2000/09/xmldsig#"]
      )

    # Fallback: try without namespace prefix or with different paths
    certs =
      if Enum.empty?(certs) do
        # Try alternative path without use attribute
        xpath(
          doc,
          ~x"//md:KeyDescriptor/ds:KeyInfo/ds:X509Data/ds:X509Certificate/text()"ls,
          namespace_conformant: true,
          namespaces: [
            md: "urn:oasis:names:tc:SAML:2.0:metadata",
            ds: "http://www.w3.org/2000/09/xmldsig#"
          ]
        )
      else
        certs
      end

    # Second fallback: try without namespace prefixes
    certs =
      if Enum.empty?(certs) do
        xpath(doc, ~x"//X509Certificate/text()"ls)
      else
        certs
      end

    # Decode base64 certificates to DER format
    decoded_certs =
      certs
      |> Enum.map(&String.replace(&1, ~r/\s+/, ""))
      |> Enum.filter(&(&1 != ""))
      |> Enum.map(&decode_certificate/1)
      |> Enum.filter(&(&1 != nil))

    {:ok, decoded_certs}
  rescue
    e ->
      Logger.error("Failed to extract IdP certificates: #{inspect(e)}")
      {:ok, []}
  end

  defp decode_certificate(base64_cert) do
    case Base.decode64(base64_cert) do
      {:ok, der} ->
        # Convert DER to Erlang certificate record
        try do
          :public_key.der_decode(:Certificate, der)
        rescue
          _ -> nil
        end

      :error ->
        nil
    end
  end

  defp validate_signature_with_fingerprints(xml_string, fingerprints) when is_binary(xml_string) do
    # Parse XML safely using xmerl (disable external entities)
    {doc, _} = safe_xmerl_scan(xml_string)

    signed_elements = signed_elements(doc)

    case signed_elements do
      [] ->
        Logger.warning("No signature found in SAML response or assertion")
        {:error, :no_signature}

      elements ->
        case verify_signed_elements(elements, fingerprints) do
          {:ok, verified_element} -> {:ok, verified_element}
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    e ->
      Logger.error("Signature validation error: #{inspect(e)}")
      {:error, :signature_validation_error}
  end

  defp signed_elements(doc) do
    namespaces = [
      {"saml2p", ~c"urn:oasis:names:tc:SAML:2.0:protocol"},
      {"saml2", ~c"urn:oasis:names:tc:SAML:2.0:assertion"},
      {"ds", ~c"http://www.w3.org/2000/09/xmldsig#"}
    ]

    # Prioritize Assertion signatures to prevent XSW where Response is signed but Assertion is spoofed
    assertion_signed =
      :xmerl_xpath.string(~c"//saml2:Assertion[ds:Signature]", doc, namespace: namespaces)

    response_signed =
      :xmerl_xpath.string(~c"//saml2p:Response[ds:Signature]", doc, namespace: namespaces)

    Enum.uniq(assertion_signed ++ response_signed)
  end

  defp verify_signed_elements(elements, fingerprints) do
    # Return the first element that verifies successfully
    verified =
      Enum.find_value(elements, fn element ->
        case :xmerl_dsig.verify(element, fingerprints) do
          :ok -> element
          _ -> nil
        end
      end)

    if verified do
      {:ok, verified}
    else
      Logger.warning("SAML signature verification failed")
      {:error, :invalid_signature}
    end
  end

  defp build_trusted_fingerprints(certs) when is_list(certs) do
    certs
    |> Enum.flat_map(fn cert ->
      case cert_der(cert) do
        nil ->
          []

        der ->
          sha = :crypto.hash(:sha, der)
          sha256 = :crypto.hash(:sha256, der)
          [sha, {:sha, sha}, {:sha256, sha256}]
      end
    end)
    |> Enum.uniq()
  end

  defp cert_der({:Certificate, _, _, _} = cert), do: :public_key.der_encode(:Certificate, cert)
  defp cert_der(der) when is_binary(der), do: der
  defp cert_der(_), do: nil

  defp parse_saml_assertion(node) do
    import SweetXml

    # Extract assertion data relative to the verified node
    namespaces = [
      saml: "urn:oasis:names:tc:SAML:2.0:assertion",
      samlp: "urn:oasis:names:tc:SAML:2.0:protocol"
    ]

    # Note: We use relative paths (.) to ensure we only look within the verified assertion node
    assertion = %{
      subject_name_id: xpath(node, ~x"./saml:Subject/saml:NameID/text()"s, namespaces: namespaces),
      issuer: xpath(node, ~x"./saml:Issuer/text()"s, namespaces: namespaces),
      attributes: parse_attributes(node, namespaces),
      conditions: %{
        not_before: xpath(node, ~x"./saml:Conditions/@NotBefore"s, namespaces: namespaces),
        not_on_or_after: xpath(node, ~x"./saml:Conditions/@NotOnOrAfter"s, namespaces: namespaces),
        audience:
          xpath(node, ~x"./saml:Conditions/saml:AudienceRestriction/saml:Audience/text()"s, namespaces: namespaces)
      },
      subject_confirmation: %{
        recipient:
          xpath(node, ~x"./saml:SubjectConfirmation/saml:SubjectConfirmationData/@Recipient"s, namespaces: namespaces)
      }
    }

    # Fallback for non-namespaced XML
    assertion =
      if assertion.subject_name_id == "" do
        %{
          assertion
          | subject_name_id: xpath(node, ~x"./Subject/NameID/text()"s),
            conditions: %{
              not_before: xpath(node, ~x"./Conditions/@NotBefore"s),
              not_on_or_after: xpath(node, ~x"./Conditions/@NotOnOrAfter"s),
              audience: xpath(node, ~x"./Conditions/AudienceRestriction/Audience/text()"s)
            },
            issuer: xpath(node, ~x"./Issuer/text()"s),
            subject_confirmation: %{
              recipient: xpath(node, ~x"./SubjectConfirmation/SubjectConfirmationData/@Recipient"s)
            }
        }
      else
        assertion
      end

    if assertion.subject_name_id == "" do
      {:error, :no_subject}
    else
      {:ok, assertion}
    end
  rescue
    e ->
      Logger.error("Failed to parse SAML assertion: #{inspect(e)}")
      {:error, :parse_failed}
  end

  defp parse_attributes(node, namespaces) do
    import SweetXml

    # Use relative path statement
    attrs =
      node
      |> xpath(
        ~x"./saml:AttributeStatement/saml:Attribute"l,
        namespaces: namespaces
      )
      |> Enum.map(fn attr ->
        name = xpath(attr, ~x"./@Name"s, namespaces: namespaces)
        value = xpath(attr, ~x"./saml:AttributeValue/text()"s, namespaces: namespaces)
        %{name: name, value: value}
      end)

    # Fallback to non-namespaced
    attrs =
      if Enum.empty?(attrs) do
        xpath(node, ~x"./AttributeStatement/Attribute"l, name: ~x"./@Name"s, value: ~x"./AttributeValue/text()"s)
      else
        attrs
      end

    Enum.reduce(attrs, %{}, fn %{name: name, value: value}, acc ->
      if name && name != "", do: Map.put(acc, name, value), else: acc
    end)
  end

  # Safe XML parsing helpers to prevent XXE

  defp safe_xmerl_scan(xml_string) do
    xml_charlist = String.to_charlist(xml_string)

    :xmerl_scan.string(xml_charlist, [
      {:quiet, true},
      {:validation, false},
      {:fetch_fun, &reject_external_resource/2}
    ])
  end

  defp safe_sweetxml_parse(xml_string) do
    SweetXml.parse(xml_string,
      quiet: true,
      xmerl_options: [
        fetch_fun: &reject_external_resource/2
      ]
    )
  end

  defp reject_external_resource(_ext_spec, _scanner_state), do: {:error, :disabled_for_security}

  defp handle_successful_assertion(conn, assertion, relay_state) do
    actor = SystemActor.system(:saml_controller)

    # Extract user info from assertion
    user_info = extract_user_info(assertion)

    case find_or_create_user(user_info, actor) do
      {:ok, user} ->
        # Record authentication
        User.record_authentication(user, actor: actor)

        # Trigger auth hooks
        Hooks.on_user_authenticated(user, %{"method" => "saml", "assertion" => assertion})

        _ = UserAuthEvents.record_login(conn, user, :saml)

        # Determine redirect destination
        return_to = relay_state || ~p"/analytics"

        conn
        |> put_flash(:info, "Signed in successfully via SAML.")
        |> UserAuth.log_in_user(user, %{"return_to" => return_to})

      {:error, :unsafe_account_linking} ->
        Logger.warning("SAML authentication rejected implicit email-based account linking")

        Hooks.on_auth_failed(:unsafe_account_linking, %{
          method: :saml,
          ip: get_client_ip(conn)
        })

        conn
        |> put_flash(
          :error,
          "An existing account with that email cannot be linked automatically. Please contact your administrator."
        )
        |> redirect(to: ~p"/users/log-in")

      {:error, reason} ->
        Logger.error("Failed to provision SAML user: #{inspect(reason)}")

        Hooks.on_auth_failed(:user_provisioning_failed, %{
          method: :saml,
          reason: reason,
          ip: get_client_ip(conn)
        })

        conn
        |> put_flash(:error, "Failed to complete authentication.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  defp extract_user_info(assertion) do
    # Get claim mappings from config
    {:ok, config} = SAMLStrategy.get_config()
    mappings = config.claim_mappings

    # Extract from assertion attributes with fallbacks
    email =
      get_attribute(assertion.attributes, mappings["email"]) ||
        get_attribute(assertion.attributes, "email") ||
        get_attribute(
          assertion.attributes,
          "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress"
        ) ||
        assertion.subject_name_id

    name =
      get_attribute(assertion.attributes, mappings["name"]) ||
        get_attribute(assertion.attributes, "name") ||
        get_attribute(assertion.attributes, "displayName") ||
        get_attribute(
          assertion.attributes,
          "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name"
        )

    external_id =
      get_attribute(assertion.attributes, mappings["sub"]) ||
        assertion.subject_name_id

    %{
      email: email,
      name: name,
      external_id: external_id,
      attributes: assertion.attributes
    }
  end

  defp get_attribute(_attributes, nil), do: nil
  defp get_attribute(attributes, key), do: Map.get(attributes, key)

  defp find_or_create_user(%{email: email, name: name, external_id: external_id, attributes: attributes}, actor) do
    claims = Map.merge(attributes, %{"email" => email, "name" => name, "sub" => external_id})

    SSOProvisioning.find_or_create_user(
      %{email: email, name: name, external_id: external_id},
      claims,
      :saml,
      actor
    )
  end

  defp generate_sp_metadata do
    sp_entity_id = SAMLStrategy.get_sp_entity_id()
    acs_url = SAMLStrategy.get_acs_url()

    String.trim("""
    <?xml version="1.0" encoding="UTF-8"?>
    <md:EntityDescriptor xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata"
                         entityID="#{sp_entity_id}">
      <md:SPSSODescriptor AuthnRequestsSigned="false"
                          WantAssertionsSigned="true"
                          protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">
        <md:NameIDFormat>urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress</md:NameIDFormat>
        <md:AssertionConsumerService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
                                      Location="#{acs_url}"
                                      index="0"
                                      isDefault="true"/>
      </md:SPSSODescriptor>
    </md:EntityDescriptor>
    """)
  end
end
