defmodule ServiceRadarWebNGWeb.Settings.NetworksLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias Ash.Error.Invalid
  alias Ecto.Adapters.SQL
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.NetworkDiscovery.MapperMikrotikController
  alias ServiceRadar.NetworkDiscovery.MapperUnifiController
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepGroupExecution
  alias ServiceRadar.SweepJobs.SweepHostResult
  alias ServiceRadar.SweepJobs.SweepProfile
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  @moduletag :web_ng_shared_fixture_db
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

  test "renders independent run-now member progress and immediate dispatch failures", %{
    conn: conn,
    scope: scope
  } do
    unique = System.unique_integer([:positive])

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(:create, %{name: "Fanout Group #{unique}"})
      |> Ash.create(scope: scope)

    {:ok, live_view, _html} = live(conn, ~p"/settings/networks")

    send(live_view.pid, {
      :sweep_dispatch,
      %{
        sweep_group_id: group.id,
        sweep_dispatch_id: "dispatch-old",
        sweep_dispatch_generation: "1",
        phase: :finished,
        commands: [%{agent_id: "agent-old", command_id: "command-old"}],
        failures: []
      }
    })

    send(live_view.pid, {
      :command_result,
      %{
        sweep_group_id: group.id,
        sweep_dispatch_id: "dispatch-new",
        sweep_dispatch_generation: "2",
        command_id: "command-a",
        agent_id: "agent-a",
        message: "completed A",
        success: true,
        payload: %{hosts: 8}
      }
    })

    assert render(element(live_view, "#sweep-command-member-command-old")) =~ "Queued"

    send(live_view.pid, {
      :sweep_dispatch,
      %{
        sweep_group_id: group.id,
        sweep_dispatch_id: "dispatch-new",
        sweep_dispatch_generation: "2",
        phase: :finished,
        commands: [
          %{agent_id: "agent-a", command_id: "command-a"},
          %{agent_id: "agent-b", command_id: "command-b"}
        ],
        failures: [
          %{agent_id: "agent-c", reason: {:agent_capability_missing, "agent-c", "sweep"}}
        ]
      }
    })

    status = render(element(live_view, "#sweep-command-status-#{group.id}"))
    assert status =~ "1 pending, 1 completed, 1 failed"
    assert status =~ "agent-c"
    assert status =~ "Missing sweep capability"
    assert render(element(live_view, "#sweep-command-member-command-a")) =~ "Completed"

    send(live_view.pid, {
      :command_progress,
      %{
        sweep_group_id: group.id,
        sweep_dispatch_id: "dispatch-new",
        sweep_dispatch_generation: "2",
        command_id: "command-b",
        agent_id: "agent-b",
        message: "running B",
        progress_percent: 55
      }
    })

    assert render(element(live_view, "#sweep-command-member-command-b")) =~ "Running 55%"

    send(live_view.pid, {
      :command_ack,
      %{
        sweep_group_id: group.id,
        sweep_dispatch_id: "dispatch-new",
        sweep_dispatch_generation: "2",
        command_id: "command-a",
        agent_id: "agent-a",
        message: "late A ack"
      }
    })

    assert render(element(live_view, "#sweep-command-member-command-a")) =~ "Completed"
    assert render(element(live_view, "#sweep-command-member-command-b")) =~ "Running 55%"

    status = render(element(live_view, "#sweep-command-status-#{group.id}"))
    assert status =~ "1 pending, 1 completed, 1 failed"
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

    {:ok, lv, html} = live(conn, ~p"/settings/networks")

    assert html =~ group.name
    assert html =~ "Completed"

    last_run_at = execution.completed_at || execution.started_at

    assert has_element?(
             lv,
             ~s(time#settings-sweep-group-#{group.id}-last-run-at[datetime="#{DateTime.to_iso8601(last_run_at)}"][data-user-time-zone="Etc/UTC"])
           )
  end

  # Regression for #4076: a sweep group that has run could not be deleted at all.
  # Its executions -- and their host results one level further down -- held
  # foreign keys with no ON DELETE action, so PostgreSQL refused the delete and
  # the operator saw only a generic failure. Any group old enough to be worth
  # deleting is in exactly this shape, which is why the bug looked like "delete
  # is broken" rather than "delete is broken for groups with history".
  test "deletes a sweep group that has execution history", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(:create, %{name: "Deletable Group #{unique}"})
      |> Ash.create(scope: scope)

    {:ok, execution} =
      SweepGroupExecution
      |> Ash.Changeset.for_create(:start, %{
        sweep_group_id: group.id,
        agent_id: "agent-#{unique}"
      })
      |> Ash.create(scope: scope)

    {:ok, host_result} =
      SweepHostResult
      |> Ash.Changeset.for_create(:create, %{
        execution_id: execution.id,
        ip: "192.0.2.10",
        status: :available
      })
      |> Ash.create(scope: scope)

    {:ok, lv, html} = live(conn, ~p"/settings/networks")
    assert html =~ group.name

    # The operator agrees to discarding the history with its size in front of
    # them, not after the fact.
    assert html =~ "1 execution and"

    lv
    |> element(~s(button[phx-click="delete_group"][phx-value-id="#{group.id}"]))
    |> render_click()

    assert render(lv) =~ "Sweep group deleted"
    refute render(lv) =~ group.name

    assert {:error, %Invalid{}} = Ash.get(SweepGroup, group.id, scope: scope)

    # The dependent rows go with the group rather than being left orphaned.
    assert {:error, %Invalid{}} =
             Ash.get(SweepGroupExecution, execution.id, scope: scope)

    assert {:error, %Invalid{}} =
             Ash.get(SweepHostResult, host_result.id, scope: scope)
  end

  for notification <- [
        :refresh_active_scans,
        :sweep_execution_started,
        :sweep_execution_completed,
        :sweep_execution_failed
      ] do
    test "refreshes deletion history on #{notification}", %{conn: conn, scope: scope} do
      unique = System.unique_integer([:positive])

      {:ok, group} =
        SweepGroup
        |> Ash.Changeset.for_create(:create, %{name: "History Group #{unique}", enabled: false})
        |> Ash.create(scope: scope)

      {:ok, lv, _html} = live(conn, ~p"/settings/networks")
      selector = ~s(button[phx-click="delete_group"][phx-value-id="#{group.id}"])
      assert lv |> element(selector) |> render() =~ "no recorded executions"

      {:ok, execution} =
        SweepGroupExecution
        |> Ash.Changeset.for_create(:start, %{
          sweep_group_id: group.id,
          agent_id: "agent-#{unique}"
        })
        |> Ash.create(scope: scope)

      notification = unquote(notification)

      message =
        if notification == :refresh_active_scans do
          notification
        else
          {notification, %{execution_id: execution.id, started_at: execution.started_at}}
        end

      send(lv.pid, message)
      assert lv |> element(selector) |> render() =~ "1 execution and"
    end
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

  test "sweep group routes never load or retain an eager agent fleet", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(:create, %{name: "Bounded agents #{unique}"})
      |> Ash.create(scope: scope)

    for path <- [
          ~p"/settings/networks",
          ~p"/settings/networks/groups/new",
          ~p"/settings/networks/groups/#{group.id}",
          ~p"/settings/networks/groups/#{group.id}/edit"
        ] do
      queries =
        capture_repo_queries(fn ->
          {:ok, view, _html} = live(conn, path)
          assigns = live_assigns(view)

          refute Map.has_key?(assigns, :agents)
          assert Map.get(assigns, :mapper_agents) == []

          if path == ~p"/settings/networks/groups/new" do
            view
            |> form("#sweep-group-form", %{"form" => %{"name" => "Validation #{unique}"}})
            |> render_change()
          end
        end)

      refute Enum.any?(queries, &agent_query?/1),
             "expected #{path} not to read the agent fleet, got: #{inspect(queries)}"
    end
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

  test "agent picker searches, cancels drafts, applies selection, and preserves canonical IDs on validate", %{
    conn: conn
  } do
    gateway = gateway_fixture()
    unique = System.unique_integer([:positive])

    alpha =
      agent_fixture(gateway, %{
        uid: "picker-alpha-#{unique}",
        name: "Picker Alpha #{unique}",
        capabilities: ["sweep"]
      })

    beta =
      agent_fixture(gateway, %{
        uid: "picker-beta-#{unique}",
        name: "Picker Beta #{unique}",
        capabilities: []
      })

    {:ok, view, _html} = live(conn, ~p"/settings/networks/groups/new")

    view |> element("#sweep-agent-picker-trigger") |> render_click()
    assert has_element?(view, "#sweep-agent-picker-dialog")

    view
    |> element("#sweep-agent-picker-search")
    |> render_keyup(%{"value" => "  PICKER ALPHA #{unique}  "})

    assert has_element?(view, "[data-agent-picker-uid='#{alpha.uid}']")
    refute has_element?(view, "[data-agent-picker-uid='#{beta.uid}']")

    view
    |> element("input[phx-click='agent_picker_toggle'][phx-value-uid='#{alpha.uid}']")
    |> render_click()

    view
    |> element("#sweep-agent-picker-dialog button[phx-click='agent_picker_cancel']", "Cancel")
    |> render_click()

    refute has_element?(view, "input[name='form[agent_ids][]'][value='#{alpha.uid}']")

    view |> element("#sweep-agent-picker-trigger") |> render_click()

    view
    |> element("input[phx-click='agent_picker_toggle'][phx-value-uid='#{alpha.uid}']")
    |> render_click()

    view |> element("#sweep-agent-picker-selected-tab") |> render_click()
    assert has_element?(view, "[data-agent-picker-uid='#{alpha.uid}']")
    view |> element("button[phx-click='agent_picker_apply']") |> render_click()

    assert has_element?(view, "input[name='form[agent_ids][]'][value='#{alpha.uid}']")

    render_change(view, "validate_group", %{
      "form" => %{
        "name" => "Canonical draft #{unique}",
        "agent_ids" => [beta.uid],
        "agent_assignment_mode" => "selected"
      }
    })

    assert has_element?(view, "input[name='form[agent_ids][]'][value='#{alpha.uid}']")
    refute has_element?(view, "input[name='form[agent_ids][]'][value='#{beta.uid}']")
  end

  test "agent picker rows expose complete visible and accessible agent metadata", %{conn: conn} do
    partition = partition_fixture()
    gateway = gateway_fixture(%{partition_id: partition.id})
    unique = System.unique_integer([:positive])

    agent =
      agent_fixture(gateway, %{
        uid: "metadata-picker-#{unique}",
        name: "Metadata picker #{unique}",
        capabilities: ["sweep"]
      })

    {:ok, view, _html} = live(conn, ~p"/settings/networks/groups/new")
    view |> element("#sweep-agent-picker-trigger") |> render_click()

    view
    |> element("#sweep-agent-picker-search")
    |> render_keyup(%{"value" => agent.uid})

    assert has_element?(
             view,
             "input[phx-click='agent_picker_toggle'][phx-value-uid='#{agent.uid}']" <>
               "[aria-label='Select #{agent.name}, UID #{agent.uid}, status connecting']"
           )

    browse_row = render(element(view, "[data-agent-picker-uid='#{agent.uid}']"))
    assert browse_row =~ agent.name
    assert browse_row =~ agent.uid
    assert browse_row =~ "Partition #{partition.id}"
    assert browse_row =~ "connecting"
    assert browse_row =~ "sweep"

    view
    |> element("input[phx-click='agent_picker_toggle'][phx-value-uid='#{agent.uid}']")
    |> render_click()

    view |> element("#sweep-agent-picker-selected-tab") |> render_click()
    selected_row = render(element(view, "[data-agent-picker-uid='#{agent.uid}']"))
    assert selected_row =~ agent.name
    assert selected_row =~ agent.uid
    assert selected_row =~ "Partition #{partition.id}"
    assert selected_row =~ "connecting"
    assert selected_row =~ "sweep"
  end

  test "save injects committed IDs, ignores crafted hidden IDs, and rejects selected-empty mode", %{
    conn: conn,
    scope: scope
  } do
    gateway = gateway_fixture()
    unique = System.unique_integer([:positive])
    selected = agent_fixture(gateway, %{uid: "save-selected-#{unique}", name: "Save selected #{unique}"})
    crafted = agent_fixture(gateway, %{uid: "save-crafted-#{unique}", name: "Save crafted #{unique}"})

    {:ok, view, _html} = live(conn, ~p"/settings/networks/groups/new")
    view |> element("#sweep-agent-picker-trigger") |> render_click()

    view
    |> element("input[phx-click='agent_picker_toggle'][phx-value-uid='#{selected.uid}']")
    |> render_click()

    view |> element("button[phx-click='agent_picker_apply']") |> render_click()

    name = "Canonical save #{unique}"

    render_submit(view, "save_group", %{
      "form" => %{
        "name" => name,
        "agent_ids" => [crafted.uid],
        "agent_assignment_mode" => "selected"
      }
    })

    group = SweepGroup |> Ash.read!(scope: scope) |> Enum.find(&(&1.name == name))
    assert group.agent_ids == [selected.uid]

    {:ok, empty_view, _html} = live(conn, ~p"/settings/networks/groups/new")

    html =
      render_submit(empty_view, "save_group", %{
        "form" => %{
          "name" => "Rejected empty #{unique}",
          "agent_assignment_mode" => "selected",
          "agent_ids" => [crafted.uid]
        }
      })

    assert html =~ "Select at least one agent"
    refute Enum.any?(Ash.read!(SweepGroup, scope: scope), &(&1.name == "Rejected empty #{unique}"))

    {:ok, all_view, _html} = live(conn, ~p"/settings/networks/groups/new")
    all_name = "Canonical all #{unique}"

    render_submit(all_view, "save_group", %{
      "form" => %{
        "name" => all_name,
        "agent_assignment_mode" => "all",
        "agent_ids" => [crafted.uid]
      }
    })

    all_group = SweepGroup |> Ash.read!(scope: scope) |> Enum.find(&(&1.name == all_name))
    assert all_group.agent_ids == []
  end

  test "many selected agents validate and save without a feature flag", %{conn: conn, scope: scope} do
    gateway = gateway_fixture()
    unique = System.unique_integer([:positive])

    agents =
      for index <- 1..3 do
        agent_fixture(gateway, %{
          uid: "many-picker-#{unique}-#{index}",
          name: "Many picker #{unique} #{index}"
        })
      end

    {:ok, view, _html} = live(conn, ~p"/settings/networks/groups/new")
    view |> element("#sweep-agent-picker-trigger") |> render_click()

    view
    |> element("#sweep-agent-picker-search")
    |> render_keyup(%{"value" => "many picker #{unique}"})

    for agent <- agents do
      view
      |> element("input[phx-click='agent_picker_toggle'][phx-value-uid='#{agent.uid}']")
      |> render_click()
    end

    view |> element("button[phx-click='agent_picker_apply']") |> render_click()

    name = "Many selected #{unique}"

    view
    |> form("#sweep-group-form", %{"form" => %{"name" => name}})
    |> render_change()

    view
    |> form("#sweep-group-form", %{"form" => %{"name" => name}})
    |> render_submit()

    group = SweepGroup |> Ash.read!(scope: scope) |> Enum.find(&(&1.name == name))
    assert Enum.sort(group.agent_ids) == Enum.sort(Enum.map(agents, & &1.uid))
  end

  test "closed summary resolves one UID once but keeps multiple UIDs count-only", %{conn: conn} do
    gateway = gateway_fixture()
    unique = System.unique_integer([:positive])
    first = agent_fixture(gateway, %{uid: "summary-one-#{unique}", name: "Summary One #{unique}"})
    second = agent_fixture(gateway, %{uid: "summary-two-#{unique}", name: "Summary Two #{unique}"})

    singleton_id = insert_sweep_group!("Singleton summary #{unique}", [first.uid])
    multiple_id = insert_sweep_group!("Multiple summary #{unique}", [first.uid, second.uid])

    singleton_queries =
      capture_repo_queries(fn ->
        {:ok, view, _html} = live(conn, ~p"/settings/networks/groups/#{singleton_id}/edit")
        assert has_element?(view, "#sweep-agent-assignment-summary", first.name)
      end)

    assert Enum.count(singleton_queries, &agent_query?/1) == 1

    multiple_queries =
      capture_repo_queries(fn ->
        {:ok, view, _html} = live(conn, ~p"/settings/networks/groups/#{multiple_id}/edit")
        assert has_element?(view, "#sweep-agent-assignment-summary", "2 selected agents")
      end)

    refute Enum.any?(multiple_queries, &agent_query?/1)
  end

  test "list and detail summaries resolve singleton names and mark stale UIDs unavailable", %{
    conn: conn
  } do
    gateway = gateway_fixture()
    unique = System.unique_integer([:positive])
    first = agent_fixture(gateway, %{uid: "list-summary-one-#{unique}", name: "List summary one #{unique}"})
    second = agent_fixture(gateway, %{uid: "list-summary-two-#{unique}", name: "List summary two #{unique}"})
    stale_uid = "list-summary-stale-#{unique}"

    first_id = insert_sweep_group!("List singleton one #{unique}", [first.uid])
    second_id = insert_sweep_group!("List singleton two #{unique}", [second.uid])
    stale_id = insert_sweep_group!("List stale #{unique}", [stale_uid])
    all_id = insert_sweep_group!("List all #{unique}", [])
    multiple_id = insert_sweep_group!("List multiple #{unique}", [first.uid, second.uid])

    list_queries =
      capture_repo_queries(fn ->
        {:ok, list_view, _html} = live(conn, ~p"/settings/networks")

        assert has_element?(
                 list_view,
                 "[data-sweep-group-assignment='#{first_id}']",
                 first.name
               )

        assert has_element?(
                 list_view,
                 "[data-sweep-group-assignment='#{second_id}']",
                 second.name
               )

        stale_summary =
          render(element(list_view, "[data-sweep-group-assignment='#{stale_id}']"))

        assert stale_summary =~ stale_uid
        assert stale_summary =~ "Unavailable"
        assert has_element?(list_view, "[data-sweep-group-assignment='#{all_id}']", "All agents")
        assert has_element?(list_view, "[data-sweep-group-assignment='#{multiple_id}']", "2 selected")
      end)

    assert Enum.count(list_queries, &agent_query?/1) == 1

    {:ok, known_detail, _html} = live(conn, ~p"/settings/networks/groups/#{first_id}")
    assert has_element?(known_detail, "#sweep-group-assignment-summary", first.name)

    {:ok, stale_detail, _html} = live(conn, ~p"/settings/networks/groups/#{stale_id}")
    stale_detail_summary = render(element(stale_detail, "#sweep-group-assignment-summary"))
    assert stale_detail_summary =~ stale_uid
    assert stale_detail_summary =~ "Unavailable"
  end

  test "selected view renders a stale UID as unavailable and allows removing it", %{conn: conn} do
    gateway = gateway_fixture()
    unique = System.unique_integer([:positive])
    stale = agent_fixture(gateway, %{uid: "stale-picker-#{unique}", name: "Stale picker #{unique}"})

    group_id = insert_sweep_group!("Stale group #{unique}", [stale.uid])

    SQL.query!(
      ServiceRadar.Repo,
      "DELETE FROM platform.ocsf_agents WHERE uid = $1",
      [stale.uid]
    )

    {:ok, view, _html} = live(conn, ~p"/settings/networks/groups/#{group_id}/edit")
    view |> element("#sweep-agent-picker-trigger") |> render_click()
    view |> element("#sweep-agent-picker-selected-tab") |> render_click()

    assert has_element?(
             view,
             "[data-agent-picker-uid='#{stale.uid}'][data-agent-unavailable='true']"
           )

    view
    |> element("button[phx-click='agent_picker_remove'][phx-value-uid='#{stale.uid}']")
    |> render_click()

    refute has_element?(view, "[data-agent-picker-uid='#{stale.uid}']")
  end

  test "browse page renders at most fifty agents and truthful boundary pagination", %{conn: conn} do
    gateway = gateway_fixture()
    unique = System.unique_integer([:positive])

    for index <- 1..51 do
      agent_fixture(gateway, %{
        uid: "bounded-picker-#{unique}-#{String.pad_leading(Integer.to_string(index), 2, "0")}",
        name: "Bounded picker #{unique} #{String.pad_leading(Integer.to_string(index), 2, "0")}"
      })
    end

    {:ok, view, _html} = live(conn, ~p"/settings/networks/groups/new")
    view |> element("#sweep-agent-picker-trigger") |> render_click()

    view
    |> element("#sweep-agent-picker-search")
    |> render_keyup(%{"value" => "bounded picker #{unique}"})

    document = view |> render() |> LazyHTML.from_fragment()
    assert document |> LazyHTML.query("[data-agent-picker-row]") |> LazyHTML.to_tree() |> length() == 50
    assert has_element?(view, "button[aria-label='Previous agents page'][disabled]")
    assert has_element?(view, "button[aria-label='Next agents page']:not([disabled])")

    view |> element("button[aria-label='Next agents page']") |> render_click()
    document = view |> render() |> LazyHTML.from_fragment()
    assert document |> LazyHTML.query("[data-agent-picker-row]") |> LazyHTML.to_tree() |> length() == 1
    assert has_element?(view, "button[aria-label='Next agents page'][disabled]")
    assert has_element?(view, "button[aria-label='Previous agents page']:not([disabled])")
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

    assigns = live_assigns(lv)
    refute Map.has_key?(assigns, :agents)
    assert Enum.any?(assigns.mapper_agents, &(&1.uid == agent.uid))
  end

  test "discovery list and mapper forms lazily load bounded mapper agent options", %{
    conn: conn,
    scope: scope
  } do
    gateway = gateway_fixture()
    unique = System.unique_integer([:positive])

    mapper =
      agent_fixture(gateway, %{
        uid: "lazy-mapper-#{unique}",
        name: "Lazy mapper #{unique}",
        capabilities: ["mapper"]
      })

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(:create, %{
        name: "Lazy mapper job #{unique}",
        agent_id: mapper.uid
      })
      |> Ash.create(scope: scope)

    for path <- [
          ~p"/settings/networks/discovery",
          ~p"/settings/networks/discovery/new",
          ~p"/settings/networks/discovery/#{job.id}/edit"
        ] do
      {:ok, view, _html} = live(conn, path)
      assigns = live_assigns(view)

      refute Map.has_key?(assigns, :agents)
      assert length(assigns.mapper_agents) <= 51
      assert Enum.any?(assigns.mapper_agents, &(&1.uid == mapper.uid))
    end
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
    SQL.query!(
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

  defp live_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp insert_sweep_group!(name, agent_ids) do
    %{rows: [[id]]} =
      SQL.query!(
        ServiceRadar.Repo,
        "INSERT INTO platform.sweep_groups (name, agent_ids) VALUES ($1, $2::text[]) RETURNING id::text",
        [name, agent_ids]
      )

    id
  end

  defp capture_repo_queries(fun) do
    handler_id = {__MODULE__, :repo_query, System.unique_integer([:positive])}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:service_radar, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:networks_repo_query, metadata.query})
      end,
      nil
    )

    try do
      fun.()
      drain_repo_queries([])
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_queries(queries) do
    receive do
      {:networks_repo_query, query} -> drain_repo_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp agent_query?(query) do
    String.contains?(query, ~s(FROM "platform"."ocsf_agents"))
  end
end
