defmodule ServiceRadarWebNGWeb.TimezoneSurfaceBTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Phoenix.LiveComponent.CID
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Admin.ClusterLive.Index, as: AdminCluster
  alias ServiceRadarWebNGWeb.Components.PromotionRuleBuilder
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View.SweepGroups
  alias ServiceRadarWebNGWeb.UserLive.ApiCredentials

  @moduletag :db_free

  @canonical ~U[2026-08-30 18:00:00Z]
  @timezone "America/Chicago"

  test "admin cluster event rows keep canonical instants and stable unique ids" do
    events = [
      %{type: :node_up, node: :edge_a@localhost, timestamp: @canonical},
      %{type: :node_down, node: :edge_b@localhost, timestamp: @canonical}
    ]

    html = render_admin_cluster(events)

    times =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("time[data-user-time-zone='#{@timezone}']")

    assert LazyHTML.attribute(times, "datetime") ==
             List.duplicate("2026-08-30T18:00:00Z", 2)

    ids = LazyHTML.attribute(times, "id")
    assert length(ids) == 2
    assert Enum.all?(ids, &(&1 != ""))
    assert Enum.uniq(ids) == ids
    assert user_time_ids(render_admin_cluster(Enum.reverse(events))) == Enum.reverse(ids)
  end

  test "settings sweep rows render repeated absolute last-run instants semantically" do
    groups = [sweep_group("group-a"), sweep_group("group-b")]

    html =
      render_component(&SweepGroups.render/1,
        groups: groups,
        sweep_command_statuses: %{},
        can_manage_networks: false,
        timezone: @timezone
      )

    times =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("time[data-user-time-zone='#{@timezone}']")

    assert LazyHTML.attribute(times, "id") == [
             "settings-sweep-group-group-a-last-run-at",
             "settings-sweep-group-group-b-last-run-at"
           ]

    assert LazyHTML.attribute(times, "datetime") ==
             List.duplicate("2026-08-30T18:00:00Z", 2)

    reordered_html =
      render_component(&SweepGroups.render/1,
        groups: Enum.reverse(groups),
        sweep_command_statuses: %{},
        can_manage_networks: false,
        timezone: @timezone
      )

    assert user_time_ids(reordered_html) ==
             Enum.reverse(LazyHTML.attribute(times, "id"))
  end

  test "API credential relative labels retain accessible canonical user-time metadata" do
    html = render_api_credentials([api_client("client-a"), api_client("client-b")])

    times =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("time[data-user-time-zone='#{@timezone}']")

    assert LazyHTML.attribute(times, "id") == [
             "api-credential-client-a-last-used-at",
             "api-credential-client-b-last-used-at"
           ]

    assert LazyHTML.attribute(times, "datetime") ==
             List.duplicate("2026-08-30T18:00:00Z", 2)

    assert user_time_ids(render_api_credentials([api_client("client-b"), api_client("client-a")])) ==
             Enum.reverse(LazyHTML.attribute(times, "id"))
  end

  test "promotion preview timestamps use the saved timezone without changing source values" do
    form =
      to_form(
        %{
          "name" => "preview",
          "body_contains" => "error",
          "body_contains_enabled" => true,
          "severity_text" => "error",
          "severity_enabled" => true,
          "service_name" => "api",
          "service_name_enabled" => true,
          "attribute_key" => "",
          "attribute_value" => "",
          "attribute_enabled" => false,
          "auto_alert" => false,
          "parsed_attributes" => %{}
        },
        as: :rule
      )

    logs = [preview_log("log-a"), preview_log("log-b")]
    html = render_promotion_preview(form, logs)

    times =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("time[data-user-time-zone='#{@timezone}']")

    assert LazyHTML.attribute(times, "id") == [
             "promotion-preview-log-log-a-timestamp",
             "promotion-preview-log-log-b-timestamp"
           ]

    assert LazyHTML.attribute(times, "datetime") ==
             List.duplicate("2026-08-30T18:00:00Z", 2)

    assert user_time_ids(render_promotion_preview(form, Enum.reverse(logs))) ==
             Enum.reverse(LazyHTML.attribute(times, "id"))
  end

  defp render_admin_cluster(events) do
    render_component(&AdminCluster.render/1,
      flash: %{},
      current_scope: scope(),
      settings_active_view: nil,
      settings_active_category: nil,
      settings_breadcrumbs: [],
      settings_nav_tree: %{categories: [], groups: []},
      settings_palette: [],
      settings_stats: [],
      cluster_status: %{enabled: true, node_count: 1, self: :web@localhost, connected_nodes: []},
      cluster_health: %{gateway_count: 0, agent_count: 0},
      gateways: [],
      agents: [],
      events: events
    )
  end

  defp render_api_credentials(clients) do
    render_component(&ApiCredentials.render/1,
      flash: %{},
      current_scope: scope(),
      settings_active_view: nil,
      settings_active_category: nil,
      settings_breadcrumbs: [],
      settings_nav_tree: %{categories: [], groups: []},
      settings_palette: [],
      settings_stats: [],
      show_secret_modal: false,
      show_create_modal: false,
      show_revoke_modal: false,
      clients: clients,
      base_url: "https://example.test"
    )
  end

  defp render_promotion_preview(form, logs) do
    render_component(&PromotionRuleBuilder.render/1,
      myself: %CID{cid: 1},
      current_scope: scope(),
      mode: :create,
      form: form,
      preview_state: :done,
      preview_result: %{match_count: length(logs), sample_logs: logs},
      preview_error: nil,
      saving: false,
      error: nil
    )
  end

  defp user_time_ids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("time[data-user-time-zone='#{@timezone}']")
    |> LazyHTML.attribute("id")
  end

  defp scope do
    Scope.for_user(%{
      id: "user-a",
      email: "user@example.test",
      role: :admin,
      timezone: @timezone
    })
  end

  defp sweep_group(id) do
    %{
      id: id,
      enabled: true,
      name: id,
      description: nil,
      schedule_type: :interval,
      interval: 300,
      cron_expression: nil,
      partition: "default",
      agent_id: nil,
      agent_ids: [],
      last_run_at: @canonical,
      execution_count: 0,
      executions: []
    }
  end

  defp api_client(id) do
    %{
      id: id,
      name: id,
      description: nil,
      scopes: ["read"],
      enabled: true,
      revoked_at: nil,
      expires_at: nil,
      last_used_at: @canonical,
      use_count: 1
    }
  end

  defp preview_log(id) do
    %{
      "id" => id,
      "timestamp" => "2026-08-30T18:00:00Z",
      "severity_text" => "error",
      "body" => "request failed"
    }
  end
end
