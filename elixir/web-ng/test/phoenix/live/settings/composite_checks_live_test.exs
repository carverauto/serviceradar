defmodule ServiceRadarWebNGWeb.Settings.CompositeChecksLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadarWebNG.AccountsFixtures

  require Ash.Query

  setup :register_and_log_in_admin_user

  @path "/settings/networks/composite-checks"

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})

    %{conn: log_in_user(conn, user), user: user}
  end

  defp create_check(attrs) do
    defaults = %{
      name: "Live Check #{System.unique_integer([:positive])}",
      scope_query: "in:devices"
    }

    CompositeCheck
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs), actor: system_actor())
    |> Ash.create!()
  end

  defp read_checks_named(name) do
    CompositeCheck
    |> Ash.Query.filter(name == ^name)
    |> Ash.read(actor: system_actor())
  end

  defp check_named!(name) do
    {:ok, [check]} = read_checks_named(name)
    check
  end

  describe "access" do
    test "renders for an admin", %{conn: conn} do
      {:ok, _live, html} = live(conn, @path)
      assert html =~ "Composite Checks"
    end

    test "renders for a viewer, who holds composite_checks.view", %{conn: conn} do
      viewer = AccountsFixtures.user_fixture(%{role: :viewer})

      {:ok, _live, html} = live(log_in_user(conn, viewer), @path)

      assert html =~ "Composite Checks"
    end
  end

  describe "index" do
    test "explains the liveness witness requirement when empty", %{conn: conn} do
      {:ok, _live, html} = live(conn, @path)

      # The empty state is the only place a first-time operator learns why one
      # vantage point is never enough.
      assert html =~ "powered-off device"
    end

    test "lists an existing check with its scope and state", %{conn: conn} do
      check = create_check(%{scope_query: "in:devices source:armis"})

      {:ok, _live, html} = live(conn, @path)

      assert html =~ check.name
      assert html =~ "in:devices source:armis"
      assert html =~ "draft"
      assert html =~ ~s(phx-click="delete_check")
      refute html =~ ~s(phx-click="disable")
    end

    test "a viewer cannot disable or remove checks", %{conn: conn} do
      create_check(%{scope_query: "in:devices source:armis"})
      viewer = AccountsFixtures.user_fixture(%{role: :viewer})

      {:ok, _live, html} = live(log_in_user(conn, viewer), @path)

      refute html =~ ~s(phx-click="delete_check")
      refute html =~ ~s(phx-click="disable")
      refute html =~ "New check"
    end

    test "removing a check from the list deletes it", %{conn: conn} do
      check = create_check(%{name: "Disposable Check #{System.unique_integer([:positive])}"})

      {:ok, live, _html} = live(conn, @path)

      live
      |> element(~s(button[phx-click="delete_check"][phx-value-id="#{check.id}"]))
      |> render_click()

      assert {:ok, []} = read_checks_named(check.name)
    end

    test "a draft check says it has not been evaluated rather than showing a zero rollup", %{
      conn: conn
    } do
      create_check(%{})

      {:ok, _live, html} = live(conn, @path)

      # A rollup of zeros reads like a computed answer. "Not yet evaluated" is
      # the honest statement for a check that has never run.
      assert html =~ "Not yet evaluated"
    end

    test "renders verdict counts for a check with results", %{conn: conn} do
      check = create_check(%{})
      now = DateTime.utc_now()

      for {uid, verdict, status} <- [
            {"idx-a", "isolated_verified", :healthy},
            {"idx-b", "isolated_verified", :healthy},
            {"idx-c", "not_isolated", :down}
          ] do
        DeviceCompositeCheckResult
        |> Ash.Changeset.for_create(
          :upsert,
          %{
            device_uid: uid,
            check_id: check.id,
            verdict: verdict,
            status: status,
            inputs: %{},
            evaluated_at: now,
            changed_at: now
          },
          actor: system_actor(),
          upsert?: true,
          upsert_identity: :unique_device_check
        )
        |> Ash.create!()
      end

      {:ok, _live, html} = live(conn, @path)

      assert html =~ "isolated_verified"
      assert html =~ "not_isolated"
      refute html =~ "Not yet evaluated"
    end

    test "offers the new-check action to an operator", %{conn: conn} do
      {:ok, _live, html} = live(conn, @path)
      assert html =~ "New check"
    end
  end

  describe "manage-gated actions" do
    # Scope must come from the logged-in user: a LiveView resolves it through
    # the session on mount, so assigning :current_scope on the conn has no
    # effect on what the LiveView sees.
    test "a viewer is not offered the new-check action", %{conn: conn} do
      viewer = AccountsFixtures.user_fixture(%{role: :viewer})

      {:ok, _live, html} = live(log_in_user(conn, viewer), @path)

      refute html =~ "New check"
    end

    test "a viewer is redirected away from the new-check route", %{conn: conn} do
      viewer = AccountsFixtures.user_fixture(%{role: :viewer})

      # A push_patch issued during the initial mount surfaces to the test client
      # as a live_redirect rather than a patch.
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(log_in_user(conn, viewer), @path <> "/new")

      assert to == @path
      assert flash["error"] =~ "do not have permission"
    end

    test "an admin can reach the new-check route", %{conn: conn} do
      {:ok, _live, html} = live(conn, @path <> "/new")

      assert html =~ "Composite Check"
    end
  end

  describe "the scope panel" do
    test "editing the raw SRQL updates the visual filter rows", %{conn: conn} do
      {:ok, live, _html} = live(conn, @path <> "/new")

      html =
        live
        |> form("#composite-check-form", %{"form" => %{"scope_query" => "source:armis tag:managed"}})
        |> render_change()

      assert html =~ "value=\"source\""
      assert html =~ "value=\"armis\""
      assert html =~ "value=\"tag\""
      assert html =~ "value=\"managed\""
    end

    test "an unparseable query warns and leaves the raw string authoritative", %{conn: conn} do
      {:ok, live, _html} = live(conn, @path <> "/new")

      html =
        live
        |> form("#composite-check-form", %{"form" => %{"scope_query" => ~s|in:devices stats:"count() as total"|}})
        |> render_change()

      assert html =~ "cannot represent"
      assert html =~ "SRQL above is what will be saved"
    end

    test "adding a filter row keeps the raw query in step", %{conn: conn} do
      {:ok, live, _html} = live(conn, @path <> "/new")

      html = live |> element("button", "Add filter") |> render_click()

      assert html =~ "Filter field"
    end

    test "saving a new check stays on the builder at the new check's route", %{conn: conn} do
      {:ok, live, _html} = live(conn, @path <> "/new")

      html =
        live
        |> form("#composite-check-form", %{
          "form" => %{
            "name" => "Scoped Check",
            "scope_query" => "in:devices source:armis",
            "evaluation_interval_seconds" => "300"
          }
        })
        |> render_submit()

      check = check_named!("Scoped Check")

      # The URL follows the check that was just written, so a refresh reopens
      # the saved check rather than a blank form.
      assert_patch(live, @path <> "/#{check.id}/edit")

      assert html =~ "in:devices source:armis"
      assert check.scope_query == "in:devices source:armis"
    end

    test "the index lists a saved check", %{conn: conn} do
      create_check(%{name: "Listed Check", scope_query: "in:devices source:armis"})

      {:ok, _live, html} = live(conn, @path)

      assert html =~ "Listed Check"
      assert html =~ "in:devices source:armis"
    end

    test "a scope that does not target devices is rejected by the resource", %{conn: conn} do
      {:ok, live, _html} = live(conn, @path <> "/new")

      html =
        live
        |> form("#composite-check-form", %{
          "form" => %{
            "name" => "Bad Scope",
            "scope_query" => "in:flows src_ip:10.0.0.1",
            "evaluation_interval_seconds" => "300"
          }
        })
        |> render_submit()

      # Surfaced from Ash rather than re-implemented in the form.
      assert html =~ "must target devices"
    end

    test "a blank name is caught before hitting the resource", %{conn: conn} do
      {:ok, live, _html} = live(conn, @path <> "/new")

      html =
        live
        |> form("#composite-check-form", %{"form" => %{"name" => "", "scope_query" => "in:devices"}})
        |> render_submit()

      assert html =~ "Name is required"
    end

    test "an out-of-range interval is caught locally", %{conn: conn} do
      {:ok, live, _html} = live(conn, @path <> "/new")

      html =
        live
        |> form("#composite-check-form", %{
          "form" => %{
            "name" => "Fast Check",
            "scope_query" => "in:devices",
            "evaluation_interval_seconds" => "5"
          }
        })
        |> render_submit()

      assert html =~ "at least 60 seconds"
    end

    test "editing an existing check loads its scope", %{conn: conn} do
      check = create_check(%{scope_query: "in:devices tag:managed"})

      {:ok, _live, html} = live(conn, @path <> "/#{check.id}/edit")

      assert html =~ "in:devices tag:managed"
      assert html =~ check.name
    end

    test "renaming a check keeps its slug", %{conn: conn} do
      check = create_check(%{})
      original_slug = check.slug

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")

      live
      |> form("#composite-check-form", %{
        "form" => %{
          "name" => "Renamed Check",
          "scope_query" => check.scope_query,
          "evaluation_interval_seconds" => "300"
        }
      })
      |> render_submit()

      {:ok, reloaded} = CompositeCheck.get_by_id(check.id, actor: system_actor())

      assert reloaded.name == "Renamed Check"
      # The slug is the SRQL handle; saved queries referencing it must keep
      # resolving after a rename.
      assert reloaded.slug == original_slug
    end
  end

  describe "vantage points" do
    setup do
      %{gateway: gateway_fixture()}
    end

    defp add_rows(live, count) do
      Enum.each(1..count//1, fn _index ->
        live |> element("button", "Add vantage point") |> render_click()
      end)

      live
    end

    defp indexed(rows) do
      rows |> Enum.with_index() |> Map.new(fn {row, index} -> {to_string(index), row} end)
    end

    defp submit_check(live, name, rows) do
      live
      |> form("#composite-check-form", %{
        "form" => %{
          "name" => name,
          "scope_query" => "in:devices",
          "evaluation_interval_seconds" => "300"
        },
        "vantage_points" => indexed(rows)
      })
      |> render_submit()
    end

    test "adding a vantage point renders an agent picker", %{conn: conn, gateway: gateway} do
      agent = agent_fixture(gateway)

      {:ok, live, html} = live(conn, @path <> "/new")
      refute html =~ ~s(name="vantage_points[0][agent_id]")

      html = live |> element("button", "Add vantage point") |> render_click()

      assert html =~ ~s(name="vantage_points[0][agent_id]")
      assert html =~ agent.uid
    end

    test "an expected-available vantage point is the liveness witness", %{
      conn: conn,
      gateway: gateway
    } do
      agent = agent_fixture(gateway)

      {:ok, live, _html} = live(conn, @path <> "/new")

      html =
        live
        |> add_rows(1)
        |> form("#composite-check-form", %{
          "vantage_points" => indexed([%{"agent_id" => agent.uid, "expected" => "available"}])
        })
        |> render_change()

      assert html =~ "liveness witness"
      refute html =~ "isolation probe"
    end

    test "an expected-blocked vantage point is an isolation probe", %{
      conn: conn,
      gateway: gateway
    } do
      agent = agent_fixture(gateway)

      {:ok, live, _html} = live(conn, @path <> "/new")

      html =
        live
        |> add_rows(1)
        |> form("#composite-check-form", %{
          "vantage_points" => indexed([%{"agent_id" => agent.uid, "expected" => "blocked"}])
        })
        |> render_change()

      assert html =~ "isolation probe"
      refute html =~ "liveness witness"
    end

    test "a new row defaults to blocked so a second point never invents a witness", %{
      conn: conn,
      gateway: gateway
    } do
      agent_fixture(gateway)

      {:ok, live, _html} = live(conn, @path <> "/new")

      html = live |> add_rows(2) |> render()

      # Both rows blocked by default: the operator, not the form, decides which
      # agent is the witness.
      assert html =~ "powered-off device is indistinguishable"
    end

    test "a single blocked row does not yet warn about the witness", %{
      conn: conn,
      gateway: gateway
    } do
      agent_fixture(gateway)

      {:ok, live, _html} = live(conn, @path <> "/new")

      html = live |> add_rows(1) |> render()

      # One row is a half-built check, not a broken one. The gate is at enable.
      refute html =~ "powered-off device is indistinguishable"
    end

    test "removing the witness surfaces the readiness warning", %{conn: conn, gateway: gateway} do
      witness = agent_fixture(gateway)
      probe = agent_fixture(gateway)
      other_probe = agent_fixture(gateway)

      {:ok, live, _html} = live(conn, @path <> "/new")

      html =
        live
        |> add_rows(3)
        |> form("#composite-check-form", %{
          "vantage_points" =>
            indexed([
              %{"agent_id" => witness.uid, "expected" => "available"},
              %{"agent_id" => probe.uid, "expected" => "blocked"},
              %{"agent_id" => other_probe.uid, "expected" => "blocked"}
            ])
        })
        |> render_change()

      refute html =~ "powered-off device is indistinguishable"

      html =
        live
        |> element(~s(button[phx-click="remove_vantage_point"][phx-value-index="0"]))
        |> render_click()

      assert html =~ "powered-off device is indistinguishable"
    end

    test "saving persists the rows as vantage point inputs", %{conn: conn, gateway: gateway} do
      witness = agent_fixture(gateway)
      probe = agent_fixture(gateway)

      {:ok, live, _html} = live(conn, @path <> "/new")

      live
      |> add_rows(2)
      |> submit_check("Witness Check", [
        %{"agent_id" => witness.uid, "expected" => "available"},
        %{"agent_id" => probe.uid, "expected" => "blocked"}
      ])

      check = check_named!("Witness Check")

      {:ok, inputs} = CompositeCheckInput.list_by_check(check.id, actor: system_actor())

      assert [first, second] = Enum.sort_by(inputs, & &1.position)
      assert Enum.all?(inputs, &(&1.kind == :vantage_point))

      # The key is the agent id: that is what makes `unique_key_per_check`
      # enforce one vantage point per agent, and what rule match maps address.
      assert first.key == witness.uid
      assert first.expected == "available"
      assert first.config["agent_id"] == witness.uid
      assert second.key == probe.uid
      assert second.expected == "blocked"
    end

    test "editing replaces the saved rows rather than accumulating them", %{
      conn: conn,
      gateway: gateway
    } do
      original = agent_fixture(gateway)
      replacement = agent_fixture(gateway)

      {:ok, live, _html} = live(conn, @path <> "/new")

      live
      |> add_rows(1)
      |> submit_check("Replaced Check", [
        %{"agent_id" => original.uid, "expected" => "available"}
      ])

      check = check_named!("Replaced Check")

      {:ok, live, html} = live(conn, @path <> "/#{check.id}/edit")
      assert html =~ original.uid
      assert html =~ "liveness witness"

      submit_check(live, "Replaced Check", [%{"agent_id" => replacement.uid, "expected" => "available"}])
      {:ok, inputs} = CompositeCheckInput.list_by_check(check.id, actor: system_actor())

      assert [only] = Enum.filter(inputs, &(&1.kind == :vantage_point))
      assert only.key == replacement.uid
    end

    test "a row with no agent is rejected before it reaches the resource", %{conn: conn} do
      {:ok, live, _html} = live(conn, @path <> "/new")

      html = live |> add_rows(1) |> submit_check("No Agent", [%{"agent_id" => ""}])

      assert html =~ "needs an agent"
      assert {:ok, []} = read_checks_named("No Agent")
    end

    test "the same agent cannot be a vantage point twice", %{conn: conn, gateway: gateway} do
      agent = agent_fixture(gateway)

      {:ok, live, _html} = live(conn, @path <> "/new")

      html =
        live
        |> add_rows(2)
        |> submit_check("Duplicate", [
          %{"agent_id" => agent.uid, "expected" => "available"},
          %{"agent_id" => agent.uid, "expected" => "blocked"}
        ])

      # Caught locally so the operator sees which row is wrong, rather than a
      # unique-constraint error after the check has already been created.
      assert html =~ "only be a vantage point once"
      assert {:ok, []} = read_checks_named("Duplicate")
    end

    test "removing a row keeps the remaining rows in their original order", %{
      conn: conn,
      gateway: gateway
    } do
      first = agent_fixture(gateway)
      second = agent_fixture(gateway)
      third = agent_fixture(gateway)

      {:ok, live, _html} = live(conn, @path <> "/new")

      live
      |> add_rows(3)
      |> form("#composite-check-form", %{
        "vantage_points" =>
          indexed([
            %{"agent_id" => first.uid, "expected" => "available"},
            %{"agent_id" => second.uid, "expected" => "blocked"},
            %{"agent_id" => third.uid, "expected" => "blocked"}
          ])
      })
      |> render_change()

      html =
        live
        |> element(~s(button[phx-click="remove_vantage_point"][phx-value-index="1"]))
        |> render_click()

      # Indexed params sort numerically, so removing the middle row must leave
      # the first and third rows intact rather than renumbering them apart.
      assert html =~ ~s(value="#{first.uid}" selected)
      assert html =~ ~s(value="#{third.uid}" selected)
      refute html =~ ~s(value="#{second.uid}" selected)
    end
  end

  describe "verdict rule table" do
    setup do
      %{gateway: gateway_fixture()}
    end

    defp saved_check_with_vantage_points(conn, gateway, name) do
      witness = agent_fixture(gateway)
      probe = agent_fixture(gateway)

      {:ok, live, _html} = live(conn, @path <> "/new")

      live
      |> add_rows(2)
      |> submit_check(name, [
        %{"agent_id" => witness.uid, "expected" => "available"},
        %{"agent_id" => probe.uid, "expected" => "blocked"}
      ])

      {check_named!(name), witness, probe}
    end

    defp rules_for(check) do
      {:ok, rules} = CompositeCheckRule.list_by_check(check.id, actor: system_actor())
      rules
    end

    defp authored_rules(check), do: check |> rules_for() |> Enum.reject(& &1.catch_all)

    defp rule_form(live, rule), do: form(live, "#rule-form-#{rule.id}")

    test "a new check explains that the table needs a saved vantage point", %{conn: conn} do
      {:ok, _live, html} = live(conn, @path <> "/new")

      # Rules match on input keys, which do not exist until the vantage points
      # are persisted, so there is nothing honest to render yet.
      assert html =~ "Save the check to build its decision table"
      refute html =~ "Generate from expectations"
    end

    test "a saved check with no rules offers generation", %{conn: conn, gateway: gateway} do
      {check, _witness, _probe} = saved_check_with_vantage_points(conn, gateway, "Generatable")

      {:ok, _live, html} = live(conn, @path <> "/#{check.id}/edit")

      assert html =~ "Generate from expectations"
      assert authored_rules(check) == []
    end

    test "generating produces the isolation rows keyed by agent", %{conn: conn, gateway: gateway} do
      {check, witness, probe} = saved_check_with_vantage_points(conn, gateway, "Generated")

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")

      html = live |> element("button", "Generate from expectations") |> render_click()

      verdicts = check |> authored_rules() |> Enum.map(& &1.verdict)

      assert verdicts == [
               "isolated_verified",
               "not_isolated",
               "device_unreachable",
               "inverted_reachability"
             ]

      assert html =~ "isolated_verified"

      # The match is keyed by agent id, which is what the vantage point inputs
      # are keyed by, so the generated table is addressable from the UI.
      [first | _rest] = authored_rules(check)
      assert first.match == %{witness.uid => "available", probe.uid => "blocked"}
    end

    test "the catch-all is never duplicated by generation", %{conn: conn, gateway: gateway} do
      {check, _witness, _probe} = saved_check_with_vantage_points(conn, gateway, "One Catch All")

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      live |> element("button", "Generate from expectations") |> render_click()
      live |> element("button", "Generate from expectations") |> render_click()
      live |> element("button", "Replace the table") |> render_click()

      assert check |> rules_for() |> Enum.count(& &1.catch_all) == 1
    end

    test "editing a verdict label persists", %{conn: conn, gateway: gateway} do
      {check, _witness, _probe} = saved_check_with_vantage_points(conn, gateway, "Relabelled")

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      live |> element("button", "Generate from expectations") |> render_click()

      [rule | _rest] = authored_rules(check)

      live
      |> rule_form(rule)
      |> render_change(%{"verdict_label" => "Proven isolated", "status" => "healthy"})

      assert %{verdict_label: "Proven isolated"} =
               check |> authored_rules() |> Enum.find(&(&1.id == rule.id))
    end

    test "editing a status persists and is what rollups key on", %{conn: conn, gateway: gateway} do
      {check, _witness, _probe} = saved_check_with_vantage_points(conn, gateway, "Restatused")

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      live |> element("button", "Generate from expectations") |> render_click()

      rule = check |> authored_rules() |> Enum.find(&(&1.verdict == "device_unreachable"))
      assert rule.status == :degraded

      live |> rule_form(rule) |> render_change(%{"status" => "down"})

      assert %{status: :down} = check |> authored_rules() |> Enum.find(&(&1.id == rule.id))
    end

    test "editing a match cell persists", %{conn: conn, gateway: gateway} do
      {check, witness, probe} = saved_check_with_vantage_points(conn, gateway, "Rematched")

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      live |> element("button", "Generate from expectations") |> render_click()

      [rule | _rest] = authored_rules(check)

      live
      |> rule_form(rule)
      |> render_change(%{"match" => %{witness.uid => "available", probe.uid => "any"}})

      # "any" is stored as an absent key, the same shape the generator writes,
      # so there is one representation of "unconstrained".
      updated = check |> authored_rules() |> Enum.find(&(&1.id == rule.id))

      assert updated.match == %{witness.uid => "available"}
    end

    test "a rule that constrains nothing is refused by the database", %{
      conn: conn,
      gateway: gateway
    } do
      {check, witness, probe} = saved_check_with_vantage_points(conn, gateway, "Unconstrained")

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      live |> element("button", "Generate from expectations") |> render_click()

      [rule | _rest] = authored_rules(check)

      html =
        live
        |> rule_form(rule)
        |> render_change(%{"match" => %{witness.uid => "any", probe.uid => "any"}})

      assert html =~ "must constrain at least one input"

      updated = check |> authored_rules() |> Enum.find(&(&1.id == rule.id))
      assert updated.match != %{}
    end

    test "the catch-all renders without delete or reorder controls", %{
      conn: conn,
      gateway: gateway
    } do
      {check, _witness, _probe} = saved_check_with_vantage_points(conn, gateway, "Protected")

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      live |> element("button", "Generate from expectations") |> render_click()

      catch_all = check |> rules_for() |> Enum.find(& &1.catch_all)
      html = render(live)

      assert html =~ "rule-form-#{catch_all.id}"
      refute html =~ ~s(phx-value-id="#{catch_all.id}")
      assert html =~ "fallback"
    end

    test "the catch-all is still relabellable", %{conn: conn, gateway: gateway} do
      {check, _witness, _probe} = saved_check_with_vantage_points(conn, gateway, "Relabel Fallback")

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")

      catch_all = check |> rules_for() |> Enum.find(& &1.catch_all)

      live |> rule_form(catch_all) |> render_change(%{"verdict_label" => "Needs review"})

      # Routed through :relabel, not :update — the resource forbids updating the
      # catch-all at all, so the UI must pick the action from the rule.
      assert %{verdict_label: "Needs review"} =
               check |> rules_for() |> Enum.find(&(&1.id == catch_all.id))
    end

    test "regenerating over an edited table asks first", %{conn: conn, gateway: gateway} do
      {check, _witness, _probe} = saved_check_with_vantage_points(conn, gateway, "Confirm First")

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      live |> element("button", "Generate from expectations") |> render_click()

      [rule | _rest] = authored_rules(check)
      live |> rule_form(rule) |> render_change(%{"verdict_label" => "Hand written"})

      html = live |> element("button", "Generate from expectations") |> render_click()
      assert html =~ "Any edits to verdicts"

      # Declining leaves the edit in place.
      live |> element("button", "Keep my edits") |> render_click()

      assert %{verdict_label: "Hand written"} =
               check |> authored_rules() |> Enum.find(&(&1.id == rule.id))
    end

    test "confirming regeneration discards the edits", %{conn: conn, gateway: gateway} do
      {check, _witness, _probe} = saved_check_with_vantage_points(conn, gateway, "Discarded")

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      live |> element("button", "Generate from expectations") |> render_click()

      [rule | _rest] = authored_rules(check)
      live |> rule_form(rule) |> render_change(%{"verdict_label" => "Hand written"})

      live |> element("button", "Generate from expectations") |> render_click()
      live |> element("button", "Replace the table") |> render_click()

      labels = check |> authored_rules() |> Enum.map(& &1.verdict_label)
      refute "Hand written" in labels
      assert length(labels) == 4
    end

    test "moving a rule down reorders evaluation", %{conn: conn, gateway: gateway} do
      {check, _witness, _probe} = saved_check_with_vantage_points(conn, gateway, "Reordered")

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      live |> element("button", "Generate from expectations") |> render_click()

      [first, second | _rest] = authored_rules(check)

      live
      |> element(~s(button[phx-click="move_rule"][phx-value-id="#{first.id}"][phx-value-direction="down"]))
      |> render_click()

      # Order is what the evaluator reads; first match wins.
      assert check |> authored_rules() |> Enum.map(& &1.id) |> Enum.take(2) ==
               [second.id, first.id]
    end

    test "deleting a rule removes it from the table", %{conn: conn, gateway: gateway} do
      {check, _witness, _probe} = saved_check_with_vantage_points(conn, gateway, "Deleted")

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      live |> element("button", "Generate from expectations") |> render_click()

      [first | _rest] = authored_rules(check)

      live
      |> element(~s(button[phx-click="delete_rule"][phx-value-id="#{first.id}"]))
      |> render_click()

      refute first.id in (check |> authored_rules() |> Enum.map(& &1.id))
      assert check |> rules_for() |> Enum.count(& &1.catch_all) == 1
    end
  end

  describe "live preview" do
    setup do
      %{gateway: gateway_fixture(), tag: "pv#{System.unique_integer([:positive])}"}
    end

    defp availability(device_uid, agent_id, is_available, checked_at) do
      ServiceRadar.Inventory.DeviceAgentAvailability
      |> Ash.Changeset.for_create(
        :create,
        %{
          device_uid: device_uid,
          agent_id: agent_id,
          is_available: is_available,
          checked_at: checked_at
        },
        actor: system_actor()
      )
      |> Ash.create!()
    end

    # A check whose scope is exactly the devices this test created, with its
    # rule table generated from the two vantage points.
    defp previewable_check(conn, gateway, tag) do
      witness = agent_fixture(gateway)
      probe = agent_fixture(gateway)

      {:ok, live, _html} = live(conn, @path <> "/new")

      live
      |> add_rows(2)
      |> form("#composite-check-form", %{
        "form" => %{
          "name" => "Preview #{tag}",
          "scope_query" => "in:devices hostname:#{tag}%",
          "evaluation_interval_seconds" => "300"
        },
        "vantage_points" =>
          indexed([
            %{"agent_id" => witness.uid, "expected" => "available"},
            %{"agent_id" => probe.uid, "expected" => "blocked"}
          ])
      })
      |> render_submit()

      check = check_named!("Preview #{tag}")

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      live |> element("button", "Generate from expectations") |> render_click()

      {check, witness, probe}
    end

    test "a new check says the preview needs a saved check", %{conn: conn} do
      {:ok, _live, html} = live(conn, @path <> "/new")

      assert html =~ "Save the check to preview it"
      refute html =~ "Run preview"
    end

    test "an operator is offered the preview on a saved check", %{conn: conn, gateway: gateway} do
      {check, _witness, _probe} = saved_check_with_vantage_points(conn, gateway, "Previewable")

      {:ok, _live, html} = live(conn, @path <> "/#{check.id}/edit")

      assert html =~ "Run preview"
    end

    test "the preview resolves each vantage point with its value and age", %{
      conn: conn,
      gateway: gateway,
      tag: tag
    } do
      {check, witness, probe} = previewable_check(conn, gateway, tag)

      device = device_fixture(%{hostname: "#{tag}-isolated.local"})
      now = DateTime.utc_now()
      availability(device.uid, witness.uid, true, now)
      availability(device.uid, probe.uid, false, now)

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      html = live |> element("button", "Run preview") |> render_click()

      # Asserted on the preview row's own attributes rather than on visible
      # text: every verdict and expectation this panel renders also appears in
      # the rule table and the vantage point selects above it, so a text match
      # would pass with the preview panel entirely empty.
      assert html =~ ~s(data-preview-device="#{device.uid}")
      assert html =~ ~s(data-preview-verdict="isolated_verified")
      assert html =~ ~s(data-preview-input="#{witness.uid}" data-preview-value="available")
      assert html =~ ~s(data-preview-input="#{probe.uid}" data-preview-value="blocked")
      assert html =~ ~r/data-preview-age="\d+s ago"/

      # The explanation is the matched rule's description, not a UI string.
      assert html =~ "Isolation observed from every vantage point"
    end

    test "a preview row carries the device's address and opens it in a new tab", %{
      conn: conn,
      gateway: gateway,
      tag: tag
    } do
      {check, witness, probe} = previewable_check(conn, gateway, tag)

      device = device_fixture(%{hostname: "#{tag}-addressed.local", ip: "192.168.1.171"})
      now = DateTime.utc_now()
      availability(device.uid, witness.uid, true, now)
      availability(device.uid, probe.uid, false, now)

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      html = live |> element("button", "Run preview") |> render_click()

      # A uid identifies a device; an address is how an operator recognises one.
      # The address is not on the evaluation row, so this asserts the separate
      # lookup ran -- and it is a real read against the Device resource, whose
      # :read action requires pagination, so a wrong call shape fails here
      # rather than silently rendering every row without an address.
      assert html =~ ~s(data-preview-ip="192.168.1.171")

      # target=_blank because the operator is mid-authoring: navigating away
      # discards unsaved rule edits and the preview they just ran. Matched as
      # one tag rather than three separate string checks, so the attributes are
      # proven to be on the device link and not on some other anchor.
      assert [anchor] =
               Regex.run(~r{<a [^>]*href="/devices/#{Regex.escape(device.uid)}"[^>]*>}, html)

      assert anchor =~ ~s(target="_blank")
      assert anchor =~ ~s(rel="noopener noreferrer")
    end

    test "a device with no recorded address still renders its row", %{
      conn: conn,
      gateway: gateway,
      tag: tag
    } do
      {check, witness, probe} = previewable_check(conn, gateway, tag)

      device = device_fixture(%{hostname: "#{tag}-anon.local"})
      now = DateTime.utc_now()
      availability(device.uid, witness.uid, true, now)
      availability(device.uid, probe.uid, false, now)

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      html = live |> element("button", "Run preview") |> render_click()

      # The verdict is the point of the row; a missing address omits the span
      # rather than dropping the device or rendering an empty slot.
      assert html =~ ~s(data-preview-device="#{device.uid}")
      assert html =~ ~s(data-preview-verdict="isolated_verified")
    end

    test "an input with no result reads unknown rather than blank", %{
      conn: conn,
      gateway: gateway,
      tag: tag
    } do
      {check, witness, probe} = previewable_check(conn, gateway, tag)

      device = device_fixture(%{hostname: "#{tag}-partial.local"})
      availability(device.uid, witness.uid, true, DateTime.utc_now())

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      html = live |> element("button", "Run preview") |> render_click()

      # The probe never reported. A blank cell would read as "nothing to say";
      # unknown with a reason is the actual state, and it is what keeps the
      # check from being enabled.
      assert html =~
               ~s(data-preview-input="#{probe.uid}" data-preview-value="unknown" data-preview-age="never" data-preview-reason="no_result")

      assert html =~ ~s(data-preview-input="#{witness.uid}" data-preview-value="available")
    end

    test "the rollup names the population no vantage point can see", %{
      conn: conn,
      gateway: gateway,
      tag: tag
    } do
      {check, witness, probe} = previewable_check(conn, gateway, tag)

      dark = device_fixture(%{hostname: "#{tag}-dark.local"})
      now = DateTime.utc_now()
      availability(dark.uid, witness.uid, false, now)
      availability(dark.uid, probe.uid, false, now)

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      html = live |> element("button", "Run preview") |> render_click()

      assert html =~ "visible from no vantage point"
      assert html =~ "cannot be counted as compliant"
      assert html =~ ~s(data-preview-verdict="device_unreachable")
    end

    test "a reachable device is not counted as unreachable", %{
      conn: conn,
      gateway: gateway,
      tag: tag
    } do
      {check, witness, probe} = previewable_check(conn, gateway, tag)

      device = device_fixture(%{hostname: "#{tag}-live.local"})
      now = DateTime.utc_now()
      availability(device.uid, witness.uid, true, now)
      availability(device.uid, probe.uid, false, now)

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      html = live |> element("button", "Run preview") |> render_click()

      refute html =~ "visible from no vantage point"
    end

    test "a draft check's counts are labelled as coming from the sample", %{
      conn: conn,
      gateway: gateway,
      tag: tag
    } do
      {check, _witness, _probe} = previewable_check(conn, gateway, tag)
      device_fixture(%{hostname: "#{tag}-draft.local"})

      assert check.state == :draft

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      html = live |> element("button", "Run preview") |> render_click()

      # A draft has no stored verdicts, so these numbers must not read like a
      # rollup over the whole scope.
      assert html =~ "not from stored verdicts"
    end

    test "an empty scope says so instead of rendering an empty rollup", %{
      conn: conn,
      gateway: gateway,
      tag: tag
    } do
      {check, _witness, _probe} = previewable_check(conn, gateway, tag)

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      html = live |> element("button", "Run preview") |> render_click()

      assert html =~ "No devices are in scope"
    end

    test "the preview persists nothing", %{conn: conn, gateway: gateway, tag: tag} do
      {check, witness, probe} = previewable_check(conn, gateway, tag)

      device = device_fixture(%{hostname: "#{tag}-clean.local"})
      now = DateTime.utc_now()
      availability(device.uid, witness.uid, true, now)
      availability(device.uid, probe.uid, false, now)

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      live |> element("button", "Run preview") |> render_click()

      # `evaluate_devices/5` writes nothing by construction; this asserts the
      # preview really goes through it rather than through `run/2`.
      {:ok, results} =
        DeviceCompositeCheckResult
        |> Ash.Query.filter(check_id == ^check.id)
        |> Ash.read(actor: system_actor())

      assert results == []
    end
  end

  describe "readiness and enable" do
    setup do
      %{gateway: gateway_fixture(), tag: "rd#{System.unique_integer([:positive])}"}
    end

    # A check whose scope is exactly the devices this test created, with
    # `expectations` as its vantage points.
    defp scoped_check(conn, gateway, tag, expectations) do
      agents = Enum.map(expectations, fn _expected -> agent_fixture(gateway) end)

      rows =
        agents
        |> Enum.zip(expectations)
        |> Enum.map(fn {agent, expected} ->
          %{"agent_id" => agent.uid, "expected" => expected}
        end)

      {:ok, live, _html} = live(conn, @path <> "/new")

      live
      |> add_rows(length(rows))
      |> form("#composite-check-form", %{
        "form" => %{
          "name" => "Readiness #{tag}",
          "scope_query" => "in:devices hostname:#{tag}%",
          "evaluation_interval_seconds" => "300"
        },
        "vantage_points" => indexed(rows)
      })
      |> render_submit()

      {check_named!("Readiness #{tag}"), agents}
    end

    defp reload(check) do
      {:ok, reloaded} = CompositeCheck.get_by_id(check.id, actor: system_actor())
      reloaded
    end

    # Enable is a form submit, not a click: the acknowledgement checkbox has to
    # travel with it, and a checkbox outside a form submits nothing.
    defp submit_enable(live, params \\ %{}) do
      live |> form("form[phx-submit=enable]", params) |> render_submit()
    end

    test "a new check says readiness needs a saved check", %{conn: conn} do
      {:ok, _live, html} = live(conn, @path <> "/new")

      assert html =~ "Save the check to see whether it is ready to enable"
      refute html =~ "Check readiness"
    end

    test "saving reports the coverage gap without a second click", %{
      conn: conn,
      gateway: gateway,
      tag: tag
    } do
      witness = agent_fixture(gateway)
      probe = agent_fixture(gateway)

      covered = device_fixture(%{hostname: "#{tag}-covered.local"})
      device_fixture(%{hostname: "#{tag}-uncovered.local"})

      now = DateTime.utc_now()
      availability(covered.uid, witness.uid, true, now)
      availability(covered.uid, probe.uid, false, now)

      {:ok, live, _html} = live(conn, @path <> "/new")

      html =
        live
        |> add_rows(2)
        |> form("#composite-check-form", %{
          "form" => %{
            "name" => "Saved Readiness #{tag}",
            "scope_query" => "in:devices hostname:#{tag}%",
            "evaluation_interval_seconds" => "300"
          },
          "vantage_points" =>
            indexed([
              %{"agent_id" => witness.uid, "expected" => "available"},
              %{"agent_id" => probe.uid, "expected" => "blocked"}
            ])
        })
        |> render_submit()

      # The spec reports coverage at save time, so the save has to stay on the
      # builder and carry the report through the patch to the new check's route.
      assert html =~ ~s(data-readiness-warning="partial_coverage")
      assert html =~ "1 of 2 devices in scope"
    end

    test "a witness-less check cannot be enabled and is told why", %{
      conn: conn,
      gateway: gateway,
      tag: tag
    } do
      {check, _agents} = scoped_check(conn, gateway, tag, ["blocked", "blocked"])
      device_fixture(%{hostname: "#{tag}-a.local"})

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      html = submit_enable(live)

      assert html =~ ~s(data-readiness-blocking="no_liveness_witness")
      assert html =~ "powered-off device is indistinguishable"
      assert reload(check).state == :draft
    end

    test "a missing witness is not acknowledgeable", %{conn: conn, gateway: gateway, tag: tag} do
      {check, _agents} = scoped_check(conn, gateway, tag, ["blocked", "blocked"])
      device_fixture(%{hostname: "#{tag}-a.local"})

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      html = live |> element("button", "Check readiness") |> render_click()

      # A correctness fault, not a timing one. Offering a checkbox would promise
      # an override the resource refuses.
      assert html =~ ~s(data-readiness-blocking="no_liveness_witness")
      refute html =~ "acknowledge_coverage_gap"
    end

    test "zero coverage blocks enabling until it is acknowledged", %{
      conn: conn,
      gateway: gateway,
      tag: tag
    } do
      {check, _agents} = scoped_check(conn, gateway, tag, ["available", "blocked"])
      device_fixture(%{hostname: "#{tag}-a.local"})

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")

      html = submit_enable(live)

      assert html =~ ~s(data-readiness-blocking="no_coverage")
      assert html =~ "Every device will evaluate as inconclusive"
      assert reload(check).state == :draft

      # The failed enable is what surfaces the acknowledgement, so the message
      # names a problem the page now offers a way to answer.
      assert html =~ "acknowledge_coverage_gap"

      submit_enable(live, %{"acknowledge_coverage_gap" => "true"})

      assert reload(check).state == :enabled
    end

    test "partial coverage is a warning, not a block", %{conn: conn, gateway: gateway, tag: tag} do
      {check, [witness, probe]} = scoped_check(conn, gateway, tag, ["available", "blocked"])

      covered = device_fixture(%{hostname: "#{tag}-covered.local"})
      device_fixture(%{hostname: "#{tag}-uncovered.local"})

      now = DateTime.utc_now()
      availability(covered.uid, witness.uid, true, now)
      availability(covered.uid, probe.uid, false, now)

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      html = live |> element("button", "Check readiness") |> render_click()

      assert html =~ ~s(data-readiness-warning="partial_coverage")
      assert html =~ "1 of 2 devices in scope"
      refute html =~ ~s(data-readiness-blocking=)

      submit_enable(live)

      assert reload(check).state == :enabled
    end

    test "full coverage reports ready and enables cleanly", %{
      conn: conn,
      gateway: gateway,
      tag: tag
    } do
      {check, [witness, probe]} = scoped_check(conn, gateway, tag, ["available", "blocked"])

      device = device_fixture(%{hostname: "#{tag}-full.local"})
      now = DateTime.utc_now()
      availability(device.uid, witness.uid, true, now)
      availability(device.uid, probe.uid, false, now)

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      html = live |> element("button", "Check readiness") |> render_click()

      assert html =~ "Every vantage point has coverage"
      assert html =~ ~s(data-coverage-agent="#{witness.uid}" data-coverage-covered="1")
      assert html =~ ~s(data-coverage-agent="#{probe.uid}" data-coverage-covered="1")

      html = submit_enable(live)

      assert reload(check).state == :enabled
      assert html =~ "enabled"
    end

    test "an enabled check can be disabled", %{conn: conn, gateway: gateway, tag: tag} do
      {check, [witness, probe]} = scoped_check(conn, gateway, tag, ["available", "blocked"])

      device = device_fixture(%{hostname: "#{tag}-cycle.local"})
      now = DateTime.utc_now()
      availability(device.uid, witness.uid, true, now)
      availability(device.uid, probe.uid, false, now)

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      submit_enable(live)
      assert reload(check).state == :enabled

      live
      |> element(~s(button[phx-click="disable"][phx-value-id="#{check.id}"]))
      |> render_click()

      assert reload(check).state == :disabled
    end

    test "an enabled check can be disabled from the index", %{conn: conn, gateway: gateway, tag: tag} do
      {check, [witness, probe]} = scoped_check(conn, gateway, tag, ["available", "blocked"])

      device = device_fixture(%{hostname: "#{tag}-index-disable.local"})
      now = DateTime.utc_now()
      availability(device.uid, witness.uid, true, now)
      availability(device.uid, probe.uid, false, now)

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      submit_enable(live)
      assert reload(check).state == :enabled

      {:ok, index, html} = live(conn, @path)
      assert html =~ ~s(phx-click="disable")

      index
      |> element(~s(button[phx-click="disable"][phx-value-id="#{check.id}"]))
      |> render_click()

      assert reload(check).state == :disabled
    end

    test "an enabled check offers no enable control", %{conn: conn, gateway: gateway, tag: tag} do
      {check, [witness, probe]} = scoped_check(conn, gateway, tag, ["available", "blocked"])

      device = device_fixture(%{hostname: "#{tag}-once.local"})
      now = DateTime.utc_now()
      availability(device.uid, witness.uid, true, now)
      availability(device.uid, probe.uid, false, now)

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      html = submit_enable(live)

      # The enable form is gone once the check is enabled, so there is no way to
      # submit it twice.
      refute html =~ ~s(phx-submit="enable")
      assert html =~ ~s(phx-click="disable")
    end
  end

  describe "sweep context" do
    setup do
      %{gateway: gateway_fixture(), tag: "sw#{System.unique_integer([:positive])}"}
    end

    defp sweep_profile(attrs) do
      ServiceRadar.SweepJobs.SweepProfile
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(
          %{name: "Profile #{System.unique_integer([:positive])}", ports: [22, 443]},
          attrs
        ),
        actor: system_actor()
      )
      |> Ash.create!()
    end

    defp sweep_group(attrs) do
      ServiceRadar.SweepJobs.SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(
          %{name: "Group #{System.unique_integer([:positive])}", partition: "default"},
          attrs
        ),
        actor: system_actor()
      )
      |> Ash.create!()
    end

    test "a new check says sweep context needs a saved check", %{conn: conn} do
      {:ok, _live, html} = live(conn, @path <> "/new")

      assert html =~ "Save the check to see which sweeps feed its vantage points"
    end

    test "a group assigned to the agent renders its ports and cadence", %{
      conn: conn,
      gateway: gateway
    } do
      {check, witness, _probe} = saved_check_with_vantage_points(conn, gateway, "Swept")

      group =
        sweep_group(%{
          agent_id: witness.uid,
          ports: [22, 3389],
          sweep_modes: ["tcp"],
          interval: "15m"
        })

      {:ok, _live, html} = live(conn, @path <> "/#{check.id}/edit")

      assert html =~ ~s(data-sweep-group="#{group.id}")
      assert html =~ "ports 22, 3389"
      assert html =~ "every 15m"
      assert html =~ "assigned to this agent"
    end

    test "an unassigned group in the partition also covers the agent", %{
      conn: conn,
      gateway: gateway
    } do
      {check, _witness, _probe} = saved_check_with_vantage_points(conn, gateway, "Partitionwide")

      group = sweep_group(%{agent_id: nil, ports: [443], interval: "1h"})

      {:ok, _live, html} = live(conn, @path <> "/#{check.id}/edit")

      # `SweepGroup.agent_id` nil means "any agent in partition", so this group
      # feeds the vantage point even though it names no agent.
      assert html =~ ~s(data-sweep-group="#{group.id}")
      assert html =~ "any agent in partition"
    end

    test "a group in another partition does not count as coverage", %{
      conn: conn,
      gateway: gateway
    } do
      {check, _witness, _probe} = saved_check_with_vantage_points(conn, gateway, "Elsewhere")

      elsewhere = sweep_group(%{agent_id: nil, partition: "somewhere-else", ports: [443]})
      here = sweep_group(%{agent_id: nil, partition: "default", ports: [22]})

      {:ok, _live, html} = live(conn, @path <> "/#{check.id}/edit")

      # `:by_agent` would have credited the foreign one: its filter is
      # agent-or-nil and ignores partition entirely. Asserting the local group
      # renders too is what keeps this from passing on an empty panel.
      assert html =~ ~s(data-sweep-group="#{here.id}")
      refute html =~ ~s(data-sweep-group="#{elsewhere.id}")
    end

    test "every covering group is listed, none singled out as the profile", %{
      conn: conn,
      gateway: gateway
    } do
      {check, witness, _probe} = saved_check_with_vantage_points(conn, gateway, "Several")

      assigned = sweep_group(%{agent_id: witness.uid, ports: [22]})
      partition_wide = sweep_group(%{agent_id: nil, ports: [443]})

      {:ok, _live, html} = live(conn, @path <> "/#{check.id}/edit")

      assert html =~ ~s(data-sweep-group="#{assigned.id}")
      assert html =~ ~s(data-sweep-group="#{partition_wide.id}")
    end

    test "a vantage point with no covering group is named", %{conn: conn, gateway: gateway} do
      {check, witness, probe} = saved_check_with_vantage_points(conn, gateway, "Uncovered")

      {:ok, _live, html} = live(conn, @path <> "/#{check.id}/edit")

      # The silent case: without this the panel renders nothing and the operator
      # cannot tell "no sweeps" from "not loaded".
      assert html =~ ~s(data-sweep-uncovered="#{witness.uid}")
      assert html =~ ~s(data-sweep-uncovered="#{probe.uid}")
      assert html =~ "will resolve unknown for every"
    end

    test "a group's ports fall back to its profile's", %{conn: conn, gateway: gateway} do
      {check, witness, _probe} = saved_check_with_vantage_points(conn, gateway, "Inherited")

      profile = sweep_profile(%{ports: [161, 162], sweep_modes: ["icmp"]})
      sweep_group(%{agent_id: witness.uid, profile_id: profile.id, ports: nil, sweep_modes: nil})

      {:ok, _live, html} = live(conn, @path <> "/#{check.id}/edit")

      # Group ports are an override of the profile's. Rendering the group's nil
      # would claim no ports are probed when the profile names two.
      assert html =~ "ports 161, 162"
      assert html =~ "icmp"
    end

    test "a disabled group is not shown as coverage", %{conn: conn, gateway: gateway} do
      {check, witness, _probe} = saved_check_with_vantage_points(conn, gateway, "Disabled Sweep")

      group = sweep_group(%{agent_id: witness.uid, ports: [22], enabled: false})

      {:ok, _live, html} = live(conn, @path <> "/#{check.id}/edit")

      refute html =~ ~s(data-sweep-group="#{group.id}")
      assert html =~ ~s(data-sweep-uncovered="#{witness.uid}")
    end

    test "the panel links to sweep administration rather than editing in place", %{
      conn: conn,
      gateway: gateway
    } do
      {check, witness, _probe} = saved_check_with_vantage_points(conn, gateway, "Linked")
      group = sweep_group(%{agent_id: witness.uid, ports: [22]})

      {:ok, _live, html} = live(conn, @path <> "/#{check.id}/edit")

      assert html =~ "Edit in sweep administration"
      assert html =~ ~s(href="/settings/networks/groups/#{group.id}")
    end
  end

  describe "device facts" do
    setup do
      %{gateway: gateway_fixture()}
    end

    defp fill_facts(live, rows) do
      live
      |> form("#composite-check-form", %{"device_facts" => indexed(rows)})
      |> render_change()
    end

    defp submit_with_facts(live, name, vantage_rows, fact_rows) do
      live
      |> form("#composite-check-form", %{
        "form" => %{
          "name" => name,
          "scope_query" => "in:devices",
          "evaluation_interval_seconds" => "300"
        },
        "vantage_points" => indexed(vantage_rows),
        "device_facts" => indexed(fact_rows)
      })
      |> render_submit()
    end

    test "the builder offers a device fact section", %{conn: conn} do
      {:ok, _live, html} = live(conn, @path <> "/new")

      assert html =~ "Device facts"
      assert html =~ "Add device fact"

      # The third factor is what separates enforced isolation from incidental
      # isolation, so the section has to say that rather than just take a key.
      #
      # Whitespace-normalised because the assertion is about the sentence the
      # operator reads, not about where the source happens to wrap it -- an
      # earlier rewrap of this copy broke the match without changing a word of
      # what renders.
      assert normalize_space(html) =~ "enforced isolation from incidental isolation"
    end

    defp normalize_space(html), do: String.replace(html, ~r/\s+/, " ")

    test "adding a fact renders a metadata key field", %{conn: conn} do
      {:ok, live, _html} = live(conn, @path <> "/new")

      html = live |> element("button", "Add device fact") |> render_click()

      assert html =~ ~s(name="device_facts[0][path]")
      assert html =~ ~s(name="device_facts[0][max_age_seconds]")
    end

    test "the key field is a combobox, so a key nothing has written yet is still typable", %{
      conn: conn
    } do
      # A device carrying a NON-boolean value at some key. It must not be
      # suggested: the resolver casts booleans only, so offering it would offer
      # a choice that resolves `unknown` forever. Observed on a live deployment
      # where every existing metadata key was non-boolean internal bookkeeping,
      # which is what a plain dropdown would have listed.
      device_fixture(%{
        hostname: "combo-#{System.unique_integer([:positive])}.local",
        metadata: %{"identity_state" => "canonical", "acl_enforced" => true}
      })

      {:ok, live, _html} = live(conn, @path <> "/new")
      html = live |> element("button", "Add device fact") |> render_click()

      # Free text bound to a datalist -- not a <select>, which would make the
      # common case (a key the validator has not written yet) impossible.
      assert html =~ ~s(list="device-fact-key-options")
      refute html =~ ~s(<select name="device_facts[0][path]")

      assert html =~ ~s(<option value="acl_enforced")
      refute html =~ ~s(<option value="identity_state")
    end

    test "saving persists the fact as a device_metadata input", %{conn: conn, gateway: gateway} do
      witness = agent_fixture(gateway)
      probe = agent_fixture(gateway)

      {:ok, live, _html} = live(conn, @path <> "/new")
      add_rows(live, 2)
      live |> element("button", "Add device fact") |> render_click()

      submit_with_facts(
        live,
        "Three Factor",
        [
          %{"agent_id" => witness.uid, "expected" => "available"},
          %{"agent_id" => probe.uid, "expected" => "blocked"}
        ],
        [%{"path" => "nco_acl_enforced", "max_age_seconds" => "3600"}]
      )

      check = check_named!("Three Factor")
      {:ok, inputs} = CompositeCheckInput.list_by_check(check.id, actor: system_actor())

      assert fact = Enum.find(inputs, &(&1.kind == :device_metadata))
      assert fact.config["path"] == "nco_acl_enforced"
      assert fact.config["value_type"] == "boolean"
      assert fact.config["max_age_seconds"] == 3600
      # Keyed by the metadata path, which is what rule match maps address.
      assert fact.key == "nco_acl_enforced"

      # Facts sit after the vantage points so the rule columns read
      # "who could reach it, then what it is configured to be".
      assert fact.position == 2
    end

    test "a blank max age omits the key rather than storing nil", %{conn: conn, gateway: gateway} do
      witness = agent_fixture(gateway)

      {:ok, live, _html} = live(conn, @path <> "/new")
      add_rows(live, 1)
      live |> element("button", "Add device fact") |> render_click()

      submit_with_facts(
        live,
        "No Max Age",
        [%{"agent_id" => witness.uid, "expected" => "available"}],
        [%{"path" => "nco_acl_enforced", "max_age_seconds" => ""}]
      )

      check = check_named!("No Max Age")
      {:ok, inputs} = CompositeCheckInput.list_by_check(check.id, actor: system_actor())
      fact = Enum.find(inputs, &(&1.kind == :device_metadata))

      # Absent, not nil: without it the resolver trusts the stored value and
      # needs no provenance, which is what keeps a key written by a path that
      # records none usable at all.
      refute Map.has_key?(fact.config, "max_age_seconds")
    end

    test "a fact with no metadata key is rejected locally", %{conn: conn} do
      {:ok, live, _html} = live(conn, @path <> "/new")
      live |> element("button", "Add device fact") |> render_click()

      html = submit_with_facts(live, "No Key", [], [%{"path" => ""}])

      assert html =~ "needs a metadata key"
      assert {:ok, []} = read_checks_named("No Key")
    end

    test "the same metadata key cannot be used twice", %{conn: conn} do
      {:ok, live, _html} = live(conn, @path <> "/new")
      add_facts(live, 2)

      html =
        submit_with_facts(live, "Dupe Key", [], [
          %{"path" => "nco_acl_enforced"},
          %{"path" => "nco_acl_enforced"}
        ])

      assert html =~ "only be used once"
      assert {:ok, []} = read_checks_named("Dupe Key")
    end

    test "a non-numeric max age is caught before the resource", %{conn: conn} do
      {:ok, live, _html} = live(conn, @path <> "/new")
      add_facts(live, 1)

      html =
        fill_facts(live, [%{"path" => "nco_acl_enforced", "max_age_seconds" => "soon"}])

      assert html =~ "whole number of seconds above zero"
    end

    test "generating with a fact splits the isolated row on the configuration", %{
      conn: conn,
      gateway: gateway
    } do
      witness = agent_fixture(gateway)
      probe = agent_fixture(gateway)

      {:ok, live, _html} = live(conn, @path <> "/new")
      add_rows(live, 2)
      live |> element("button", "Add device fact") |> render_click()

      submit_with_facts(
        live,
        "Split Table",
        [
          %{"agent_id" => witness.uid, "expected" => "available"},
          %{"agent_id" => probe.uid, "expected" => "blocked"}
        ],
        [%{"path" => "nco_acl_enforced", "max_age_seconds" => ""}]
      )

      check = check_named!("Split Table")

      {:ok, live, _html} = live(conn, @path <> "/#{check.id}/edit")
      live |> element("button", "Generate from expectations") |> render_click()

      {:ok, rules} = CompositeCheckRule.list_by_check(check.id, actor: system_actor())
      verdicts = rules |> Enum.reject(& &1.catch_all) |> Enum.map(& &1.verdict)

      # This is the whole point of the third factor: blocked-and-configured is a
      # different verdict from blocked-but-not-by-config.
      assert "isolated_verified" in verdicts
      assert "isolated_unenforced" in verdicts

      verified = Enum.find(rules, &(&1.verdict == "isolated_verified"))
      unenforced = Enum.find(rules, &(&1.verdict == "isolated_unenforced"))

      assert verified.match["nco_acl_enforced"] == true
      assert unenforced.match["nco_acl_enforced"] == false
      assert unenforced.status == :degraded
    end

    test "editing a check reloads its saved facts", %{conn: conn, gateway: gateway} do
      witness = agent_fixture(gateway)

      {:ok, live, _html} = live(conn, @path <> "/new")
      add_rows(live, 1)
      live |> element("button", "Add device fact") |> render_click()

      submit_with_facts(
        live,
        "Reloaded Facts",
        [%{"agent_id" => witness.uid, "expected" => "available"}],
        [%{"path" => "nco_acl_enforced", "max_age_seconds" => "1800"}]
      )

      check = check_named!("Reloaded Facts")

      {:ok, _live, html} = live(conn, @path <> "/#{check.id}/edit")

      assert html =~ ~s(value="nco_acl_enforced")
      assert html =~ ~s(value="1800")
    end

    defp add_facts(live, count) do
      Enum.each(1..count//1, fn _index ->
        live |> element("button", "Add device fact") |> render_click()
      end)

      live
    end
  end
end
