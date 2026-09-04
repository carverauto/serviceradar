defmodule ServiceRadarWebNG.Dashboards do
  @moduledoc """
  Context module for browser-hosted dashboard packages.
  """

  use Boundary,
    top_level?: true,
    deps: [ServiceRadarWebNG, ServiceRadarWebNG.Plugins],
    exports: :all

  alias ServiceRadarWebNG.Dashboards.Authored
  alias ServiceRadarWebNG.Dashboards.GroupAccess
  alias ServiceRadarWebNG.Dashboards.Packages

  defdelegate page_group_access(scope, entrypoint_source, group_id, selector),
    to: GroupAccess,
    as: :page

  defdelegate ensure_group_view(scope, entrypoint_source, target_id, group_id, opts \\ []),
    to: GroupAccess

  defdelegate revoke_group_view(scope, entrypoint_source, target_id, group_id, opts \\ []),
    to: GroupAccess

  defdelegate set_group_access(scope, entrypoint_source, target_id, group_id, access, opts \\ []),
    to: GroupAccess

  defdelegate list_packages(filters \\ %{}, opts \\ []), to: Packages, as: :list
  defdelegate get_package(id, opts \\ []), to: Packages, as: :get
  defdelegate import_package_json(manifest_json, wasm, opts \\ []), to: Packages, as: :import_json
  defdelegate import_package_github(attrs, opts \\ []), to: Packages, as: :import_github
  defdelegate enable_package(id, opts \\ []), to: Packages, as: :enable
  defdelegate disable_package(id, opts \\ []), to: Packages, as: :disable
  defdelegate create_instance(package, attrs, opts \\ []), to: Packages
  defdelegate get_instance(id, opts \\ []), to: Packages
  defdelegate update_instance(id, attrs, opts \\ []), to: Packages
  defdelegate set_default_instance(id, opts \\ []), to: Packages
  defdelegate enabled_instances(opts \\ []), to: Packages
  defdelegate get_enabled_instance_by_slug(slug, opts \\ []), to: Packages
  defdelegate package_has_viewable_instance?(package_id, opts \\ []), to: Packages
  defdelegate list_instance_access_grants(scope, instance_id), to: Packages
  defdelegate grant_instance_to_user(scope, attrs), to: Packages
  defdelegate grant_instance_to_group(scope, attrs), to: Packages
  defdelegate revoke_instance_access_grant(scope, grant), to: Packages

  defdelegate list_authored_dashboards(scope, filters \\ %{}), to: Authored, as: :list_dashboards
  defdelegate get_authored_dashboard(scope, id, opts \\ []), to: Authored, as: :get_dashboard
  defdelegate create_authored_dashboard(scope, attrs), to: Authored, as: :create_dashboard

  defdelegate create_authored_dashboard_with_panels(scope, attrs, panel_attrs),
    to: Authored,
    as: :create_dashboard_with_panels

  defdelegate update_authored_dashboard(scope, dashboard, attrs),
    to: Authored,
    as: :update_dashboard

  defdelegate archive_authored_dashboard(scope, dashboard), to: Authored, as: :archive_dashboard
  defdelegate list_dashboard_preferences(scope), to: Authored
  defdelegate set_dashboard_favorite(scope, target_type, target_id, favorite?), to: Authored
  defdelegate set_default_dashboard(scope, target_type, target_id), to: Authored
  defdelegate list_authored_panels(scope, dashboard_id), to: Authored, as: :list_panels
  defdelegate create_authored_panel(scope, attrs), to: Authored, as: :create_panel
  defdelegate update_authored_panel(scope, panel, attrs), to: Authored, as: :update_panel
  defdelegate delete_authored_panel(scope, panel), to: Authored, as: :delete_panel

  defdelegate create_authored_report_schedule(scope, attrs),
    to: Authored,
    as: :create_report_schedule

  defdelegate list_authored_report_schedules(scope, dashboard_id),
    to: Authored,
    as: :list_report_schedules

  defdelegate update_authored_report_schedule(scope, schedule, attrs),
    to: Authored,
    as: :update_report_schedule

  defdelegate delete_authored_report_schedule(scope, schedule),
    to: Authored,
    as: :delete_report_schedule

  defdelegate list_authored_access_grants(scope, dashboard_id),
    to: Authored,
    as: :list_access_grants

  defdelegate grant_authored_dashboard_to_user(scope, attrs),
    to: Authored,
    as: :grant_dashboard_to_user

  defdelegate grant_authored_dashboard_to_group(scope, attrs),
    to: Authored,
    as: :grant_dashboard_to_group

  defdelegate revoke_authored_access_grant(scope, grant),
    to: Authored,
    as: :revoke_access_grant

  defdelegate list_user_groups(scope), to: Authored
  defdelegate list_user_group_memberships(scope, group_id \\ nil), to: Authored
  defdelegate create_user_group(scope, attrs), to: Authored
  defdelegate add_user_group_member(scope, attrs), to: Authored
  defdelegate list_share_principals(scope), to: Authored

  defdelegate preview_authored_query(scope, srql_query, opts \\ []),
    to: Authored,
    as: :preview_query

  defdelegate authored_visual_options(), to: Authored, as: :visual_options
  defdelegate enabled_package_instances(opts \\ []), to: Packages, as: :enabled_instances

  @doc """
  Returns SRQL-style dashboard discovery rows for `in:dashboards`.
  """
  @spec search_dashboard_rows(term(), String.t(), keyword()) :: [map()]
  def search_dashboard_rows(scope, query, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 100) |> normalize_limit()
    filters = dashboard_query_filters(query)

    authored =
      scope
      |> list_authored_dashboards(%{status: [:draft, :active], limit: 200})
      |> Enum.map(&authored_dashboard_row/1)

    packages =
      [scope: scope]
      |> enabled_package_instances()
      |> Enum.map(&package_dashboard_row/1)

    authored
    |> Kernel.++(packages)
    |> Enum.filter(&dashboard_row_matches?(&1, filters))
    |> Enum.sort_by(&{&1["is_default"] != true, String.downcase(&1["title"] || "")})
    |> Enum.take(limit)
  end

  @spec authored_dashboard_route_ref(map()) :: String.t()
  def authored_dashboard_route_ref(%{slug: slug}) when is_binary(slug) and slug != "", do: slug

  def authored_dashboard_route_ref(%{dashboard_ref: ref}) when is_integer(ref), do: Integer.to_string(ref)

  def authored_dashboard_route_ref(%{id: id}), do: to_string(id)
  def authored_dashboard_route_ref(_), do: ""

  defp authored_dashboard_row(dashboard) do
    route_ref = authored_dashboard_route_ref(dashboard)

    %{
      "type" => "authored",
      "id" => to_string(dashboard.id),
      "dashboard_ref" => route_ref,
      "slug" => dashboard.slug,
      "title" => dashboard.title,
      "description" => dashboard.description || "SRQL dashboard",
      "visibility" => to_string(dashboard.visibility),
      "status" => to_string(dashboard.status),
      "href" => "/dashboard/#{route_ref}",
      "updated_at" => dashboard.updated_at
    }
  end

  defp package_dashboard_row(instance) do
    package = instance.dashboard_package

    %{
      "type" => "package",
      "id" => instance.route_slug,
      "dashboard_ref" => instance.route_slug,
      "slug" => instance.route_slug,
      "title" => instance.name || package_name(package) || instance.route_slug,
      "description" => package_description(package),
      "visibility" => "package",
      "status" => if(instance.enabled, do: "active", else: "disabled"),
      "href" => "/dashboards/#{instance.route_slug}",
      "is_default" => instance.is_default,
      "updated_at" => instance.updated_at
    }
  end

  defp dashboard_row_matches?(row, filters) do
    Enum.all?(filters, fn
      {:title, value} ->
        fuzzy_match?(row["title"], value)

      {:description, value} ->
        fuzzy_match?(row["description"], value)

      {:slug, value} ->
        fuzzy_match?(row["slug"], value)

      {:dashboard_ref, value} ->
        fuzzy_match?(row["dashboard_ref"], value)

      {:id, value} ->
        fuzzy_match?(row["id"], value)

      {:type, value} ->
        fuzzy_match?(row["type"], value)

      {:status, value} ->
        fuzzy_match?(row["status"], value)

      {:text, value} ->
        fuzzy_match?(Enum.join([row["title"], row["description"], row["slug"]], " "), value)
    end)
  end

  defp dashboard_query_filters(query) when is_binary(query) do
    query
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&dashboard_control_token?/1)
    |> Enum.flat_map(&dashboard_query_filter/1)
  end

  defp dashboard_query_filters(_query), do: []

  defp dashboard_control_token?(token) do
    Enum.any?(~w(in: limit: sort: time: stats: rollup_stats: group_by:), &String.starts_with?(token, &1))
  end

  defp dashboard_query_filter("title:" <> value), do: [{:title, clean_srql_value(value)}]

  defp dashboard_query_filter("description:" <> value), do: [{:description, clean_srql_value(value)}]

  defp dashboard_query_filter("slug:" <> value), do: [{:slug, clean_srql_value(value)}]
  defp dashboard_query_filter("dashboard_ref:" <> value), do: [{:dashboard_ref, clean_srql_value(value)}]
  defp dashboard_query_filter("id:" <> value), do: [{:id, clean_srql_value(value)}]
  defp dashboard_query_filter("type:" <> value), do: [{:type, clean_srql_value(value)}]
  defp dashboard_query_filter("status:" <> value), do: [{:status, clean_srql_value(value)}]
  defp dashboard_query_filter(value), do: [{:text, clean_srql_value(value)}]

  defp clean_srql_value(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim("\"")
    |> String.trim("'")
    |> String.trim("%")
  end

  defp fuzzy_match?(_haystack, ""), do: true
  defp fuzzy_match?(nil, _needle), do: false

  defp fuzzy_match?(haystack, needle) do
    haystack
    |> to_string()
    |> String.downcase()
    |> String.contains?(String.downcase(to_string(needle)))
  end

  defp package_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp package_name(_package), do: nil

  defp package_description(%{description: description}) when is_binary(description) and description != "" do
    description
  end

  defp package_description(_package), do: "Signed dashboard package"

  defp normalize_limit(value) when is_integer(value), do: value |> max(1) |> min(500)

  defp normalize_limit(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {limit, ""} -> normalize_limit(limit)
      _ -> 100
    end
  end

  defp normalize_limit(_value), do: 100
end
