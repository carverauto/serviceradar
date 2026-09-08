defmodule ServiceRadarWebNGWeb.Admin.PluginRepositoryLiveTest do
  @moduledoc """
  The catalog-source picker on Settings -> Agents -> Plugins.

  The field this replaces was never a setting: it assigned the submitted URL to
  socket state and nothing else, so it reset on the next mount while the sync
  worker kept importing from config. These tests pin the two properties that
  make the replacement a setting rather than a widget -- the selection comes from
  persisted rows, and managing those rows is gated separately from staging
  packages.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.AshTestHelpers, only: [system_actor: 0, user_fixture: 0]

  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Plugins.PluginRepository
  alias ServiceRadarWebNG.RBAC

  require Ash.Query

  @moduletag :integration

  @plugins_path "/settings/agents/plugins"

  defp grant_permissions(user, permissions) do
    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Plugin repository LiveView #{System.unique_integer([:positive])}",
          description: "Test profile for plugin repository permissions",
          permissions: permissions
        },
        actor: system_actor(),
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!()

    updated =
      user
      |> Ash.Changeset.for_update(:update_role_profile, %{role_profile_id: profile.id}, actor: system_actor())
      |> Ash.update!()

    RBAC.clear_process_cache()
    RBAC.Cache.put(updated.id, MapSet.new(permissions))

    updated
  end

  defp log_in(conn, permissions) do
    user = grant_permissions(user_fixture(), permissions)
    {log_in_user(conn, user), user}
  end

  defp create_repository(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: "Acme Plugins",
          repo_url: "https://github.com/acme/live-#{System.unique_integer([:positive])}",
          index_asset_name: "serviceradar-wasm-plugin-index.json",
          signing_key_id: "acme-v1",
          signing_public_key: Base.encode64(:crypto.strong_rand_bytes(32))
        },
        overrides
      )

    PluginRepository
    |> Ash.Changeset.for_create(:create, attrs, actor: system_actor())
    |> Ash.create!()
  end

  defp builtin do
    PluginRepository
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(builtin == true)
    |> Ash.read_one!(actor: system_actor())
  end

  describe "the catalog source picker" do
    test "renders a dropdown of repositories with the built-in preselected", %{conn: conn} do
      {conn, _user} = log_in(conn, ["plugins.view", "plugins.repositories.manage"])
      other = create_repository(%{name: "Acme Plugins"})

      {:ok, _live, html} = live(conn, @plugins_path)

      assert html =~ "plugin-repository-select"
      assert html =~ builtin().name
      assert html =~ other.name

      # The free-form URL field is gone, not merely hidden.
      refute html =~ "first-party-repository-url"
    end

    test "offers the Add New action to a user who may manage repositories", %{conn: conn} do
      {conn, _user} = log_in(conn, ["plugins.view", "plugins.repositories.manage"])

      {:ok, _live, html} = live(conn, @plugins_path)

      assert html =~ "__add_new__"
    end

    test "a viewer sees the dropdown but not Add New", %{conn: conn} do
      # Switching which catalog you look at is a read; deciding which sources
      # are trusted is not.
      {conn, _user} = log_in(conn, ["plugins.view"])
      create_repository()

      {:ok, _live, html} = live(conn, @plugins_path)

      assert html =~ "plugin-repository-select"
      refute html =~ "__add_new__"
    end
  end

  describe "the add repository modal" do
    setup %{conn: conn} do
      {conn, user} = log_in(conn, ["plugins.view", "plugins.repositories.manage"])
      %{conn: conn, user: user}
    end

    test "choosing Add New opens the modal", %{conn: conn} do
      {:ok, live, _html} = live(conn, @plugins_path)

      html =
        live
        |> element("#select-first-party-repository-form")
        |> render_change(%{"repository_id" => "__add_new__"})

      assert html =~ "plugin-repository-modal"
      assert html =~ "Add plugin repository"
    end

    test "saving a valid repository selects it and closes the modal", %{conn: conn} do
      {:ok, live, _html} = live(conn, @plugins_path)

      live
      |> element("#select-first-party-repository-form")
      |> render_change(%{"repository_id" => "__add_new__"})

      html =
        live
        |> form("#plugin-repository-form", %{
          "repository" => %{
            "name" => "Acme Saved",
            "repo_url" => "https://github.com/acme/saved-repo",
            "index_asset_name" => "serviceradar-wasm-plugin-index.json",
            "signing_key_id" => "acme-v1",
            "signing_public_key" => Base.encode64(:crypto.strong_rand_bytes(32)),
            "github_token" => ""
          }
        })
        |> render_submit()

      assert html =~ "Acme Saved"
      refute html =~ "Add plugin repository"

      assert {:ok, saved} =
               PluginRepository
               |> Ash.Query.for_read(:by_repo_url, %{
                 repo_url: "https://github.com/acme/saved-repo"
               })
               |> Ash.read_one(actor: system_actor())

      assert saved.name == "Acme Saved"
    end

    test "an invalid repository keeps the modal open and shows the error", %{conn: conn} do
      {:ok, live, _html} = live(conn, @plugins_path)

      live
      |> element("#select-first-party-repository-form")
      |> render_change(%{"repository_id" => "__add_new__"})

      html =
        live
        |> form("#plugin-repository-form", %{
          "repository" => %{
            "name" => "Bad Key",
            "repo_url" => "https://github.com/acme/bad-key",
            "index_asset_name" => "serviceradar-wasm-plugin-index.json",
            "signing_key_id" => "acme-v1",
            # Not a 32-byte ed25519 key.
            "signing_public_key" => Base.encode64(<<1, 2, 3>>),
            "github_token" => ""
          }
        })
        |> render_submit()

      # The modal must not close and discard what was typed.
      assert html =~ "plugin-repository-modal"
      assert html =~ "32-byte"
    end

    test "a malformed repository URL is reported rather than saved", %{conn: conn} do
      {:ok, live, _html} = live(conn, @plugins_path)

      live
      |> element("#select-first-party-repository-form")
      |> render_change(%{"repository_id" => "__add_new__"})

      html =
        live
        |> form("#plugin-repository-form", %{
          "repository" => %{
            "name" => "Wrong Host",
            "repo_url" => "https://gitlab.com/acme/nope",
            "index_asset_name" => "serviceradar-wasm-plugin-index.json",
            "signing_key_id" => "acme-v1",
            "signing_public_key" => Base.encode64(:crypto.strong_rand_bytes(32)),
            "github_token" => ""
          }
        })
        |> render_submit()

      assert html =~ "plugin-repository-modal"
      assert html =~ "github.com"
    end
  end

  describe "the built-in repository" do
    test "can be disabled but offers no edit or remove control", %{conn: conn} do
      {conn, _user} = log_in(conn, ["plugins.view", "plugins.repositories.manage"])

      {:ok, live, html} = live(conn, @plugins_path)

      # The built-in row is selected by default, so its controls are the ones
      # rendered. Edit and remove would always fail at the resource, so the UI
      # must not offer them.
      assert html =~ "Disable repository"
      refute html =~ "Remove repository"
      refute html =~ "Edit repository"

      html = live |> element(~s{[phx-click="toggle_repository"]}) |> render_click()

      assert html =~ "Disabled"
      refute builtin().enabled
    end
  end

  describe "server-side authorization" do
    test "a viewer cannot create a repository even by sending the event", %{conn: conn} do
      # The hidden control is not the check: the handler re-checks.
      {conn, _user} = log_in(conn, ["plugins.view"])

      {:ok, live, _html} = live(conn, @plugins_path)

      html =
        render_change(live, "select_first_party_repository", %{"repository_id" => "__add_new__"})

      assert html =~ "permission to manage plugin repositories"
      refute html =~ "Add plugin repository"
    end

    test "a viewer cannot remove a repository by sending the event", %{conn: conn} do
      repository = create_repository()
      {conn, _user} = log_in(conn, ["plugins.view"])

      {:ok, live, _html} = live(conn, @plugins_path)

      html = render_click(live, "delete_repository", %{"id" => repository.id})

      assert html =~ "permission to manage plugin repositories"

      assert {:ok, still_there} =
               PluginRepository
               |> Ash.Query.for_read(:by_id, %{id: repository.id})
               |> Ash.read_one(actor: system_actor())

      assert still_there
    end
  end
end
