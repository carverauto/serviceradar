defmodule ServiceRadarWebNGWeb.Settings.PrefixTagsLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  setup do
    Store.clear()

    on_exit(fn ->
      Store.clear()
    end)

    :ok
  end

  test "viewer is blocked from prefix tags settings", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/settings/networks/prefix-tags")
    assert to == ~p"/settings/profile"
  end

  test "admin can open prefix tags settings", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings/networks/prefix-tags")

    assert html =~ "Prefix Tags"
    assert html =~ "Active trie stats"
    assert html =~ "IP preview"
    assert html =~ "Add prefix"
  end

  test "new prefix form explains structured tags vs extra tags", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/prefix-tags")
    html = render_click(lv, "new", %{})

    assert html =~ "Extra tags (optional)"
    assert html =~ "Site, role, tenant, and status become tags automatically"
    refute html =~ ~s(name="prefix_tag[tags]" required)
  end

  test "IP preview uses the local Store trie", %{conn: conn} do
    Store.put_rows("manual", [
      %{prefix: "10.1.2.0/24", tags: ["site:hq", "role:wifi"], source: "manual"}
    ])

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/prefix-tags")

    html =
      lv
      |> form("form[phx-submit=preview]", %{"ip" => "10.1.2.50"})
      |> render_submit()

    assert html =~ "site:hq"
    assert html =~ "role:wifi"
    assert html =~ "10.1.2.0/24"
  end

  test "source tabs are available for imported views", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/prefix-tags")

    html = render_click(lv, "select_source", %{"source" => "netbox"})
    assert html =~ "netbox"
    assert html =~ "Read-only imported source"
    refute html =~ "Add prefix"
  end

  test "external materializer tab shows trie stats not empty CNPG table", %{conn: conn} do
    Store.put_rows("provider", [
      %{prefix: "203.0.113.0/24", tags: ["provider:ExampleCloud"], source: "provider"}
    ])

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/prefix-tags")
    html = render_click(lv, "select_source", %{"source" => "provider"})

    assert html =~ "In-memory materializer"
    assert html =~ "provider"
    refute html =~ "No prefixes for this source yet."
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end
end
