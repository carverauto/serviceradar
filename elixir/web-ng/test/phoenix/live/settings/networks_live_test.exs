defmodule ServiceRadarWebNGWeb.Settings.NetworksLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.NetworkDiscovery.MapperMikrotikController
  alias ServiceRadar.NetworkDiscovery.MapperUnifiController
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepGroupExecution
  alias ServiceRadar.SweepJobs.SweepProfile
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

  test "shows last run and status from latest execution", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(:create, %{name: "Ran Group #{unique}"})
      |> Ash.create(scope: scope)

    {:ok, execution} =
      SweepGroupExecution
      |> Ash.Changeset.for_create(:start, %{
        sweep_group_id: group.id,
        agent_id: "farm01"
      })
      |> Ash.create(scope: scope)

    {:ok, execution} =
      execution
      |> Ash.Changeset.for_update(:complete, %{hosts_total: 99, hosts_available: 42})
      |> Ash.update(scope: scope)

    {:ok, _lv, html} = live(conn, ~p"/settings/networks")

    assert html =~ group.name
    assert html =~ "Completed"
    assert html =~ Calendar.strftime(execution.completed_at || execution.started_at, "%Y-%m-%d %H:%M")
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
    assert html =~ "Banner grab"
    assert html =~ "Outbound traffic preview"
    assert html =~ "form[banner_grab][ports][ssh]"
  end

  test "banner grab protocol checkboxes stay selected after validate", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/profiles/new")

    html =
      lv
      |> form("#scanner-profile-form", %{
        "form" => %{
          "name" => "Banner Draft",
          "banner_grab" => %{
            "enabled" => "true",
            "protocols" => ["ssh", "http"]
          }
        }
      })
      |> render_change()

    assert html =~ ~s(name="form[banner_grab][enabled]")
    assert html =~ ~s(value="ssh")
    assert html =~ ~s(value="http")
    assert html =~ "checked"
  end

  test "saves banner grab controls on scanner profile", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])
    name = "Banner Profile #{unique}"

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/profiles/new")

    lv
    |> form("#scanner-profile-form", %{
      "form" => %{
        "name" => name,
        "description" => "",
        "ports" => "22, 80",
        "concurrency" => "50",
        "timeout" => "3s",
        "sweep_modes" => ["icmp", "tcp"],
        "enabled" => "true",
        "banner_grab" => %{
          "enabled" => "true",
          "protocols" => ["ssh", "http"],
          "ports" => %{"ssh" => "22", "http" => "80, 443", "ntp" => "123"},
          "connect_timeout_ms" => "1500",
          "read_timeout_ms" => "1200",
          "max_banner_bytes" => "2048",
          "max_concurrency_per_host" => "2",
          "max_global_concurrency" => "64",
          "max_probe_rate_per_second" => "100",
          "max_candidate_queue" => "4096",
          "match_batch_size" => "128",
          "match_batch_max_bytes" => "524288",
          "min_reprobe_interval_s" => "3600",
          "per_host_rate_limit_ms" => "50"
        }
      }
    })
    |> render_submit()

    profile =
      SweepProfile
      |> Ash.read!(scope: scope)
      |> Enum.find(&(&1.name == name))

    assert profile.banner_grab.enabled
    assert Enum.sort(profile.banner_grab.protocols) == [:http, :ssh]
    assert profile.banner_grab.ports["ssh"] == [22]
    assert profile.banner_grab.ports["http"] == [80, 443]
    refute Map.has_key?(profile.banner_grab.ports, "ntp")
    assert profile.banner_grab.connect_timeout_ms == 1_500
    assert profile.banner_grab.max_global_concurrency == 64
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

  test "run now shows an actionable validation message when no mapper agent is online", %{
    conn: conn,
    scope: scope
  } do
    unique = System.unique_integer([:positive])

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(:create, %{
        name: "Offline Discovery #{unique}",
        enabled: false
      })
      |> Ash.create(scope: scope)

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/discovery")

    html =
      lv
      |> element("#run-mapper-job-#{job.id}")
      |> render_click()

    assert html =~
             "Failed to run discovery job: No online mapper-capable agent is available for this discovery job."

    refute html =~ "Ash.Error"
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
