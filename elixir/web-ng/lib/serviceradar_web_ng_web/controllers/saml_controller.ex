defmodule ServiceRadarWebNGWeb.SAMLController do
  @moduledoc """
  Controller for SAML 2.0 authentication flow.

  Handles:
  - SP-initiated SSO (redirect to IdP)
  - ACS endpoint for SAML assertions
  - SP metadata endpoint for IdP configuration

  ## Flow

  1. User clicks "Sign in with SSO" on login page
  2. `GET /auth/saml` records the AuthnRequest server-side under a fresh,
     unguessable RelayState and redirects to the IdP with both
  3. User authenticates at IdP
  4. IdP POSTs the SAML response and RelayState to `/auth/saml/consume`
  5. App takes the pending request for that RelayState, validates the response
     against it, spends the assertion, and creates a session
  6. User is redirected to where they were going when the login started

  ## The ACS does not use the browser session

  The IdP's POST to `/auth/saml/consume` is a cross-site form submission. It
  carries no Phoenix CSRF token, and with the `SameSite=Lax` session cookie the
  browser usually sends no session with it either. The route therefore runs in
  the `:saml_acs` pipeline, without `:protect_from_forgery`, and nothing here
  reads the session. Security rests on four checks instead:

  - **Signature.** The response is parsed with DTDs disabled (`SAMLXml`) and
    its signature is verified against the signing certificates in the IdP
    metadata, honouring certificate pinning (`SAMLResponse`).
  - **Assertion content.** It must carry an `ID`, an `Issuer` and a bounded
    `Conditions` window containing now, and match the expected issuer,
    audience and recipient (`SAMLAssertionValidator`).
  - **One-use request binding.** `GET /auth/saml` stores
    `ServiceRadar.Identity.SAMLPendingRequest` rows keyed by a hash of a
    256-bit RelayState, valid for `:saml_authn_request_ttl_seconds` (default
    600). The consumer deletes the row for the posted RelayState in one atomic
    statement, so a RelayState answers at most one response; an unknown, used
    or expired one is rejected. The bearer
    `SubjectConfirmationData/@InResponseTo` must then equal the stored request
    ID, as must `Response/@InResponseTo` when present.
  - **Replay protection.** Each accepted assertion is recorded as
    `(issuer, assertion ID)` in `ServiceRadar.Identity.SAMLConsumedAssertion`
    before any user is looked up or a session is created. A second submission of
    the same assertion conflicts on the unique identity and is rejected, on any
    web node. A failure to record fails closed.

  What the session used to add, and no longer can: proof that the browser
  posting the response is the one that started the login. Someone who starts a
  login, authenticates as themselves and gets a victim's browser to post the
  result can sign the victim into the attacker's account (login CSRF). The
  RelayState binding keeps that to responses the attacker obtained for their own
  request, within the TTL, once.

  The return path is taken from the session when the login starts, stored on
  the pending request, and passed through `UserAuth.log_in_user/3`'s
  same-origin sanitizer. Nothing in the POST chooses it.

  ## IdP-initiated (unsolicited) responses

  Rejected unless `config :serviceradar_web_ng, :saml_allow_idp_initiated,
  true` is set; it is off by default because an unsolicited response has no
  request to bind to. When it is enabled, a response whose RelayState matches
  no pending request (or that has none) is treated as unsolicited: it must not
  name any `InResponseTo`, it lands on the default page, and every other check,
  including replay protection, still applies.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.SAMLConsumedAssertion
  alias ServiceRadar.Identity.SAMLPendingRequest
  alias ServiceRadar.Security.Lockouts
  alias ServiceRadarWebNG.Audit.UserAuthEvents
  alias ServiceRadarWebNG.Auth.Hooks
  alias ServiceRadarWebNGWeb.Auth.OutboundURLPolicy
  alias ServiceRadarWebNGWeb.Auth.SAMLAssertionValidator
  alias ServiceRadarWebNGWeb.Auth.SAMLMetadata
  alias ServiceRadarWebNGWeb.Auth.SAMLResponse
  alias ServiceRadarWebNGWeb.Auth.SAMLStrategy
  alias ServiceRadarWebNGWeb.Auth.SSOProvisioning
  alias ServiceRadarWebNGWeb.ClientIP
  alias ServiceRadarWebNGWeb.UserAuth

  require Logger

  plug :fetch_session

  # Rate limiting for `consume` happens at the
  # `:rate_limit_auth_saml` pipeline (router.ex).

  @default_authn_request_ttl_seconds 600

  # Failures that mean "this browser did not start this login" rather than "the
  # IdP's response was bad"; they share the invalid-request message.
  @request_binding_failures [
    :unsolicited_response,
    :unknown_relay_state,
    :authn_request_expired
  ]

  defp get_client_ip(conn) do
    ClientIP.get(conn)
  end

  @doc """
  Initiates SAML authentication by redirecting to the IdP.

  Records the AuthnRequest server-side under a fresh RelayState (see the
  moduledoc); `consume/2` requires that RelayState back.
  """
  def request(conn, _params) do
    if SAMLStrategy.enabled?() do
      relay_state = generate_relay_state()
      request_id = generate_request_id()

      with {:ok, url} <- get_saml_request_url(relay_state, request_id),
           :ok <- open_pending_request(relay_state, request_id, get_session(conn, :user_return_to)) do
        redirect(conn, external: url)
      else
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

  # 256 bits, URL-safe, 43 characters (SAML caps RelayState at 80 bytes).
  defp generate_relay_state do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  # XML IDs must not start with a digit.
  defp generate_request_id do
    "_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp open_pending_request(relay_state, request_id, return_to) do
    expires_at = DateTime.add(DateTime.utc_now(), authn_request_ttl_seconds(), :second)
    # An unusable path is dropped rather than failing the login.
    return_to = if is_binary(return_to) and byte_size(return_to) <= 2048, do: return_to

    case SAMLPendingRequest.open(relay_state, request_id, expires_at, %{return_to: return_to},
           actor: SystemActor.system(:saml_controller)
         ) do
      {:ok, _pending} -> :ok
      {:error, reason} -> {:error, {:pending_request_not_stored, reason}}
    end
  end

  @doc """
  Assertion Consumer Service (ACS) endpoint.

  Receives and validates SAML responses from the IdP. Reads nothing from the
  browser session; the posted RelayState selects the server-side pending
  request, which is consumed before the response is looked at.
  """
  def consume(conn, params) do
    with {:ok, expected_request, return_to} <- take_pending_request(params["RelayState"]),
         {:ok, saml_response} <- fetch_saml_response(params),
         {:ok, config} <- SAMLStrategy.get_config(),
         {:ok, assertion} <- validate_saml_response(saml_response, config, expected_request),
         :ok <- spend_assertion(assertion) do
      handle_successful_assertion(conn, assertion, config, return_to)
    else
      {:error, reason} -> reject(conn, reason)
    end
  end

  defp take_pending_request(relay_state) when is_binary(relay_state) and relay_state != "" do
    case SAMLPendingRequest.take(relay_state, actor: SystemActor.system(:saml_controller)) do
      {:ok, %SAMLPendingRequest{} = pending} ->
        if DateTime.before?(DateTime.utc_now(), pending.expires_at) do
          {:ok, pending.request_id, pending.return_to}
        else
          {:error, :authn_request_expired}
        end

      {:ok, nil} ->
        unsolicited_or(:unknown_relay_state)

      {:error, reason} ->
        Logger.error("Failed to look up SAML pending request: #{inspect(reason)}")
        {:error, :authn_request_lookup_failed}
    end
  end

  defp take_pending_request(_relay_state), do: unsolicited_or(:unsolicited_response)

  defp unsolicited_or(reason) do
    if allow_idp_initiated?(), do: {:ok, :unsolicited, nil}, else: {:error, reason}
  end

  defp fetch_saml_response(%{"SAMLResponse" => saml_response}) when is_binary(saml_response) and saml_response != "",
    do: {:ok, saml_response}

  defp fetch_saml_response(_params), do: {:error, :no_saml_response}

  defp reject(conn, reason) when reason in @request_binding_failures do
    Logger.warning("SAML request binding failed: #{inspect(reason)}")
    Hooks.on_auth_failed(reason, %{method: :saml, ip: get_client_ip(conn)})

    conn
    |> put_flash(:error, "Authentication failed: invalid request. Please try again.")
    |> redirect(to: ~p"/users/log-in")
  end

  defp reject(conn, :no_saml_response) do
    Hooks.on_auth_failed(:no_saml_response, %{method: :saml, ip: get_client_ip(conn)})

    conn
    |> put_flash(:error, "No SAML response received.")
    |> redirect(to: ~p"/users/log-in")
  end

  defp reject(conn, reason) do
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

  defp authn_request_ttl_seconds do
    case Application.get_env(:serviceradar_web_ng, :saml_authn_request_ttl_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _ -> @default_authn_request_ttl_seconds
    end
  end

  defp allow_idp_initiated? do
    Application.get_env(:serviceradar_web_ng, :saml_allow_idp_initiated, false) == true
  end

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

  defp get_saml_request_url(relay_state, request_id) do
    with {:ok, config} <- SAMLStrategy.get_config(),
         {:xml, xml} <- config.idp_metadata,
         {:ok, sso_url} <- SAMLMetadata.sso_redirect_url(xml),
         :ok <- validate_sso_redirect_url(sso_url) do
      authn_request = build_authn_request(request_id, config.sp_entity_id, config.acs_url, sso_url)

      # HTTP-Redirect binding: raw DEFLATE, then base64, then URL-encoded.
      query =
        URI.encode_query(%{
          "SAMLRequest" => authn_request |> :zlib.zip() |> Base.encode64(),
          "RelayState" => relay_state
        })

      separator = if String.contains?(sso_url, "?"), do: "&", else: "?"

      {:ok, sso_url <> separator <> query}
    else
      {:error, :invalid_sso_url} -> {:error, :invalid_metadata}
      error -> error
    end
  end

  defp validate_sso_redirect_url(url) when is_binary(url) do
    case OutboundURLPolicy.validate(url) do
      {:ok, _uri} -> :ok
      {:error, _reason} -> {:error, :invalid_sso_url}
    end
  end

  defp validate_sso_redirect_url(_url), do: {:error, :invalid_sso_url}

  defp build_authn_request(request_id, sp_entity_id, acs_url, sso_url) do
    issue_instant = DateTime.to_iso8601(DateTime.utc_now())

    String.trim("""
    <?xml version="1.0" encoding="UTF-8"?>
    <samlp:AuthnRequest
      xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol"
      xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion"
      ID="#{request_id}"
      Version="2.0"
      IssueInstant="#{issue_instant}"
      Destination="#{xml_escape(sso_url)}"
      AssertionConsumerServiceURL="#{xml_escape(acs_url)}"
      ProtocolBinding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST">
      <saml:Issuer>#{xml_escape(sp_entity_id)}</saml:Issuer>
      <samlp:NameIDPolicy
        Format="urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"
        AllowCreate="true"/>
    </samlp:AuthnRequest>
    """)
  end

  defp xml_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp validate_saml_response(saml_response_b64, config, expected_request) do
    with {:ok, assertion} <- SAMLResponse.decode(saml_response_b64, config),
         :ok <- SAMLAssertionValidator.validate(assertion, config),
         :ok <- SAMLAssertionValidator.validate_in_response_to(assertion, expected_request) do
      {:ok, assertion}
    end
  end

  # Records the assertion as used. Runs after every other check and before any
  # user lookup or session, so a replayed assertion never reaches provisioning.
  # The validator has already required a non-empty ID and issuer and a parseable
  # NotOnOrAfter; anything that stops the row being written fails closed.
  defp spend_assertion(assertion) do
    actor = SystemActor.system(:saml_controller)

    with {:ok, not_on_or_after, _offset} <-
           DateTime.from_iso8601(assertion.conditions.not_on_or_after),
         {:ok, _row} <-
           SAMLConsumedAssertion.record(
             String.trim(assertion.issuer),
             String.trim(assertion.id),
             not_on_or_after,
             actor: actor
           ) do
      :ok
    else
      {:error, %Ash.Error.Invalid{errors: errors}} = error ->
        if Enum.any?(errors, &unique_violation?/1) do
          {:error, :assertion_replayed}
        else
          Logger.error("Failed to record SAML assertion use: #{inspect(error)}")
          {:error, :assertion_replay_check_failed}
        end

      error ->
        Logger.error("Failed to record SAML assertion use: #{inspect(error)}")
        {:error, :assertion_replay_check_failed}
    end
  end

  defp unique_violation?(%Ash.Error.Changes.InvalidAttribute{private_vars: private_vars}) do
    Keyword.get(private_vars || [], :constraint_type) == :unique
  end

  defp unique_violation?(_error), do: false

  defp handle_successful_assertion(conn, assertion, config, return_to) do
    actor = SystemActor.system(:saml_controller)

    # Extract user info from assertion
    user_info = extract_user_info(assertion, config)

    with {:ok, user} <- find_or_create_user(user_info, actor),
         {:ok, user} <- SSOProvisioning.record_successful_authentication(user, :saml, actor) do
      # Trigger auth hooks
      Hooks.on_user_authenticated(user, %{"method" => "saml", "assertion" => assertion})

      _ = UserAuthEvents.record_login(conn, user, :saml)

      # The stored path from the pending request; log_in_user/3 keeps it same-origin.
      return_to = return_to || ~p"/dashboard"

      identity_claims =
        user_info.attributes
        |> Map.merge(%{
          "email" => user_info.email,
          "name" => user_info.name,
          "sub" => user_info.external_id,
          "iss" => assertion.issuer,
          "SessionIndex" => assertion.session_index
        })
        |> Map.put("service_radar_auth_method", "saml")

      conn
      |> put_flash(:info, "Signed in successfully via SAML.")
      |> UserAuth.log_in_user(user, %{
        "return_to" => return_to,
        "identity_claims" => identity_claims
      })
    else
      {:error, :unsafe_account_linking} ->
        Logger.warning("SAML authentication rejected implicit email-based account linking")
        record_validated_failure(conn, user_info, :unsafe_account_linking)

        conn
        |> put_flash(
          :error,
          "An existing account with that email cannot be linked automatically. Please contact your administrator."
        )
        |> redirect(to: ~p"/users/log-in")

      {:error, :no_local_account} ->
        Logger.warning("SAML authentication denied: no local account and JIT provisioning disabled")
        record_validated_failure(conn, user_info, :no_local_account)

        conn
        |> put_flash(
          :error,
          "No account is provisioned for this identity. Contact your administrator."
        )
        |> redirect(to: ~p"/users/log-in")

      {:error, reason} ->
        Logger.error("Failed to provision SAML user: #{inspect(reason)}")
        record_validated_failure(conn, user_info, reason)

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

  # The assertion has already been signature/audience-validated by
  # SAMLAssertionValidator; failures from here represent a validated
  # identity that we couldn't map to a local user. Feed those into
  # the lockout trigger like a failed password.
  defp record_validated_failure(conn, user_info, reason) do
    if reason == :unsafe_account_linking do
      Hooks.on_auth_failed(:unsafe_account_linking, %{
        method: :saml,
        ip: get_client_ip(conn)
      })
    end

    email = Map.get(user_info || %{}, :email)

    if is_binary(email) and email != "" do
      Lockouts.record_failed_login(email, %{
        ip: get_client_ip(conn),
        route: conn.request_path,
        method: "saml",
        reason: to_string(reason)
      })
    end
  end

  defp extract_user_info(assertion, config) do
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
