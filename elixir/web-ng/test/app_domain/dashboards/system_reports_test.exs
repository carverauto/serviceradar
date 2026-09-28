defmodule ServiceRadarWebNG.Dashboards.SystemReportsTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Dashboards.DashboardPanel
  alias ServiceRadarWebNG.Dashboards.Definition
  alias ServiceRadarWebNG.Dashboards.SystemReports
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.AccessControls

  # A `time:<duration>` group dimension projects its bucket under this key. It is
  # produced by the compiler rather than named in the query text, so a binding
  # may reference it without the field appearing in the SRQL.
  @implicit_bucket_field "bucket"

  @moduletag :db_free

  describe "definition_action/1" do
    test "creates a definition that is not stored yet" do
      assert SystemReports.definition_action(nil) == :create
    end

    test "keeps a stored definition rather than rewriting it" do
      # The property this whole module exists to preserve. The previous
      # implementation wrote the shipped query back over a differing one, so an
      # operator edit was silently reverted on the next boot — a divergence that
      # only appeared after a restart, long after the edit had seemed to succeed.
      edited = %{
        slug: "mtr-path-analytics",
        title: "Renamed by the operator",
        panels: [%{srql_query: "in:mtr_hops addr:198.51.100.7 limit:5"}]
      }

      assert SystemReports.definition_action(edited) == :keep
    end

    test "keeps a definition whose panels were reduced but not emptied" do
      assert SystemReports.definition_action(%{panels: [%{srql_query: "in:devices limit:1"}]}) ==
               :keep
    end

    test "completes a definition stored with no panels" do
      # An interrupted creation, not an operator choice: a dashboard with no
      # panels renders nothing and cannot have been deliberately configured that
      # way by anyone using the builder.
      assert SystemReports.definition_action(%{panels: []}) == :create_panels
      assert SystemReports.definition_action(%{panels: nil}) == :create_panels
      assert SystemReports.definition_action(%{}) == :create_panels
    end
  end

  describe "dashboard_specs/0" do
    test "ships the new-devices definition unchanged alongside MTR path analytics" do
      slugs = Enum.map(SystemReports.dashboard_specs(), & &1.slug)

      assert SystemReports.new_devices_slug() in slugs
      assert SystemReports.mtr_path_analytics_slug() in slugs
      assert length(Enum.uniq(slugs)) == length(slugs), "slugs must be unique"
    end

    test "every panel carries a query, a visual type and a distinct position" do
      for spec <- SystemReports.dashboard_specs() do
        assert spec.panels != [], "#{spec.slug} must define at least one panel"

        positions = Enum.map(spec.panels, & &1.position)

        assert length(Enum.uniq(positions)) == length(positions),
               "#{spec.slug} has duplicate panel positions"

        for panel <- spec.panels do
          assert is_binary(panel.srql_query) and panel.srql_query != ""
          assert is_atom(panel.visual_type)
          assert is_binary(panel.title) and panel.title != ""
        end
      end
    end

    test "every panel declares an explicit grid layout" do
      # An omitted layout is not "let the renderer choose". LayoutHelpers defaults
      # a missing layout to x=0, y=0, w=12, h=4, so panels that all omit it land in
      # one grid cell and only one is visible on the dashboard view — while the
      # builder canvas still shows them spread out by its own placement, which is
      # what made this look like a renderer bug.
      for spec <- SystemReports.dashboard_specs(), panel <- spec.panels do
        layout = Map.get(panel, :layout)

        assert is_map(layout) and layout != %{},
               "#{spec.slug}/#{panel.title} has no layout, so it would stack on the others"

        for key <- ["x", "y", "w", "h"] do
          assert is_integer(Map.get(layout, key)),
                 "#{spec.slug}/#{panel.title} layout is missing an integer #{key}"
        end

        assert layout["x"] >= 0 and layout["x"] <= 11,
               "#{spec.slug}/#{panel.title} x is outside the 12-column grid"

        assert layout["x"] + layout["w"] <= 12,
               "#{spec.slug}/#{panel.title} overflows the 12-column grid"
      end
    end

    test "no two panels on a dashboard occupy the same grid cell" do
      for spec <- SystemReports.dashboard_specs() do
        cells =
          Enum.flat_map(spec.panels, fn panel ->
            l = panel.layout

            for cx <- l["x"]..(l["x"] + l["w"] - 1),
                cy <- l["y"]..(l["y"] + l["h"] - 1),
                do: {cx, cy}
          end)

        assert length(Enum.uniq(cells)) == length(cells),
               "#{spec.slug} has overlapping panel layouts, so a panel would be hidden"
      end
    end

    test "the panel attribute allowlist passes layout through to the resource" do
      assert :layout in SystemReports.panel_attribute_keys()
      assert :layout in Info.action(DashboardPanel, :create).accept
    end

    test "every key a shipped panel sets is in the panel attribute allowlist" do
      allowed = MapSet.new(SystemReports.panel_attribute_keys())

      for spec <- SystemReports.dashboard_specs(), panel <- spec.panels do
        panel_keys = MapSet.new(Map.keys(panel))
        dropped = MapSet.difference(panel_keys, allowed)

        assert MapSet.size(dropped) == 0,
               "#{spec.slug}/#{panel.title} sets keys not in panel_attribute_keys/0 " <>
                 "(would be silently dropped by Map.take): #{inspect(MapSet.to_list(dropped))}"
      end
    end

    test "every panel's visual type is one the resource accepts" do
      allowed =
        DashboardPanel
        |> Info.attribute(:visual_type)
        |> Map.fetch!(:constraints)
        |> Keyword.fetch!(:one_of)

      for spec <- SystemReports.dashboard_specs(), panel <- spec.panels do
        assert panel.visual_type in allowed,
               "#{spec.slug}/#{panel.title} uses visual_type #{inspect(panel.visual_type)}, " <>
                 "which the resource would reject"
      end
    end

    test "every data binding names a field the panel's own query selects" do
      # A binding naming a field the query does not produce renders an empty
      # panel with no error, which is the failure mode this guards.
      # Uses Definition.selects_field?/2 so quoted multi-aggregation expressions
      # (stats:"... by hop_number") are handled the same way the validator handles them.
      for spec <- SystemReports.dashboard_specs(), panel <- spec.panels do
        for {_key, field} <- panel.data_binding do
          assert Definition.selects_field?(panel.srql_query, field),
                 "#{spec.slug}/#{panel.title} binds #{inspect(field)}, " <>
                   "which its query does not select: #{panel.srql_query}"
        end
      end
    end

    test "a bucket binding is only valid when the query groups by a time dimension" do
      # Guards the exemption above from becoming a blanket escape: binding
      # `bucket` on a query with no time dimension would render an empty panel.
      for spec <- SystemReports.dashboard_specs(), panel <- spec.panels do
        if @implicit_bucket_field in Map.values(panel.data_binding) do
          assert String.contains?(panel.srql_query, "by time:"),
                 "#{spec.slug}/#{panel.title} binds the bucket field but does not " <>
                   "group by time: #{panel.srql_query}"
        end
      end
    end

    test "MTR loss and latency panels use the statistically correct aggregates" do
      mtr =
        Enum.find(
          SystemReports.dashboard_specs(),
          &(&1.slug == SystemReports.mtr_path_analytics_slug())
        )

      queries = Enum.map(mtr.panels, & &1.srql_query)

      # Averaging a percentage is a mean of ratios; loss is a ratio of sums.
      refute Enum.any?(queries, &String.contains?(&1, "avg(loss_pct)"))
      refute Enum.any?(queries, &String.contains?(&1, "avg(avg_us)"))
      assert Enum.any?(queries, &String.contains?(&1, "loss_ratio(sent, received)"))
      assert Enum.any?(queries, &String.contains?(&1, "wavg(avg_us, received)"))
    end

    test "the MTR dashboard has no GeoLite2-dependent panel" do
      # The AS-grouped panel was intentionally dropped. `asn` is populated only by
      # a GeoLite2 lookup that most deployments do not run. For internal hops every
      # address lands in a NULL bucket that reads as a finding rather than missing
      # data, so shipping the panel does more harm than good.
      mtr =
        Enum.find(
          SystemReports.dashboard_specs(),
          &(&1.slug == SystemReports.mtr_path_analytics_slug())
        )

      asn_panel = Enum.find(mtr.panels, &String.contains?(&1.srql_query, "by asn"))

      refute asn_panel,
             "the MTR dashboard must not ship a GeoLite2-dependent AS panel: #{inspect(asn_panel && asn_panel.title)}"
    end
  end

  describe "edit authority on a built-in dashboard" do
    test "the panel resource requires edit permission or a per-dashboard grant" do
      # Asserted against the resource's own policy model rather than its source
      # text, so a rewrite that preserves meaning does not fail this and one that
      # drops the authorization does.
      mutation_policy =
        DashboardPanel
        |> Ash.Policy.Info.policies()
        |> Enum.find(fn policy ->
          condition = inspect(policy.condition)
          condition =~ "ActionType" and condition =~ ":update"
        end)

      assert mutation_policy,
             "DashboardPanel must carry a policy whose condition covers :update"

      checks = Enum.map_join(mutation_policy.policies, " ", &inspect/1)

      assert checks =~ "analytics.dashboards.edit",
             "changing a panel must require the dashboard edit permission: #{checks}"

      assert checks =~ "ActorCanEditDashboardChild",
             "a per-dashboard edit grant must remain a way to authorize the change: #{checks}"
    end

    test "a public dashboard with no owner grants no edit rights by itself" do
      # The built-in case. `dashboard_owner?/2` has no clause for a nil owner, so
      # this must fall through to false rather than treating "public" as "mine".
      built_in = %{owner_id: nil, visibility: :public}
      scope = %{user: %{id: "11111111-1111-1111-1111-111111111111"}}

      refute AccessControls.can_manage?(built_in, %{
               current_scope: scope,
               can_edit?: false
             })
    end

    test "the edit permission is what grants management of a built-in dashboard" do
      built_in = %{owner_id: nil, visibility: :public}
      scope = %{user: %{id: "11111111-1111-1111-1111-111111111111"}}

      assert AccessControls.can_manage?(built_in, %{
               current_scope: scope,
               can_edit?: true
             })
    end

    test "an absent scope is refused rather than defaulting open" do
      refute AccessControls.can_manage?(%{owner_id: nil, visibility: :public}, %{})
      refute AccessControls.can_manage?(nil, %{can_edit?: true})
    end
  end
end
