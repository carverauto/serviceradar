defmodule ServiceRadar.Plugins.RetiredNativeAddons do
  @moduledoc """
  Central registry for first-party native add-ons that should no longer be
  imported, assigned, or emitted into agent config.
  """

  @retired %{
    "advisory-producer" =>
      "advisory feed production is now owned by core/web-ng, not an agent add-on",
    "endpoint-inventory" => "endpoint-inventory is superseded by scalibr-endpoint-inventory"
  }

  @spec retired?(term()) :: boolean()
  def retired?(addon_id) when is_binary(addon_id), do: Map.has_key?(@retired, addon_id)
  def retired?(_addon_id), do: false

  @spec reason(term()) :: String.t() | nil
  def reason(addon_id) when is_binary(addon_id), do: Map.get(@retired, addon_id)
  def reason(_addon_id), do: nil

  @spec ids() :: [String.t()]
  def ids, do: Map.keys(@retired)
end
