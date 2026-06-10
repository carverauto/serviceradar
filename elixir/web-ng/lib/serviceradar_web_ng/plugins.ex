defmodule ServiceRadarWebNG.Plugins do
  @moduledoc """
  Context module for plugin registry, packages, and agent assignments.
  """

  use Boundary,
    top_level?: true,
    deps: [ServiceRadarWebNG, ServiceRadarWebNG.Web],
    exports: :all

  alias ServiceRadarWebNG.Plugins.AddonAssignments
  alias ServiceRadarWebNG.Plugins.AddonPackages
  alias ServiceRadarWebNG.Plugins.AddonProfiles
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
  defdelegate sync_first_party_packages(opts \\ []), to: Packages, as: :sync_first_party_plugins

  defdelegate list_assignments(filters \\ %{}, opts \\ []), to: Assignments, as: :list
  defdelegate get_assignment(id, opts \\ []), to: Assignments, as: :get
  defdelegate create_assignment(attrs, opts \\ []), to: Assignments, as: :create
  defdelegate update_assignment(id, attrs, opts \\ []), to: Assignments, as: :update
  defdelegate delete_assignment(id, opts \\ []), to: Assignments, as: :delete

  defdelegate list_addon_packages(filters \\ %{}, opts \\ []), to: AddonPackages, as: :list
  defdelegate list_approved_addon_packages(opts \\ []), to: AddonPackages, as: :list_approved
  defdelegate get_addon_package(id, opts \\ []), to: AddonPackages, as: :get
  defdelegate list_addon_assignments(filters \\ %{}, opts \\ []), to: AddonAssignments, as: :list
  defdelegate create_addon_assignment(attrs, opts \\ []), to: AddonAssignments, as: :create
  defdelegate delete_addon_assignment(id, opts \\ []), to: AddonAssignments, as: :delete
  defdelegate list_addon_profiles(filters \\ %{}, opts \\ []), to: AddonProfiles, as: :list
  defdelegate create_addon_profile(attrs, opts \\ []), to: AddonProfiles, as: :create
  defdelegate preview_addon_profile(id, opts \\ []), to: AddonProfiles, as: :preview
  defdelegate reconcile_addon_profile(id, opts \\ []), to: AddonProfiles, as: :reconcile
end
