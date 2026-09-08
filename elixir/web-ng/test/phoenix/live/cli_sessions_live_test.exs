defmodule ServiceRadarWebNGWeb.Settings.CliSessionsLiveTest do
  @moduledoc """
  Integration tests for `Settings → CLI sessions` (read + revoke flow).

  Covers proposal `add-cli-device-auth` §6.3 (revoke writes RevokedToken,
  next API call 401s) + §7.5 + §12.6 (read_*/revoke_* permission gating).

  Run via the srql-fixtures CNPG instance per the
  `.agents/skills/srql-fixtures-db-tests` skill.
  """
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.CliSession
  alias ServiceRadar.Identity.DeviceAuthorization
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.Auth.TokenRevocation

  @moduletag :integration

  describe "non-admin (read_own / revoke_own)" do
    setup do
      user = AccountsFixtures.user_fixture(%{role: :viewer})
      conn = log_in_user(Phoenix.ConnTest.build_conn(), user)
      %{conn: conn, user: user}
    end

    test "renders only own sessions; no User column", %{conn: conn, user: user} do
      other_user = AccountsFixtures.user_fixture()
      mine = mint_session(user, "BCDF-GHJK")
      theirs = mint_session(other_user, "LMNP-QRST")

      {:ok, view, _html} = live(conn, ~p"/settings/cli-sessions")

      html = render(view)
      # Own row is in the table.
      assert html =~ mine.jti
      # Other user's row is NOT.
      refute html =~ theirs.jti
      # No admin User column header.
      refute html =~ "<th>User</th>"
    end

    test "Revoke flips status + writes a RevokedToken so the JWT is denied",
         %{conn: conn, user: user} do
      session = mint_session(user, "VWXZ-BCDF")

      # The JWT validates fine before revoke.
      assert :ok = TokenRevocation.check_revoked(session.jti)

      {:ok, view, _html} = live(conn, ~p"/settings/cli-sessions")

      view
      |> element("button[phx-click='revoke'][phx-value-jti='#{session.jti}']")
      |> render_click()

      # The metadata row flipped to :revoked.
      actor = SystemActor.system(:test)
      {:ok, reread} = CliSession.get_by_jti(session.jti, actor: actor)
      assert reread.status == :revoked

      # And the token-revocation denylist now matches the jti, so the
      # ApiAuth plug's Guardian.verify_not_revoked hook 401s the JWT.
      assert {:error, :revoked} = TokenRevocation.check_revoked(session.jti)
    end
  end

  describe "admin (read_any / revoke_any)" do
    setup do
      admin = AccountsFixtures.user_fixture(%{role: :admin})
      conn = log_in_user(Phoenix.ConnTest.build_conn(), admin)
      %{conn: conn, admin: admin}
    end

    test "lists every user's sessions and surfaces the User column", %{conn: conn, admin: admin} do
      user_a = AccountsFixtures.user_fixture()
      user_b = AccountsFixtures.user_fixture()
      _ = mint_session(admin, "RNTC-VWXZ")
      _ = mint_session(user_a, "BCDF-GHJK")
      _ = mint_session(user_b, "LMNP-QRST")

      {:ok, view, _html} = live(conn, ~p"/settings/cli-sessions")

      html = render(view)
      assert html =~ "User</th>"
      # All three users' ids should be visible.
      assert html =~ admin.id
      assert html =~ user_a.id
      assert html =~ user_b.id
    end

    test "admin can revoke another user's session", %{conn: conn} do
      target = AccountsFixtures.user_fixture()
      session = mint_session(target, "QRST-VWXZ")

      {:ok, view, _html} = live(conn, ~p"/settings/cli-sessions")

      view
      |> element("button[phx-click='revoke'][phx-value-jti='#{session.jti}']")
      |> render_click()

      actor = SystemActor.system(:test)
      {:ok, reread} = CliSession.get_by_jti(session.jti, actor: actor)
      assert reread.status == :revoked
    end
  end

  ## Helpers

  defp mint_session(user, user_code) do
    actor = SystemActor.system(:test)

    {:ok, device_row} =
      DeviceAuthorization.create(
        %{
          device_code_hash: :sha256 |> :crypto.hash(user_code) |> Base.encode16(case: :lower),
          user_code: user_code,
          client_id: "serviceradar-cli",
          scope: "dashboard.publish",
          expires_at: DateTime.add(DateTime.utc_now(), 900, :second),
          interval_seconds: 5
        },
        actor: actor
      )

    {:ok, _approved} = DeviceAuthorization.approve(device_row, user.id, actor: actor)

    {:ok, _jwt, claims} = Guardian.create_api_token(user, scopes: [:read], ttl: {30, :day})
    issued_at = DateTime.from_unix!(claims["iat"])
    expires_at = DateTime.from_unix!(claims["exp"])

    {:ok, session} =
      CliSession.create(
        %{
          jti: claims["jti"],
          device_authorization_id: device_row.id,
          user_id: user.id,
          client_id: "serviceradar-cli",
          scope: "dashboard.publish",
          issued_at: issued_at,
          expires_at: expires_at
        },
        actor: actor
      )

    session
  end
end
