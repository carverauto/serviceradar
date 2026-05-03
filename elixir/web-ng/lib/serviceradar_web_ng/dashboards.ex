defmodule ServiceRadarWebNG.Dashboards do
  @moduledoc """
  Context module for browser-hosted dashboard packages.
  """

  use Boundary,
    top_level?: true,
    deps: [ServiceRadarWebNG, ServiceRadarWebNG.Plugins],
    exports: :all

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
end
