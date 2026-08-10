defmodule ServiceRadarWebNGWeb.AnsibleCatalogLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNG.Repo

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()
    %{conn: log_in_user(conn, user)}
  end

  test "catalog loads playbooks only after the LiveView connects", %{conn: conn} do
    playbook_name = "disconnected-catalog-#{System.unique_integer([:positive])}"

    Repo.insert_all(
      "ansible_playbooks",
      [%{source_type: "git", name: playbook_name}],
      prefix: "platform"
    )

    static_document =
      conn
      |> get(~p"/ansible/catalog")
      |> html_response(200)
      |> LazyHTML.from_fragment()

    assert static_document
           |> LazyHTML.query("#ansible-catalog-count")
           |> LazyHTML.text() =~ "0 playbooks"

    refute LazyHTML.text(static_document) =~ playbook_name

    {:ok, view, _html} = live(conn, ~p"/ansible/catalog")

    assert has_element?(view, "#ops-topbar")
    assert has_element?(view, ".sr-ops-sidebar[aria-label='Primary navigation']")
    assert has_element?(view, ".sr-ops-page-title", "Ansible playbook catalog")
    assert has_element?(view, "h1", "Ansible playbook catalog")
    assert has_element?(view, "#ansible-catalog tr", playbook_name)
  end
end
