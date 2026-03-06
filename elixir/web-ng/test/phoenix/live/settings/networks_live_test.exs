defmodule ServiceRadarWebNGWeb.Settings.NetworksLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.NetworkDiscovery.{MapperJob, MapperMikrotikController, MapperUnifiController}
  alias ServiceRadar.SweepJobs.{SweepGroup, SweepProfile}
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  setup do
    ensure_mikrotik_table!()
    :ok
  end

  setup :register_and_log_in_admin_user

  test "lists sweep groups on the groups tab", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(:create, %{name: "Group #{unique}"})
      |> Ash.create(scope: scope)

    {:ok, _lv, html} = live(conn, ~p"/settings/networks")

    assert html =~ "Sweep Groups"
    assert html =~ group.name
  end

  test "switches to profiles tab and lists profiles", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])

    {:ok, profile} =
      SweepProfile
      |> Ash.Changeset.for_create(:create, %{name: "Profile #{unique}"})
      |> Ash.create(scope: scope)

    {:ok, lv, _html} = live(conn, ~p"/settings/networks")

    html =
      lv
      |> element("button[phx-value-tab='profiles']")
      |> render_click()

    assert html =~ "Scanner Profiles"
    assert html =~ profile.name
  end

  test "renders new sweep group form with SRQL targeting", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/settings/networks/groups/new")

    assert html =~ "New Sweep Group"
    assert html =~ "Target Query (SRQL)"

    html =
      lv
      |> element("button[aria-label='Toggle query builder']")
      |> render_click()

    assert html =~ "Query Builder"
  end

  test "hydrates builder from edit query with negated list filter", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(:create, %{
        name: "Builder Hydration #{unique}",
        interval: "1h",
        partition: "default",
        target_query: "in:devices !discovery_sources:(armis)"
      })
      |> Ash.create(scope: scope)

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/groups/#{group.id}/edit")

    lv
    |> element("button[aria-label='Toggle query builder']")
    |> render_click()

    assert has_element?(
             lv,
             "select[name='builder[filters][0][field]'] option[value='discovery_sources'][selected]"
           )

    assert has_element?(
             lv,
             "select[name='builder[filters][0][op]'] option[value='not_equals'][selected]"
           )

    assert has_element?(
             lv,
             "input[name='builder[filters][0][value]'][value='armis']"
           )
  end

  test "renders new scanner profile form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings/networks/profiles/new")

    assert html =~ "New Scanner Profile"
    assert html =~ "Sweep Modes"
  end

  test "lists discovery jobs on the discovery tab", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(:create, %{name: "Discovery #{unique}"})
      |> Ash.create(scope: scope)

    {:ok, _lv, html} = live(conn, ~p"/settings/networks/discovery")

    assert html =~ "Discovery Jobs"
    assert html =~ job.name
  end

  test "discovery job form lists mapper-capable agents", %{conn: conn} do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: "agent-mapper", capabilities: ["mapper"]})

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/discovery/new")

    assert has_element?(lv, "select[name='mapper_job[agent_id]']")
    assert has_element?(lv, "option[value='#{agent.uid}']")
  end

  test "discovery job form renders mikrotik api fields", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/settings/networks/discovery/new")

    assert html =~ "MikroTik RouterOS"
    assert has_element?(lv, "input[name='mikrotik[base_url]']")
    assert has_element?(lv, "input[name='mikrotik[username]']")
    assert has_element?(lv, "input[name='mikrotik[password]']")
  end

  test "discovery job table includes run now action", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(:create, %{name: "Discovery #{unique}"})
      |> Ash.create(scope: scope)

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/discovery")

    assert has_element?(lv, "#run-mapper-job-#{job.id}")
  end

  test "shows masked placeholders for stored controller credentials", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(:create, %{name: "Discovery #{unique}"})
      |> Ash.create(scope: scope)

    {:ok, _controller} =
      MapperUnifiController
      |> Ash.Changeset.for_create(:create, %{
        name: "unifi-#{unique}",
        base_url: "https://controller.example",
        api_key: "api-secret",
        mapper_job_id: job.id
      })
      |> Ash.create(scope: scope)

    {:ok, lv, html} = live(conn, ~p"/settings/networks/discovery/#{job.id}/edit")

    assert html =~ "API key stored"
    assert has_element?(lv, "input[name='unifi[api_key]'][placeholder='stored']")
  end

  test "shows masked placeholders for stored mikrotik credentials", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(:create, %{name: "Discovery #{unique}"})
      |> Ash.create(scope: scope)

    {:ok, _controller} =
      MapperMikrotikController
      |> Ash.Changeset.for_create(:create, %{
        name: "mikrotik-#{unique}",
        base_url: "https://router.example/rest",
        username: "admin",
        password: "router-secret",
        mapper_job_id: job.id
      })
      |> Ash.create(scope: scope)

    {:ok, lv, html} = live(conn, ~p"/settings/networks/discovery/#{job.id}/edit")

    assert html =~ "Password stored"
    assert has_element?(lv, "input[name='mikrotik[password]'][placeholder='stored']")
    assert has_element?(lv, "input[name='mikrotik[username]'][value='admin']")
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp ensure_mikrotik_table! do
    Ecto.Adapters.SQL.query!(
      ServiceRadar.Repo,
      """
      CREATE TABLE IF NOT EXISTS platform.mapper_mikrotik_controllers (
        id uuid PRIMARY KEY,
        name text,
        base_url text NOT NULL,
        username text NOT NULL,
        encrypted_password bytea,
        insecure_skip_verify boolean NOT NULL DEFAULT false,
        mapper_job_id uuid NOT NULL,
        inserted_at timestamp(6) without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
        updated_at timestamp(6) without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
      )
      """,
      []
    )
  end
end
