defmodule ServiceRadarWebNGWeb.UserLive.ApiCredentialsTest do
  @moduledoc """
  Regression coverage for the API credentials (OAuth client) management view.

  The delete/revoke handlers look the client up with `OAuthClient.get_by_id/2`.
  That read is governed by the owner policy
  (`user_id == ^actor(:id)` OR `is_admin()`), so it must be given the
  current-scope user as the Ash actor. Previously the actor was omitted, the
  read filtered to empty, and the handler surfaced a spurious
  "Client not found." — delete/revoke never worked.
  """
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.AccountsFixtures

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.OAuthClient
  alias ServiceRadar.Identity.OAuthClient.Credentials
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User

  # Real logins stamp sudo mode in the session (20-minute window); the
  # ApiCredentials LiveView mounts under `:require_sudo_mode`, so tests must
  # simulate the freshly-authenticated session.
  defp put_sudo_mode(conn) do
    Plug.Conn.put_session(
      conn,
      "sudo_authenticated_at",
      DateTime.to_unix(DateTime.utc_now())
    )
  end

  defp create_client!(user, name) do
    {:ok, client, _secret} =
      Credentials.create_client(user.id,
        name: name,
        scopes: ["read"],
        actor: user
      )

    client
  end

  describe "permission gate" do
    test "redirects when the role profile omits settings.api_credentials.manage", %{conn: conn} do
      user = restrict_user(user_fixture(%{role: :viewer}), ["devices.view"])

      assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
               conn
               |> log_in_user(user)
               |> put_sudo_mode()
               |> live(~p"/settings/api-credentials")
    end
  end

  describe "delete_client" do
    setup %{conn: conn} do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> put_sudo_mode()
      %{conn: conn, user: user}
    end

    test "a user can delete their own OAuth client (regression: was 'Client not found')",
         %{conn: conn, user: user} do
      client = create_client!(user, "Deletable Client")

      {:ok, lv, html} = live(conn, ~p"/settings/api-credentials")
      assert html =~ "Deletable Client"

      result = render_click(lv, "delete_client", %{"id" => to_string(client.id)})

      assert result =~ "Client deleted successfully."
      refute result =~ "Client not found."

      # The client is actually destroyed, not just hidden.
      assert {:ok, []} = OAuthClient.list_by_user(user.id, actor: user)
    end

    test "a user can delete their own revoked OAuth client", %{conn: conn, user: user} do
      client = create_client!(user, "Revoked Client")
      {:ok, _} = OAuthClient.revoke(client, %{}, actor: user)

      {:ok, lv, _html} = live(conn, ~p"/settings/api-credentials")

      # `:by_id` has no enabled/revoked filter, so a revoked client is still
      # findable (and deletable) once the actor is passed.
      result = render_click(lv, "delete_client", %{"id" => to_string(client.id)})

      assert result =~ "Client deleted successfully."
      refute result =~ "Client not found."
      assert {:ok, []} = OAuthClient.list_by_user(user.id, actor: user)
    end
  end

  describe "confirm_revoke" do
    setup %{conn: conn} do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> put_sudo_mode()
      %{conn: conn, user: user}
    end

    test "a user can revoke their own OAuth client", %{conn: conn, user: user} do
      client = create_client!(user, "Revocable Client")

      {:ok, lv, _html} = live(conn, ~p"/settings/api-credentials")

      result = render_click(lv, "confirm_revoke", %{"id" => to_string(client.id)})

      assert result =~ "Client revoked successfully."
      refute result =~ "Client not found."
    end
  end

  defp restrict_user(user, permissions) do
    actor = SystemActor.system(:api_credentials_rbac_test)

    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "api-creds-rbac-#{System.unique_integer([:positive])}",
          description: "catalog-gate fixture",
          permissions: permissions
        },
        actor: actor,
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!()

    {:ok, assigned} = User.update_role_profile(user, %{role_profile_id: profile.id}, actor: actor)
    RBAC.invalidate_user_cache(assigned.id)
    RBAC.clear_process_cache()
    assigned
  end
end
