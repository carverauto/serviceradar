defmodule ServiceRadarWebNG.Dashboards do
  @moduledoc """
  Context module for browser-hosted dashboard packages.
  """

  use Boundary,
    top_level?: true,
    deps: [ServiceRadarWebNG, ServiceRadarWebNG.Plugins],
    exports: :all

  alias ServiceRadarWebNG.Dashboards.Authored
  alias ServiceRadarWebNG.Dashboards.Packages

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

  defdelegate list_authored_dashboards(scope, filters \\ %{}), to: Authored, as: :list_dashboards
  defdelegate get_authored_dashboard(scope, id, opts \\ []), to: Authored, as: :get_dashboard
  defdelegate create_authored_dashboard(scope, attrs), to: Authored, as: :create_dashboard
  defdelegate update_authored_dashboard(scope, dashboard, attrs), to: Authored, as: :update_dashboard
  defdelegate archive_authored_dashboard(scope, dashboard), to: Authored, as: :archive_dashboard
  defdelegate list_authored_panels(scope, dashboard_id), to: Authored, as: :list_panels
  defdelegate create_authored_panel(scope, attrs), to: Authored, as: :create_panel
  defdelegate update_authored_panel(scope, panel, attrs), to: Authored, as: :update_panel
  defdelegate delete_authored_panel(scope, panel), to: Authored, as: :delete_panel
  defdelegate preview_authored_query(scope, srql_query, opts \\ []), to: Authored, as: :preview_query
  defdelegate authored_visual_options(), to: Authored, as: :visual_options
end
