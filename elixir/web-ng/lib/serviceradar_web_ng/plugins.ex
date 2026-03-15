defmodule ServiceRadarWebNG.Plugins do
  @moduledoc """
  Context module for plugin registry, packages, and agent assignments.
  """

  use Boundary,
    deps: [ServiceRadarWebNG],
    exports: :all

  alias ServiceRadarWebNG.Plugins.Assignments
  alias ServiceRadarWebNG.Plugins.Packages
  alias ServiceRadarWebNG.Plugins.Registry

  defdelegate list_plugins(opts \\ []), to: Registry, as: :list
  defdelegate get_plugin(plugin_id, opts \\ []), to: Registry, as: :get
  defdelegate create_plugin(attrs, opts \\ []), to: Registry, as: :create
  defdelegate update_plugin(plugin_id, attrs, opts \\ []), to: Registry, as: :update

  defdelegate list_packages(filters \\ %{}, opts \\ []), to: Packages, as: :list
  defdelegate get_package(id, opts \\ []), to: Packages, as: :get
  defdelegate create_package(attrs, opts \\ []), to: Packages, as: :create
  defdelegate approve_package(id, attrs, opts \\ []), to: Packages, as: :approve
  defdelegate deny_package(id, attrs, opts \\ []), to: Packages, as: :deny
  defdelegate revoke_package(id, attrs, opts \\ []), to: Packages, as: :revoke
  defdelegate restage_package(id, opts \\ []), to: Packages, as: :restage

  defdelegate list_assignments(filters \\ %{}, opts \\ []), to: Assignments, as: :list
  defdelegate get_assignment(id, opts \\ []), to: Assignments, as: :get
  defdelegate create_assignment(attrs, opts \\ []), to: Assignments, as: :create
  defdelegate update_assignment(id, attrs, opts \\ []), to: Assignments, as: :update
  defdelegate delete_assignment(id, opts \\ []), to: Assignments, as: :delete
end
