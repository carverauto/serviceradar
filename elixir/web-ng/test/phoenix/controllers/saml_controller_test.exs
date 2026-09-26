defmodule ServiceRadarWebNGWeb.SAMLControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.SAMLConsumedAssertion
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.SAMLFixtures
  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.Auth.SAMLStrategy

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db

  @sp_entity_id "https://sp.example.com"
  @csrf_token "csrf-token"
  @invalid_request "Authentication failed: invalid request. Please try again."
  @failed "Authentication failed. Please try again."

  setup do
    maybe_start_config_cache()
    clear_auth_cache()

    idp = SAMLFixtures.idp()

    put_saml_settings(%{
      is_enabled: true,
      mode: :active_sso,
      provider_type: :saml,
      saml_idp_metadata_xml: SAMLFixtures.metadata(idp, sso_url: "https://127.0.0.1/sso"),
      saml_sp_entity_id: @sp_entity_id,
      claim_mappings: nil,
      saml_pinned_cert_fingerprints: nil
    })

    previous_idp_initiated = Application.get_env(:serviceradar_web_ng, :saml_allow_idp_initiated)

    on_exit(fn ->
      clear_auth_cache()
      Application.put_env(:serviceradar_web_ng, :saml_allow_idp_initiated, previous_idp_initiated)
    end)

    %{idp: idp}
  end

  test "rejects SAML login initiation when metadata-derived SSO URL violates outbound policy", %{
    conn: conn
  } do
    conn = get(conn, ~p"/auth/saml")

    assert redirected_to(conn) == ~p"/users/log-in"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "SAML authentication is not properly configured."
  end

  test "signs in with a signed response that answers this session's request", %{idp: idp} do
    {email, user} = provision_saml_user()
    assertion_id = unique_id("_assertion")

    saml_response =
      SAMLFixtures.response(idp,
        assertion_id: assertion_id,
        in_response_to: "_req-happy",
        name_id: email,
        email: email,
        recipient: SAMLStrategy.get_acs_url()
      )

    conn = consume(pending_session("_req-happy"), saml_response)

    assert redirected_to(conn) == ~p"/dashboard"
    assert get_session(conn, :live_socket_id) == "users_sessions:#{user.id}"
    assert Enum.count(recorded_assertion_ids(idp), &(&1 == assertion_id)) == 1

    # The pending request is spent whatever the outcome.
    refute get_session(conn, :saml_authn_request)
    refute get_session(conn, :saml_csrf_token)
  end

  test "rejects a replayed assertion even when the request binding matches", %{idp: idp} do
    {email, user} = provision_saml_user()

    saml_response =
      SAMLFixtures.response(idp,
        in_response_to: "_req-replay",
        name_id: email,
        email: email,
        recipient: SAMLStrategy.get_acs_url()
      )

    first = consume(pending_session("_req-replay"), saml_response)
    assert get_session(first, :live_socket_id) == "users_sessions:#{user.id}"

    {replay, log} = with_log(fn -> consume(pending_session("_req-replay"), saml_response) end)

    assert_failed(replay, @failed)
    assert log =~ ":assertion_replayed"
  end

  test "rejects a response that answers a different request", %{idp: idp} do
    {email, _user} = provision_saml_user()
    assertion_id = unique_id("_assertion")

    for in_response_to <- ["_req-someone-else", nil] do
      saml_response =
        SAMLFixtures.response(idp,
          assertion_id: assertion_id,
          in_response_to: in_response_to,
          name_id: email,
          email: email,
          recipient: SAMLStrategy.get_acs_url()
        )

      {conn, log} = with_log(fn -> consume(pending_session("_req-mine"), saml_response) end)

      assert_failed(conn, @failed)
      assert log =~ ~r/:in_response_to_mismatch|:missing_in_response_to/
    end

    # Rejected before the replay ledger, so the assertion was never spent.
    refute assertion_id in recorded_assertion_ids(idp)
  end

  test "rejects a pending request older than the request TTL", %{idp: idp} do
    {email, _user} = provision_saml_user()

    saml_response =
      SAMLFixtures.response(idp,
        in_response_to: "_req-stale",
        name_id: email,
        email: email,
        recipient: SAMLStrategy.get_acs_url()
      )

    issued_at = System.system_time(:second) - 3_600
    conn = consume(pending_session("_req-stale", issued_at), saml_response)

    assert_failed(conn, @invalid_request)
  end

  test "rejects an unsolicited response by default", %{conn: conn, idp: idp} do
    {email, _user} = provision_saml_user()
    assertion_id = unique_id("_assertion")

    saml_response =
      SAMLFixtures.response(idp,
        assertion_id: assertion_id,
        name_id: email,
        email: email,
        recipient: SAMLStrategy.get_acs_url()
      )

    conn = post(conn, ~p"/auth/saml/consume", %{"SAMLResponse" => saml_response})

    assert_failed(conn, @invalid_request)
    refute assertion_id in recorded_assertion_ids(idp)
  end

  test "accepts an unsolicited response once when IdP-initiated login is enabled", %{idp: idp} do
    Application.put_env(:serviceradar_web_ng, :saml_allow_idp_initiated, true)
    {email, user} = provision_saml_user()

    saml_response =
      SAMLFixtures.response(idp, name_id: email, email: email, recipient: SAMLStrategy.get_acs_url())

    conn = post(build_conn(), ~p"/auth/saml/consume", %{"SAMLResponse" => saml_response})
    assert redirected_to(conn) == ~p"/dashboard"
    assert get_session(conn, :live_socket_id) == "users_sessions:#{user.id}"

    replay = post(build_conn(), ~p"/auth/saml/consume", %{"SAMLResponse" => saml_response})
    assert_failed(replay, @failed)

    # An unsolicited response may not claim to answer some other session's request.
    bound =
      SAMLFixtures.response(idp,
        in_response_to: "_req-elsewhere",
        name_id: email,
        email: email,
        recipient: SAMLStrategy.get_acs_url()
      )

    conn = post(build_conn(), ~p"/auth/saml/consume", %{"SAMLResponse" => bound})
    assert_failed(conn, @failed)
  end

  test "rejects SAML ACS XML with external entities" do
    malicious_response =
      Base.encode64("""
      <!DOCTYPE samlp:Response [
        <!ENTITY xxe SYSTEM "file:///etc/passwd">
      ]>
      <samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol">
        <saml:Assertion xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion">
          <saml:Issuer>&xxe;</saml:Issuer>
        </saml:Assertion>
      </samlp:Response>
      """)

    conn = consume(pending_session("_req-xxe"), malicious_response)

    assert_failed(conn, @failed)
  end

  defp consume(conn, saml_response) do
    post(conn, ~p"/auth/saml/consume", %{
      "SAMLResponse" => saml_response,
      "RelayState" => @csrf_token
    })
  end

  # The session state `GET /auth/saml` leaves behind for an SP-initiated login.
  defp pending_session(request_id, issued_at \\ System.system_time(:second)) do
    init_test_session(build_conn(), %{
      saml_csrf_token: @csrf_token,
      saml_authn_request: %{"id" => request_id, "issued_at" => issued_at}
    })
  end

  defp assert_failed(conn, message) do
    assert redirected_to(conn) == ~p"/users/log-in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == message
    refute get_session(conn, "user_token")
  end

  # A pre-provisioned SSO account, found by external_id (the NameID) so the
  # test does not depend on JIT provisioning settings.
  defp provision_saml_user do
    email = "saml-#{System.unique_integer([:positive])}@example.com"

    {:ok, user} =
      User.provision_sso_user(
        %{email: email, display_name: "SAML User", external_id: email, provider: :saml},
        actor: SystemActor.system(:test)
      )

    {email, user}
  end

  defp recorded_assertion_ids(idp) do
    SAMLConsumedAssertion
    |> Ash.Query.filter(issuer == ^idp.entity_id)
    |> Ash.read!(actor: SystemActor.system(:test))
    |> Enum.map(& &1.assertion_id)
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp maybe_start_config_cache do
    case Process.whereis(ConfigCache) do
      nil -> start_supervised!({ConfigCache, ttl_ms: 60_000})
      _pid -> :ok
    end
  end

  defp clear_auth_cache do
    if :ets.whereis(ConfigCache) != :undefined do
      :ets.delete(ConfigCache, :auth_settings)
      ConfigCache.clear_cache()
    end
  end

  defp put_saml_settings(settings) when is_map(settings) do
    expires_at = System.monotonic_time(:millisecond) + to_timeout(minute: 5)
    :ets.insert(ConfigCache, {:auth_settings, settings, expires_at})
  end
end
