defmodule ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View.TraceTable do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View.Helpers

  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Config

  attr(:traces, :list, required: true)
  attr(:pending_jobs, :list, required: true)
  attr(:filter_target, :string, required: true)
  attr(:filter_agent, :string, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  def render(assigns) do
    ~H"""
    <form phx-change="filter" class="flex flex-col gap-3 sm:flex-row">
      <input
        type="text"
        name="target"
        value={@filter_target}
        placeholder="Filter by target..."
        class={ui_field_class(size: "sm", class: "w-full sm:w-48")}
        phx-debounce="300"
      />
      <input
        type="text"
        name="agent"
        value={@filter_agent}
        placeholder="Filter by agent..."
        class={ui_field_class(size: "sm", class: "w-full sm:w-48")}
        phx-debounce="300"
      />
    </form>

    <div class="sr-ui-table-shell">
      <table class={ui_table_class(size: "sm", class: "sr-mtr-table")}>
        <thead>
          <tr>
            <th>Time</th>
            <th>Target</th>
            <th>Status</th>
            <th>Hops</th>
            <th>Protocol</th>
            <th>Agent</th>
            <th>Check</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <.pending_rows pending_jobs={@pending_jobs} timezone={@timezone} />
          <.trace_rows traces={@traces} timezone={@timezone} />
          <tr :if={@pending_jobs == [] and @traces == []}>
            <td colspan="8" class="text-center py-8 sr-mtr-muted">
              No MTR traces found. Traces will appear once agents run MTR checks.
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr(:pending_jobs, :list, required: true)
  attr(:timezone, :string, required: true)

  defp pending_rows(assigns) do
    ~H"""
    <tr :for={job <- @pending_jobs} class="hover opacity-80">
      <td class="whitespace-nowrap text-xs">
        <.user_time
          id={"mtr-pending-job-#{job.id}-inserted-at"}
          value={job.inserted_at}
          timezone={@timezone}
          style={:compact}
          fallback="-"
        />
      </td>
      <td>
        <div class="font-mono text-sm">{job.payload[Config.payload_target_key()] || "-"}</div>
      </td>
      <td>
        <.ui_badge
          size="sm"
          variant={pending_status_variant(job.status)}
          class="w-28 justify-center"
        >
          {job.status |> to_string() |> String.replace("_", " ") |> String.upcase()}
        </.ui_badge>
      </td>
      <td class="text-center">-</td>
      <td>
        <.ui_badge size="sm" variant="ghost">
          {String.upcase(
            (job.payload || %{})[Config.payload_protocol_key()] || Config.protocol_icmp()
          )}
        </.ui_badge>
      </td>
      <td class="text-xs font-mono max-w-[120px] truncate" title={job.agent_id}>{job.agent_id}</td>
      <td class="text-xs max-w-[120px] truncate" title={job.command_type}>pending</td>
      <td class="text-xs sr-mtr-muted">{job.id}</td>
    </tr>
    """
  end

  attr(:traces, :list, required: true)
  attr(:timezone, :string, required: true)

  defp trace_rows(assigns) do
    ~H"""
    <tr :for={{trace, trace_index} <- Enum.with_index(@traces)} class="hover">
      <td class="whitespace-nowrap text-xs">
        <.user_time
          id={"mtr-trace-#{trace_identity(trace, trace_index)}-time"}
          value={trace["time"]}
          timezone={@timezone}
          style={:compact}
          fallback="-"
        />
      </td>
      <td>
        <div class="font-mono text-sm">{trace[Config.payload_target_key()]}</div>
        <div
          :if={trace[Config.payload_target_ip_key()] != trace[Config.payload_target_key()]}
          class="text-xs sr-mtr-muted"
        >
          {trace[Config.payload_target_ip_key()]}
        </div>
      </td>
      <td>
        <.ui_badge
          size="sm"
          variant={trace_status_variant(trace)}
          class="w-32 justify-center"
        >
          {trace_status_label(trace)}
        </.ui_badge>
      </td>
      <td class="text-center">{trace["total_hops"]}</td>
      <td>
        <.ui_badge size="sm" variant="ghost">
          {String.upcase(trace[Config.payload_protocol_key()] || Config.protocol_icmp())}
        </.ui_badge>
        <.ui_badge
          :if={trace[Config.payload_ip_version_key()] == 6}
          size="sm"
          variant="info"
          class="ml-1"
        >
          IPv6
        </.ui_badge>
      </td>
      <td
        class="text-xs font-mono max-w-[120px] truncate"
        title={trace[Config.payload_agent_id_key()]}
      >
        {trace[Config.payload_agent_id_key()]}
      </td>
      <td class="text-xs max-w-[120px] truncate" title={trace[Config.payload_check_name_key()]}>
        {trace[Config.payload_check_name_key()] || "-"}
      </td>
      <td class="flex items-center gap-1">
        <.ui_button
          type="button"
          phx-click="run_again"
          phx-value-target={trace[Config.payload_target_key()] || ""}
          phx-value-agent_id={trace[Config.payload_agent_id_key()] || ""}
          phx-value-protocol={trace[Config.payload_protocol_key()] || Config.protocol_icmp()}
          title="Run again"
          aria-label="Run MTR trace again"
          size="xs"
          variant="ghost"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="h-3.5 w-3.5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M4 4v6h6M20 20v-6h-6M20 9A8 8 0 006.34 5.34L4 8m16 8l-2.34 2.66A8 8 0 013.99 15"
            />
          </svg>
        </.ui_button>
        <.ui_button navigate={~p"/diagnostics/mtr/#{trace["id"]}"} size="xs" variant="ghost">
          View
        </.ui_button>
      </td>
    </tr>
    """
  end

  defp trace_identity(trace, index) do
    Enum.find(
      [Map.get(trace, "id"), Map.get(trace, "trace_id"), Map.get(trace, :id), Map.get(trace, :trace_id)],
      index,
      &(&1 not in [nil, ""])
    )
  end
end
