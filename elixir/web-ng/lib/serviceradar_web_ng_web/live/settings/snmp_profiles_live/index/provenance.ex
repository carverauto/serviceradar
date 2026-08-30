defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Provenance do
  @moduledoc """
  Says who contributed a profile or OID template, where the operator sees it.

  Configuration that appears in an operator's list with no explanation of where
  it came from is exactly the buried-backend-state problem plugin-declared SNMP
  requirements exist to avoid, so recording provenance in a column nothing
  renders would not satisfy the requirement.

  Two independent signals are read, because each survives a loss the other does
  not:

    * `plugin_package_id` survives an operator renaming the row, but is set to
      NULL when the package is deleted (`on_delete: :nilify_all`).
    * The `"plugin:<package>:<entry>"` name `SNMPRequirementCatalog` writes
      survives package deletion, but not a rename.

  Reading only the id is how a plugin-contributed row silently reverts to
  looking operator-authored the moment its package is removed.
  """

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadar.Plugins.PluginPackage

  require Ash.Query

  @type provenance :: :none | {:plugin, String.t()} | {:plugin_removed, String.t() | nil}

  @doc """
  Maps every plugin package id referenced by `rows` to its display name.

  One query for the whole list rather than a load per row, and none at all when
  no row carries a package.
  """
  @spec load_package_names(map(), [map()]) :: %{optional(String.t()) => String.t()}
  def load_package_names(scope, rows) when is_list(rows) do
    ids =
      rows
      |> Enum.map(&Map.get(&1, :plugin_package_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if ids == [] do
      %{}
    else
      PluginPackage
      |> Ash.Query.filter(id in ^ids)
      |> Ash.read(scope: scope)
      |> case do
        {:ok, packages} -> Map.new(packages, &{&1.id, &1.name})
        {:error, _reason} -> %{}
      end
    end
  end

  def load_package_names(_scope, _rows), do: %{}

  @doc "Classifies one row against the package names loaded for its list."
  @spec describe(map(), map()) :: provenance()
  def describe(row, package_names) do
    case Map.get(row, :plugin_package_id) do
      nil ->
        case package_from_name(Map.get(row, :name)) do
          nil -> :none
          package -> {:plugin_removed, package}
        end

      id ->
        case Map.get(package_names, id) do
          # An id that resolves to no package means the row still points at
          # something the reader cannot see, so it is reported as removed rather
          # than as unattributed.
          nil -> {:plugin_removed, package_from_name(Map.get(row, :name))}
          package -> {:plugin, package}
        end
    end
  end

  # Only reached once a package is already gone, since a live package row is
  # always preferred. `parts: 2` keeps any colon in the entry name where it
  # belongs rather than truncating the package.
  defp package_from_name("plugin:" <> rest) when is_binary(rest) do
    case String.split(rest, ":", parts: 2) do
      [package, _entry] when package != "" -> package
      _other -> nil
    end
  end

  defp package_from_name(_name), do: nil

  attr :id, :string, required: true
  attr :row, :map, required: true
  attr :package_names, :map, default: %{}

  def provenance_badge(assigns) do
    assigns = assign(assigns, :provenance, describe(assigns.row, assigns.package_names))

    ~H"""
    <%= case @provenance do %>
      <% {:plugin, package} -> %>
        <.ui_badge
          id={@id}
          variant="info"
          size="xs"
          title={"Contributed by the plugin package #{package}"}
        >
          Plugin: {package}
        </.ui_badge>
      <% {:plugin_removed, nil} -> %>
        <.ui_badge
          id={@id}
          variant="warning"
          size="xs"
          title="Contributed by a plugin package that has since been removed"
        >
          Plugin (package removed)
        </.ui_badge>
      <% {:plugin_removed, package} -> %>
        <.ui_badge
          id={@id}
          variant="warning"
          size="xs"
          title={"Contributed by the plugin package #{package}, which has since been removed"}
        >
          Plugin: {package} (removed)
        </.ui_badge>
      <% :none -> %>
    <% end %>
    """
  end
end
