defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.Badges do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.UIComponents

  attr(:available, :any, default: nil)

  def availability_badge(assigns) do
    {label, variant} =
      case assigns.available do
        true -> {"Online", "success"}
        false -> {"Offline", "error"}
        _ -> {"Unknown", "ghost"}
      end

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  attr(:risk_level, :string, default: nil)

  def risk_level_badge(assigns) do
    {label, variant} = risk_level_style(assigns.risk_level)

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:variant, variant)

    ~H"""
    <.ui_badge :if={@label != "—"} variant={@variant} size="xs">{@label}</.ui_badge>
    <span :if={@label == "—"} class="text-sr-muted">—</span>
    """
  end

  defp risk_level_style("Critical"), do: {"Critical", "error"}
  defp risk_level_style("High"), do: {"High", "warning"}
  defp risk_level_style("Medium"), do: {"Medium", "info"}
  defp risk_level_style("Low"), do: {"Low", "success"}
  defp risk_level_style("Info"), do: {"Info", "ghost"}
  defp risk_level_style(_), do: {"—", "ghost"}

  attr(:device_uid, :string, default: nil)
  attr(:has_snmp, :boolean, default: false)
  attr(:has_sysmon, :boolean, default: false)

  def metrics_presence(assigns) do
    device_path =
      if is_binary(assigns.device_uid) and String.trim(assigns.device_uid) != "" do
        ~p"/devices/#{assigns.device_uid}"
      end

    assigns = assign(assigns, :device_path, device_path)

    ~H"""
    <div :if={@has_snmp or @has_sysmon} class="flex items-center gap-2">
      <.link
        :if={@has_snmp and is_binary(@device_path)}
        navigate={@device_path}
        class="sr-ui-tooltip inline-flex hover:opacity-90"
        data-tip="SNMP metrics available (last 24h)"
        aria-label="View device details (SNMP metrics available)"
      >
        <.icon name="hero-chart-bar" class="size-4 text-info" />
      </.link>
      <span
        :if={@has_snmp and not is_binary(@device_path)}
        class="sr-ui-tooltip"
        data-tip="SNMP metrics available (last 24h)"
      >
        <.icon name="hero-chart-bar" class="size-4 text-info" />
      </span>

      <.link
        :if={@has_sysmon and is_binary(@device_path)}
        navigate={@device_path}
        class="sr-ui-tooltip inline-flex hover:opacity-90"
        data-tip="Host Health metrics available (last 24h)"
        aria-label="View device details (Host Health metrics available)"
      >
        <.icon name="hero-cpu-chip" class="size-4 text-success" />
      </.link>
      <span
        :if={@has_sysmon and not is_binary(@device_path)}
        class="sr-ui-tooltip"
        data-tip="Host Health metrics available (last 24h)"
      >
        <.icon name="hero-cpu-chip" class="size-4 text-success" />
      </span>
    </div>
    <span :if={not @has_snmp and not @has_sysmon} class="text-sr-muted">—</span>
    """
  end

  attr(:profile, :any, default: nil)

  def sysmon_profile_badge(assigns) do
    profile_name = sysmon_profile_label(assigns.profile)

    {label, source} =
      if is_binary(profile_name) do
        {profile_name, :direct}
      else
        {"Unassigned", :missing}
      end

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:source, source)

    ~H"""
    <div class="flex items-center gap-1">
      <span
        data-testid="sysmon-profile-label"
        class={[
          "text-xs truncate max-w-[8rem]",
          if(@source == :direct, do: "font-medium text-sr-ink", else: "text-sr-muted")
        ]}
      >
        {@label}
      </span>
    </div>
    """
  end

  defp sysmon_profile_label(profile) when is_map(profile) do
    with name when is_binary(name) <- Map.get(profile, :name) || Map.get(profile, "name"),
         trimmed_name = String.trim(name),
         true <- trimmed_name != "" do
      trimmed_name
    else
      _ -> nil
    end
  end

  defp sysmon_profile_label(_), do: nil
end
