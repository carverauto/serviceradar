defmodule ServiceRadarWebNG.Plugins.AddonRuntimePolicy do
  @moduledoc """
  Shared presentation policy for desired and observed native add-on runtimes.

  Required add-ons are delivered by the agent config generator without an
  `AddonAssignment` row. The UI must distinguish that platform-managed state
  from an unmanaged runtime.
  """

  alias ServiceRadar.Plugins.RetiredNativeAddons

  @default_required_addon_ids ["otel-collector"]

  @type management_mode :: :assignment | :required | :observed

  @spec management_mode(term(), boolean()) :: management_mode()
  def management_mode(_addon_id, true), do: :assignment

  def management_mode(addon_id, false) do
    if required?(addon_id), do: :required, else: :observed
  end

  @spec required?(term()) :: boolean()
  def required?(addon_id) when is_binary(addon_id) do
    addon_id in required_addon_ids()
  end

  def required?(_addon_id), do: false

  @spec required_addon_ids() :: [String.t()]
  def required_addon_ids do
    :serviceradar_core
    |> Application.get_env(:required_agent_addons, @default_required_addon_ids)
    |> List.wrap()
    |> Enum.map(&required_addon_id/1)
    |> Enum.reject(&(is_nil(&1) or RetiredNativeAddons.retired?(&1)))
    |> Enum.uniq()
  end

  @spec resource_limit_warning?(term()) :: boolean()
  def resource_limit_warning?(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> String.downcase()
    |> String.starts_with?("resource limits not enforced:")
  end

  def resource_limit_warning?(_reason), do: false

  defp required_addon_id(addon_id) when is_binary(addon_id), do: present(addon_id)

  defp required_addon_id(spec) when is_map(spec) do
    spec
    |> then(&(Map.get(&1, :addon_id) || Map.get(&1, "addon_id")))
    |> required_addon_id()
  end

  defp required_addon_id(_spec), do: nil

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end
end
