defmodule ServiceRadarWebNG.Dashboards.SystemReportsTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Dashboards.DashboardPanel
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
      for spec <- SystemReports.dashboard_specs(), panel <- spec.panels do
        for {_key, field} <- panel.data_binding do
          selected? =
            String.contains?(panel.srql_query, field) or
              (field == @implicit_bucket_field and
                 String.contains?(panel.srql_query, "by time:"))

          assert selected?,
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

    test "the AS panel excludes ASNs the GeoLite2 lookup could not resolve" do
      mtr =
        Enum.find(
          SystemReports.dashboard_specs(),
          &(&1.slug == SystemReports.mtr_path_analytics_slug())
        )

      asn_panel = Enum.find(mtr.panels, &String.contains?(&1.srql_query, "by asn"))

      assert asn_panel, "the MTR dashboard must define an AS-grouped panel"

      # asn is populated only by a GeoLite2 lookup, which carries no private ASNs
      # and no RFC1918 addresses. Without this filter every internal hop lands in
      # one NULL bucket that reads as a finding rather than missing data.
      assert String.contains?(asn_panel.srql_query, "asn:>0"),
             "the AS panel must restrict to resolved ASNs: #{asn_panel.srql_query}"

      assert String.contains?(String.downcase(asn_panel.title), "transit") or
               String.contains?(String.downcase(asn_panel.title), "external"),
             "the AS panel title must not read as fleet-wide: #{asn_panel.title}"
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
