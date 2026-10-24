defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.Badges do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNG.Devices.MergedAvailability
  alias ServiceRadarWebNGWeb.DeviceLive.IndexPath

  attr(:id, :string, required: true)
  attr(:availability, :map, default: nil)
  attr(:now, :any, default: nil, doc: "the time the decision's age is measured from")

  @doc """
  The device's canonical availability (Online, Offline or Unknown) with its per-agent
  reachability: "up from N of M agents", a partial-reachability marker when any fresh
  non-control agent cannot reach the device, and the negative-control indicators. The
  tooltip names the deciding source, the decision time and each agent's latest result.
  `nil` availability (still loading) renders a placeholder, never a state.
  """
  def availability_badge(assigns) do
    availability = assigns.availability

    assigns =
      assigns
      |> assign(:state, availability && availability.state)
      |> assign(:reachability, availability && MergedAvailability.reachability(availability))
      |> assign(:tooltip, availability && availability_tooltip(availability, assigns.now || DateTime.utc_now()))

    ~H"""
    <span :if={is_nil(@state)} id={@id} class="text-sr-muted">—</span>
    <div
      :if={@state}
      id={@id}
      class="flex flex-col items-start gap-0.5"
      data-availability-state={@state}
    >
      <span class="sr-ui-tooltip inline-flex" data-availability-badge data-tip={@tooltip}>
        <.ui_badge variant={availability_variant(@state)} size="xs">
          {availability_label(@state)}
        </.ui_badge>
      </span>
      <span
        :if={@reachability && @reachability.total > 0}
        class="inline-flex items-center gap-1 text-[0.65rem] leading-4 text-sr-muted"
        data-agent-reachability={"#{@reachability.up}/#{@reachability.total}"}
      >
        up from {@reachability.up} of {@reachability.total} {agent_noun(@reachability.total)}
        <span
          :if={@reachability.partial?}
          class="sr-ui-tooltip inline-flex text-warning"
          data-partial-reachability
          data-tip={"Unreachable from #{@reachability.down} #{agent_noun(@reachability.down)}"}
        >
          <.icon name="hero-exclamation-triangle" class="size-3" />
        </span>
      </span>
      <span
        :if={@reachability && @reachability.blocked_verified > 0}
        class="text-[0.65rem] leading-4 text-success"
        data-negative-control="verified"
      >
        blocked as expected ({@reachability.blocked_verified})
      </span>
      <span
        :if={@reachability && @reachability.policy_violation > 0}
        class="text-[0.65rem] font-semibold leading-4 text-error"
        data-negative-control="violation"
      >
        POLICY VIOLATION: reachable from {@reachability.policy_violation} {agent_noun(
          @reachability.policy_violation
        )} that should be blocked
      </span>
    </div>
    """
  end

  defp availability_label(:available), do: "Online"
  defp availability_label(:unavailable), do: "Offline"
  defp availability_label(:unknown), do: "Unknown"

  defp availability_variant(:available), do: "success"
  defp availability_variant(:unavailable), do: "error"
  defp availability_variant(:unknown), do: "ghost"

  defp agent_noun(1), do: "agent"
  defp agent_noun(_count), do: "agents"

  defp availability_tooltip(availability, now) do
    Enum.join(
      [decision_text(availability, now) | agent_result_texts(Map.get(availability, :agent_results, []))],
      " · "
    )
  end

  defp decision_text(%{state: :unknown} = availability, now) do
    "No fresh availability evidence" <> since_text(availability.changed_at, now)
  end

  defp decision_text(availability, now) do
    decided_by = availability.decided_by || %{}

    source =
      [decided_by["source_kind"], decided_by["authority_class"] && "(#{decided_by["authority_class"]})"]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")

    reporter = decided_by["reporter_agent_id"]
    via = if blank?(reporter), do: "", else: " via #{reporter}"
    source = if source == "", do: "an unrecorded source", else: source

    "Decided by #{source}#{via}" <> since_text(availability.changed_at, now) <> conflict_text(availability)
  end

  # The decision's age, so the tooltip needs no timezone.
  defp since_text(%DateTime{} = at, now) do
    seconds = max(DateTime.diff(now, at), 0)

    age =
      cond do
        seconds < 60 -> "#{seconds}s"
        seconds < 3_600 -> "#{div(seconds, 60)}m"
        seconds < 86_400 -> "#{div(seconds, 3_600)}h"
        true -> "#{div(seconds, 86_400)}d"
      end

    ", #{age} ago"
  end

  defp since_text(_at, _now), do: ""

  defp conflict_text(%{conflict: true}), do: "; other evidence disagrees"
  defp conflict_text(_availability), do: ""

  defp agent_result_texts(results) when is_list(results) do
    Enum.map(results, fn result ->
      label = if blank?(result.agent_name), do: result.agent_id, else: result.agent_name
      "#{label}: #{if result.available?, do: "up", else: "down"}"
    end)
  end

  defp agent_result_texts(_results), do: []

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

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
  attr(:return_to, :string, default: "/devices")

  def metrics_presence(assigns) do
    device_uid = assigns.device_uid
    return_to = assigns.return_to

    {interfaces_path, profiles_path} =
      if is_binary(device_uid) and String.trim(device_uid) != "" do
        {
          IndexPath.show_path(device_uid,
            tab: "interfaces",
            return_to: return_to
          ),
          IndexPath.show_path(device_uid,
            tab: "profiles",
            return_to: return_to
          )
        }
      else
        {nil, nil}
      end

    assigns =
      assigns
      |> assign(:interfaces_path, interfaces_path)
      |> assign(:profiles_path, profiles_path)

    ~H"""
    <div :if={@has_snmp or @has_sysmon} class="flex items-center gap-2">
      <.link
        :if={@has_snmp and is_binary(@interfaces_path)}
        navigate={@interfaces_path}
        class="sr-ui-tooltip inline-flex hover:opacity-90"
        data-tip="SNMP metrics available (last 24h)"
        aria-label="View device interfaces (SNMP metrics available)"
      >
        <.icon name="hero-chart-bar" class="size-4 text-info" />
      </.link>
      <span
        :if={@has_snmp and not is_binary(@interfaces_path)}
        class="sr-ui-tooltip"
        data-tip="SNMP metrics available (last 24h)"
      >
        <.icon name="hero-chart-bar" class="size-4 text-info" />
      </span>

      <.link
        :if={@has_sysmon and is_binary(@profiles_path)}
        navigate={@profiles_path}
        class="sr-ui-tooltip inline-flex hover:opacity-90"
        data-tip="Host Health metrics available (last 24h)"
        aria-label="View device details (Host Health metrics available)"
      >
        <.icon name="hero-cpu-chip" class="size-4 text-success" />
      </.link>
      <span
        :if={@has_sysmon and not is_binary(@profiles_path)}
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
