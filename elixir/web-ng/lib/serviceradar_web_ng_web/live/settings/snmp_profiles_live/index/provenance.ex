defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Provenance do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  @no_credential_warning "This profile has no SNMP credential bound. It will compile to zero targets until you bind one."

  def no_credential_warning, do: @no_credential_warning

  def credential_bound?(nil), do: false

  def credential_bound?(record) when is_map(record) do
    present?(Map.get(record, :credential_secret_id)) or
      present?(Map.get(record, :community_encrypted)) or
      present?(Map.get(record, :username))
  end

  def plugin_contributed?(record) when is_map(record) do
    truthy?(Map.get(record, :plugin_contributed) || Map.get(record, "plugin_contributed"))
  end

  def plugin_contributed?(_record), do: false

  def plugin_label(record) do
    cond do
      not plugin_contributed?(record) ->
        nil

      is_nil(package_id(record)) ->
        "Plugin (removed)"

      true ->
        case package_name(record) do
          nil -> "Plugin"
          name -> "Plugin · #{name}"
        end
    end
  end

  def plugin_badge_variant(record) do
    if plugin_contributed?(record) and is_nil(package_id(record)), do: "warning", else: "info"
  end

  attr :record, :map, required: true
  attr :id, :string, default: nil

  def plugin_badge(assigns) do
    label = plugin_label(assigns.record)

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:variant, plugin_badge_variant(assigns.record))

    ~H"""
    <.ui_badge :if={@label} id={@id} variant={@variant} size="xs" title={@label}>
      {@label}
    </.ui_badge>
    """
  end

  defp package_id(record) do
    case Map.get(record, :plugin_package_id) || Map.get(record, "plugin_package_id") do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp package_name(%{plugin_package: %{name: name}}) when is_binary(name) and name != "", do: name

  defp package_name(record) when is_map(record) do
    case Map.get(record, :plugin_package_name) || Map.get(record, "plugin_package_name") do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp present?(nil), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: true

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false
end
