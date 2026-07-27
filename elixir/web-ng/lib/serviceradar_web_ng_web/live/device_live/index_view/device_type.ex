defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.DeviceType do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  attr(:type, :string, default: nil)
  attr(:type_id, :integer, default: nil)

  def device_type_badge(assigns) do
    label = device_type_label(assigns.type, assigns.type_id)
    icon = device_type_icon(assigns.type, assigns.type_id)

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:icon, icon)

    ~H"""
    <div class="flex items-center gap-1.5" title={"Type ID: #{@type_id}"}>
      <.icon :if={@icon} name={@icon} class="size-3.5 text-sr-muted" />
      <span class="text-sr-ink/90">{@label}</span>
    </div>
    """
  end

  defp device_type_label(type, _type_id) when is_binary(type) and type != "" do
    case type |> String.trim() |> String.downcase() do
      "camera" -> "Camera"
      _ -> type
    end
  end

  defp device_type_label(_type, 0), do: "Unknown"
  defp device_type_label(_type, 1), do: "Server"
  defp device_type_label(_type, 2), do: "Desktop"
  defp device_type_label(_type, 3), do: "Laptop"
  defp device_type_label(_type, 4), do: "Tablet"
  defp device_type_label(_type, 5), do: "Mobile"
  defp device_type_label(_type, 6), do: "Virtual"
  defp device_type_label(_type, 7), do: "IOT"
  defp device_type_label(_type, 8), do: "Browser"
  defp device_type_label(_type, 9), do: "Firewall"
  defp device_type_label(_type, 10), do: "Switch"
  defp device_type_label(_type, 11), do: "Hub"
  defp device_type_label(_type, 12), do: "Router"
  defp device_type_label(_type, 13), do: "IDS"
  defp device_type_label(_type, 14), do: "IPS"
  defp device_type_label(_type, 15), do: "Load Balancer"
  defp device_type_label(_type, 99), do: "Other"
  defp device_type_label(_type, _type_id), do: "—"

  defp device_type_icon(type, type_id) when is_binary(type) do
    normalized = type |> String.downcase() |> String.trim()

    cond do
      normalized in ["camera", "ip camera", "security camera"] ->
        "hero-video-camera"

      normalized in ["access point", "access_point", "wireless ap", "wireless access point", "ap"] ->
        "hero-wifi"

      normalized in ["server"] ->
        "hero-server"

      normalized in ["router"] ->
        "hero-arrows-right-left"

      normalized in ["switch"] ->
        "hero-square-3-stack-3d"

      normalized in ["firewall"] ->
        "hero-shield-check"

      normalized in ["desktop"] ->
        "hero-computer-desktop"

      normalized in ["laptop"] ->
        "hero-computer-desktop"

      true ->
        device_type_icon(nil, type_id)
    end
  end

  defp device_type_icon(_type, 1), do: "hero-server"
  defp device_type_icon(_type, 2), do: "hero-computer-desktop"
  defp device_type_icon(_type, 3), do: "hero-computer-desktop"
  defp device_type_icon(_type, 4), do: "hero-device-tablet"
  defp device_type_icon(_type, 5), do: "hero-device-phone-mobile"
  defp device_type_icon(_type, 6), do: "hero-cube"
  defp device_type_icon(_type, 7), do: "hero-cpu-chip"
  defp device_type_icon(_type, 9), do: "hero-shield-check"
  defp device_type_icon(_type, 10), do: "hero-square-3-stack-3d"
  defp device_type_icon(_type, 12), do: "hero-arrows-right-left"
  defp device_type_icon(_type, 15), do: "hero-scale"
  defp device_type_icon(_type, _type_id), do: nil

  def display_model(nil), do: "—"

  def display_model(model) when is_binary(model) do
    trimmed = String.trim(model)

    if trimmed == "" or String.downcase(trimmed) == "nil" do
      "—"
    else
      trimmed
    end
  end

  def display_model(model), do: model |> to_string() |> display_model()

  defp row_metadata(row) when is_map(row) do
    case Map.get(row, "metadata") || Map.get(row, :metadata) do
      metadata when is_map(metadata) -> metadata
      _ -> %{}
    end
  end

  defp metadata_value(row, key) when is_binary(key) do
    row
    |> row_metadata()
    |> Map.get(key)
  end

  def device_type_value(row) when is_map(row) do
    Map.get(row, "type") ||
      Map.get(row, "device_type") ||
      metadata_value(row, "armis_type") ||
      metadata_value(row, "device_type") ||
      metadata_value(row, "type") ||
      metadata_value(row, "armis_category") ||
      metadata_value(row, "category")
  end

  def device_type_value(_row), do: nil

  def snmp_fallback_derived?(row) when is_map(row) do
    metadata = row_metadata(row)

    classification_source =
      row
      |> metadata_value("classification_source")
      |> normalize_meta_text()

    has_rule = present_text?(metadata_value(row, "classification_rule_id"))

    has_display_values =
      present_text?(device_type_value(row)) or present_text?(Map.get(row, "vendor_name")) or
        display_model(Map.get(row, "model")) != "—"

    has_snmp_evidence = snmp_evidence_present?(metadata)

    cond do
      classification_source in ["snmp_fallback", "snmp_fingerprint_fallback"] ->
        true

      has_rule ->
        false

      true ->
        has_display_values and has_snmp_evidence
    end
  end

  defp snmp_evidence_present?(metadata) when is_map(metadata) do
    is_map(Map.get(metadata, "snmp_fingerprint")) or
      present_text?(Map.get(metadata, "sys_object_id")) or
      present_text?(Map.get(metadata, "sys_descr")) or
      present_text?(Map.get(metadata, "sys_name")) or
      present_text?(Map.get(metadata, "snmp_description")) or
      present_text?(Map.get(metadata, "snmp_name")) or
      present_text?(Map.get(metadata, "ip_forwarding"))
  end

  defp normalize_meta_text(nil), do: ""

  defp normalize_meta_text(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  def present_text?(value) when is_binary(value), do: String.trim(value) != ""
  def present_text?(_value), do: false
end
