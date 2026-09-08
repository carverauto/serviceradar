defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonProfileComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  # ---------------------------------------------------------------------------
  # Sysmon Profile Card (shown in Profiles tab)
  # ---------------------------------------------------------------------------

  attr(:profile_info, :map, required: true)
  attr(:available_profiles, :list, required: true)
  attr(:device_uid, :string, required: true)

  def sysmon_profile_card(assigns) do
    profile = Map.get(assigns.profile_info, :profile)
    source = Map.get(assigns.profile_info, :source, "unassigned")

    assigns =
      assigns
      |> assign(:profile, profile)
      |> assign(:source, source)

    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line flex items-center justify-between">
        <div class="flex items-center gap-2">
          <.icon name="hero-cog-6-tooth" class="size-4 text-sr-brand" />
          <span class="text-sm font-semibold">Host Health Profile</span>
        </div>
        <.source_badge source={@source} />
      </div>

      <div class="p-4">
        <div :if={@profile} class="space-y-4">
          <div class="flex items-center justify-between">
            <div>
              <div class="font-medium">{@profile.name}</div>
              <div class="text-xs text-sr-muted mt-0.5">
                Sample interval: <span class="font-mono">{@profile.sample_interval}</span>
              </div>
            </div>
          </div>

          <div :if={@profile.target_query && @source == "srql"} class="text-xs">
            <span class="text-sr-muted">Matched by SRQL:</span>
            <code class="font-mono bg-sr-subtle/50 px-1.5 py-0.5 rounded ml-1">
              {@profile.target_query}
            </code>
          </div>

          <div class="pt-2 border-t border-sr-line">
            <div class="text-xs text-sr-muted mb-2">Collection enabled:</div>
            <div class="flex flex-wrap gap-2">
              <.collection_badge enabled={@profile.collect_cpu} label="CPU" />
              <.collection_badge enabled={@profile.collect_memory} label="Memory" />
              <.collection_badge enabled={@profile.collect_disk} label="Disk" />
              <.collection_badge enabled={@profile.collect_network} label="Network" />
              <.collection_badge enabled={@profile.collect_processes} label="Processes" />
            </div>
          </div>
        </div>

        <div :if={is_nil(@profile)} class="text-sm text-sr-muted">
          No matching sysmon profile
        </div>

        <div class="text-xs text-sr-muted pt-3 border-t border-sr-line mt-4">
          <.link navigate="/settings/sysmon" class="text-sr-brand hover:underline">
            Manage sysmon profiles
          </.link>
        </div>
      </div>
    </div>
    """
  end

  attr(:enabled, :boolean, required: true)
  attr(:label, :string, required: true)

  defp collection_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 px-2 py-1 rounded text-xs",
      @enabled && "bg-success/10 text-success",
      not @enabled && "bg-sr-subtle text-sr-muted"
    ]}>
      <.icon :if={@enabled} name="hero-check" class="size-3" />
      <.icon :if={not @enabled} name="hero-x-mark" class="size-3" />
      {@label}
    </span>
    """
  end

  attr(:source, :string, required: true)

  defp source_badge(assigns) do
    {label, variant} =
      case assigns.source do
        "srql" -> {"SRQL Targeting", "primary"}
        "unassigned" -> {"Unassigned", "ghost"}
        "local" -> {"Local Override", "warning"}
        _ -> {"Unassigned", "ghost"}
      end

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="sm">{@label}</.ui_badge>
    """
  end
end
