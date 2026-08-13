defmodule ServiceRadarWebNGWeb.Settings.CompositeChecksLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
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
        ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
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

    test "saving persists the scope and returns to the index", %{conn: conn} do
      {:ok, live, _html} = live(conn, @path <> "/new")

      {:ok, _index, html} =
        live
        |> form("#composite-check-form", %{
          "form" => %{
            "name" => "Scoped Check",
            "scope_query" => "in:devices source:armis",
            "evaluation_interval_seconds" => "300"
          }
        })
        |> render_submit()
        |> follow_redirect(conn, @path)

      assert html =~ "Scoped Check"
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
      |> follow_redirect(conn, @path)

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
      |> follow_redirect(conn, @path)

      check = check_named!("Replaced Check")

      {:ok, live, html} = live(conn, @path <> "/#{check.id}/edit")
      assert html =~ original.uid
      assert html =~ "liveness witness"

      live
      |> submit_check("Replaced Check", [
        %{"agent_id" => replacement.uid, "expected" => "available"}
      ])
      |> follow_redirect(conn, @path)

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
      |> follow_redirect(conn, @path)

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
end
