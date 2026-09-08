defmodule ServiceRadarWebNGWeb.CliDeviceAuthorizeLiveTest do
  @moduledoc """
  Integration tests for the `/cli/auth/device` approval LiveView.

  Covers proposal `add-cli-device-auth` §5.6 + §12.4 (RBAC gate on
  `cli.session.create`).

  Run via the srql-fixtures CNPG instance per the
  `.agents/skills/srql-fixtures-db-tests` skill.
  """
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAuthorization
  alias ServiceRadarWebNG.AccountsFixtures

  @moduletag :integration

  describe "unauthenticated visitor" do
    test "redirects to log-in with the user_code preserved in return_to", %{conn: conn} do
      assert {:error, {:redirect, %{to: redirect_to}}} =
               live(conn, ~p"/cli/auth/device?user_code=WDJB-MJHT")

      assert redirect_to =~ "/users/log-in"
      assert redirect_to =~ "return_to=%2Fcli%2Fauth%2Fdevice%3Fuser_code%3DWDJB-MJHT"
    end
  end

  describe "authenticated visitor with cli.session.create" do
    setup :register_and_log_in_user

    test "no code in URL renders the prompt form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cli/auth/device")

      assert has_element?(view, "input[name='user_code']")
      assert has_element?(view, "button[type='submit']")
    end

    test "valid pending code shows Approve / Deny buttons", %{conn: conn} do
      mint_pending("DCBF-GJLM")

      {:ok, view, _html} = live(conn, ~p"/cli/auth/device?user_code=DCBF-GJLM")

      assert has_element?(view, "button", "Approve")
      assert has_element?(view, "button", "Deny")
      assert has_element?(view, ".font-mono.tracking-widest", "DCBF-GJLM")
      assert has_element?(view, ".font-medium", "serviceradar-cli")
      assert has_element?(view, ".font-mono", "dashboard.publish")
    end

    test "Approve flips the row to :approved with the user_id stamped", %{conn: conn, user: user} do
      mint_pending("BCDF-GHJK")

      {:ok, view, _html} = live(conn, ~p"/cli/auth/device?user_code=BCDF-GHJK")
      view |> element("button", "Approve") |> render_click()

      actor = SystemActor.system(:test)
      {:ok, row} = DeviceAuthorization.get_by_user_code("BCDF-GHJK", actor: actor)
      assert row.status == :approved
      assert row.user_id == user.id
    end

    test "Deny flips the row to :denied", %{conn: conn} do
      mint_pending("LMNP-QRST")

      {:ok, view, _html} = live(conn, ~p"/cli/auth/device?user_code=LMNP-QRST")
      view |> element("button", "Deny") |> render_click()

      actor = SystemActor.system(:test)
      {:ok, row} = DeviceAuthorization.get_by_user_code("LMNP-QRST", actor: actor)
      assert row.status == :denied
    end

    test "unknown code lands on the :unknown error state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cli/auth/device?user_code=ZZZZ-ZZZZ")

      assert render(view) =~ "We couldn&#39;t find that code"
    end

    test "expired code refuses Approve / Deny buttons", %{conn: conn} do
      "VWXZ-BCDF" |> mint_pending() |> backdate_expiry!()

      {:ok, view, _html} = live(conn, ~p"/cli/auth/device?user_code=VWXZ-BCDF")

      html = render(view)
      assert html =~ "This code has expired"
      refute has_element?(view, "button", "Approve")
      refute has_element?(view, "button", "Deny")
    end
  end

  describe "authenticated visitor without cli.session.create (viewer)" do
    setup do
      user = AccountsFixtures.user_fixture(%{role: :viewer})
      conn = log_in_user(Phoenix.ConnTest.build_conn(), user)
      %{conn: conn, user: user}
    end

    test "pending code renders without Approve / Deny + shows the role-callout", %{conn: conn} do
      mint_pending("MNPQ-RSTV")

      {:ok, view, _html} = live(conn, ~p"/cli/auth/device?user_code=MNPQ-RSTV")

      html = render(view)
      assert html =~ "MNPQ-RSTV"
      assert html =~ "Your role does not allow CLI authentication"
      refute has_element?(view, "button", "Approve")
      refute has_element?(view, "button", "Deny")
    end
  end

  ## Helpers

  defp mint_pending(user_code) do
    actor = SystemActor.system(:test)

    {:ok, row} =
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

    row
  end

  defp backdate_expiry!(%DeviceAuthorization{id: id}) do
    past = DateTime.add(DateTime.utc_now(), -3600, :second)

    Ecto.Adapters.SQL.query!(
      ServiceRadar.Repo,
      "UPDATE platform.device_authorizations SET expires_at = $1 WHERE id = $2",
      [past, Ecto.UUID.dump!(id)]
    )

    :ok
  end
end
