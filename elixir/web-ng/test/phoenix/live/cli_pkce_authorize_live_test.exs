defmodule ServiceRadarWebNGWeb.CliPkceAuthorizeLiveTest do
  @moduledoc """
  Browser consent for `serviceradar-cli auth login --web`.

  The CLI probes this path before it opens a browser. A logged-out visit
  must redirect to log-in (a 302, which the probe treats as supported)
  and keep the query. Approval may redirect only to the loopback callback.
  """
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNG.AccountsFixtures

  @moduletag :integration
  @moduletag :web_ng_shared_fixture_db

  @loopback "http://127.0.0.1:4317/cli/auth/callback"

  describe "unauthenticated visitor" do
    test "redirects to log-in and keeps the authorize query on return_to", %{conn: conn} do
      assert {:error, {:redirect, %{to: redirect_to}}} = live(conn, authorize_path())

      assert redirect_to =~ "/users/log-in"
      assert redirect_to =~ "return_to=%2Fapi%2Fv1%2Fcli%2Fauth%2Fauthorize%3F"
      assert redirect_to =~ "state-pkce-test"
    end
  end

  describe "authenticated visitor with cli.session.create" do
    setup :register_and_log_in_user

    test "a non-loopback redirect shows an error and no Approve button", %{conn: conn} do
      path =
        authorize_path(%{
          "redirect_uri" => "http://192.0.2.1:4317/cli/auth/callback"
        })

      {:ok, view, _html} = live(conn, path)

      assert has_element?(view, "#cli-pkce-invalid")
      refute has_element?(view, "#cli-pkce-approve")
      refute has_element?(view, "#cli-pkce-deny")
    end

    test "an unknown scope shows an error and no Approve button", %{conn: conn} do
      {:ok, view, _html} = live(conn, authorize_path(%{"scope" => "admin"}))

      assert has_element?(view, "#cli-pkce-invalid")
      refute has_element?(view, "#cli-pkce-approve")
    end

    test "Deny returns access_denied to the loopback callback", %{conn: conn} do
      {:ok, view, _html} = live(conn, authorize_path())
      view |> element("#cli-pkce-deny") |> render_click()

      assert {redirect_to, _flash} = assert_redirect(view)
      uri = URI.parse(redirect_to)
      assert uri.scheme == "http"
      assert uri.host == "127.0.0.1"
      assert uri.path == "/cli/auth/callback"
      query = URI.decode_query(uri.query)
      assert query["error"] == "access_denied"
      assert query["state"] == "state-pkce-test"
      refute Map.has_key?(query, "code")
    end

    test "Approve redirects a one-time code to the loopback callback and the token endpoint accepts it",
         %{conn: conn, user: user} do
      {verifier, challenge} = pkce_pair()
      {:ok, view, _html} = live(conn, authorize_path(%{"code_challenge" => challenge}))
      view |> element("#cli-pkce-approve") |> render_click()

      assert {redirect_to, _flash} = assert_redirect(view)
      uri = URI.parse(redirect_to)
      assert "#{uri.scheme}://#{uri.host}:#{uri.port}#{uri.path}" == @loopback
      query = URI.decode_query(uri.query)
      assert query["state"] == "state-pkce-test"
      assert is_binary(query["code"]) and query["code"] != ""

      RateLimiter.clear(:cli_device_auth, "127.0.0.1")

      body =
        Phoenix.ConnTest.build_conn()
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> post(~p"/api/v1/cli/auth/token", %{
          "grant_type" => "authorization_code",
          "client_id" => "serviceradar-cli",
          "code" => query["code"],
          "redirect_uri" => @loopback,
          "code_verifier" => verifier
        })
        |> json_response(200)

      assert body["token_type"] == "Bearer"
      assert is_binary(body["access_token"])
      assert body["scope"] == "dashboard.publish edge.manage"
      assert body["user"]["id"] == user.id
    end
  end

  describe "authenticated visitor without cli.session.create (viewer)" do
    setup do
      user = AccountsFixtures.user_fixture(%{role: :viewer})
      conn = log_in_user(Phoenix.ConnTest.build_conn(), user)
      %{conn: conn, user: user}
    end

    test "a valid request renders without Approve or Deny", %{conn: conn} do
      {:ok, view, _html} = live(conn, authorize_path())

      assert has_element?(view, "#cli-pkce-forbidden")
      assert has_element?(view, "#cli-pkce-redirect", @loopback)
      refute has_element?(view, "#cli-pkce-approve")
      refute has_element?(view, "#cli-pkce-deny")
    end
  end

  defp authorize_path(overrides \\ %{}) do
    {_verifier, challenge} = pkce_pair()

    query =
      Map.merge(
        %{
          "response_type" => "code",
          "client_id" => "serviceradar-cli",
          "redirect_uri" => @loopback,
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "state" => "state-pkce-test",
          "scope" => "dashboard.publish edge.manage"
        },
        overrides
      )

    "/api/v1/cli/auth/authorize?" <> URI.encode_query(query)
  end

  defp pkce_pair do
    verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end
end
