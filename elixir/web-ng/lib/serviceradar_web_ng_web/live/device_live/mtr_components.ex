defmodule ServiceRadarWebNGWeb.DeviceLive.MtrComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.SRQLComponents, only: [srql_sparkline: 1]

  attr(:device_uid, :string, required: true)
  attr(:fallback_target, :string, default: nil)
  attr(:traces, :list, default: [])
  attr(:recent_traces, :list, default: [])
  attr(:pending_jobs, :list, default: [])
  attr(:trends, :map, default: %{hops: [], latency: []})
  attr(:total_count, :integer, default: 0)
  attr(:coverage, :map, default: %{trace_count: 0, earliest_time: nil, latest_time: nil})
  attr(:retention_status, :map, default: %{configured_days: 30, status: :degraded, tables: %{}})
  attr(:page, :integer, default: 1)
  attr(:page_size, :integer, default: 50)
  attr(:timezone, :string, default: "Etc/UTC")

  def mtr_tab_content(assigns) do
    dashboard = mtr_trace_dashboard(assigns.recent_traces, assigns.pending_jobs)
    recent_trace_bars = recent_mtr_trace_bars(assigns.recent_traces)

    assigns =
      assigns
      |> assign(:mtr_dashboard, dashboard)
      |> assign(:recent_trace_bars, recent_trace_bars)

    ~H"""
    <div class="space-y-4">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <h3 class="text-lg font-semibold">MTR Traces</h3>
        <div class="flex flex-wrap gap-2 sm:justify-end">
          <.ui_button type="button" phx-click="run_mtr" size="sm" variant="primary">
            <.icon name="hero-bolt" class="size-4" /> Queue MTR
          </.ui_button>
          <.ui_button navigate={~p"/diagnostics/mtr"} size="sm" variant="ghost">
            View All
          </.ui_button>
        </div>
      </div>

      <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-4 min-[1800px]:grid-cols-8">
        <div class="sr-mtr-card p-4">
          <div class="sr-mtr-label">Pending Jobs</div>
          <div class="sr-mtr-value mt-2 text-3xl">{@mtr_dashboard.pending_count}</div>
        </div>
        <div id="device-mtr-reachability" class="sr-mtr-card p-4">
          <div class="flex items-center justify-between gap-4">
            <div class="min-w-0">
              <div class="sr-mtr-label">Reachability</div>
              <div class="sr-mtr-value mt-2 text-3xl">{@mtr_dashboard.success_rate}%</div>
              <div class="sr-mtr-muted text-sm">recent traces reached target</div>
            </div>
            <div
              class={[
                "radial-progress sr-mtr-radial shrink-0 text-sm font-semibold",
                mtr_reachability_tone(@mtr_dashboard.success_rate)
              ]}
              style={"--value: #{mtr_radial_value(@mtr_dashboard.success_rate)};"}
              role="progressbar"
              aria-label="MTR reachability"
            >
              {mtr_radial_value(@mtr_dashboard.success_rate)}%
            </div>
          </div>
        </div>
        <div class="sr-mtr-card p-4">
          <div class="sr-mtr-label">
            Avg Hop Depth
          </div>
          <div class="sr-mtr-value mt-2 text-3xl">{@mtr_dashboard.avg_hops}</div>
        </div>
        <div id="device-mtr-destination-latency" class="sr-mtr-card p-4">
          <div class="sr-mtr-label">
            Destination Latency
          </div>
          <div class="sr-mtr-value mt-2 text-3xl">{@mtr_dashboard.avg_latency_label}</div>
        </div>
        <div id="device-mtr-destination-loss" class="sr-mtr-card p-4">
          <div class="sr-mtr-label">Destination Loss</div>
          <div class={[
            "mt-2 text-3xl font-semibold tabular-nums",
            loss_class_for_modal(@mtr_dashboard.destination_loss_pct)
          ]}>
            {format_pct_mtr(@mtr_dashboard.destination_loss_pct)}
          </div>
        </div>
        <div class="sr-mtr-card p-4">
          <div class="sr-mtr-label">Endpoint Samples</div>
          <div class="sr-mtr-value mt-2 text-3xl">{@mtr_dashboard.endpoint_sample_count}</div>
          <div class="sr-mtr-muted text-sm">destination observations</div>
        </div>
        <div class="sr-mtr-card p-4">
          <div class="sr-mtr-label">
            Retained Matches
          </div>
          <div class="sr-mtr-value mt-2 text-3xl">{@total_count}</div>
          <div class="sr-mtr-muted text-sm">
            <%= if Map.get(@coverage, :earliest_time) do %>
              <.user_time
                id="device-mtr-coverage-earliest-time"
                value={Map.get(@coverage, :earliest_time)}
                timezone={@timezone}
                style={:date}
              /> to
              <.user_time
                id="device-mtr-coverage-latest-time"
                value={Map.get(@coverage, :latest_time)}
                timezone={@timezone}
                style={:date}
              />
            <% else %>
              no retained history
            <% end %>
          </div>
        </div>
        <div class="sr-mtr-card p-4">
          <div class="sr-mtr-label">Retention</div>
          <div class="sr-mtr-value mt-2 text-3xl">
            {Map.get(@retention_status, :configured_days, 30)}d
          </div>
          <div class={["text-sm", mtr_retention_status_class(@retention_status)]}>
            {mtr_retention_status_label(@retention_status)}
          </div>
        </div>
      </div>

      <div
        :if={@recent_trace_bars != [] or @trends.latency != []}
        class="grid grid-cols-1 gap-4 xl:grid-cols-3"
      >
        <div :if={@recent_trace_bars != []} class="sr-mtr-panel p-4 xl:col-span-2">
          <div class="flex items-center justify-between gap-3">
            <h4 class="sr-mtr-title font-semibold">Recent Availability Timeline</h4>
            <div class="sr-mtr-muted text-xs">newest left</div>
          </div>
          <div
            class="sr-mtr-outcome-strip mt-4"
            id="device-mtr-recent-samples"
            role="list"
            aria-label="Recent MTR trace outcomes"
          >
            <span
              :for={{trace, index} <- Enum.with_index(@recent_trace_bars)}
              role="listitem"
              class={[
                "sr-mtr-outcome-dot",
                if(mtr_trace_reached?(trace), do: "is-reached", else: "is-failed")
              ]}
              title={"#{trace["target"]} #{if mtr_trace_reached?(trace), do: "reached", else: "unreachable"}"}
            >
              <.user_time
                id={"device-mtr-outcome-#{mtr_time_key(trace, index)}-time"}
                value={trace["time"]}
                timezone={@timezone}
                style={:compact}
                class="sr-only"
              />
            </span>
          </div>
          <div class="mt-3 grid grid-cols-1 gap-3 text-xs md:grid-cols-3">
            <div class="sr-mtr-subpanel p-3">
              <div class="sr-mtr-label">Reached</div>
              <div class="sr-mtr-value mt-1 text-lg">{@mtr_dashboard.reached_count}</div>
            </div>
            <div class="sr-mtr-subpanel p-3">
              <div class="sr-mtr-label">Unreachable</div>
              <div class="sr-mtr-value mt-1 text-lg">{@mtr_dashboard.failed_count}</div>
            </div>
            <div class="sr-mtr-subpanel p-3">
              <div class="sr-mtr-label">Recent Samples</div>
              <div class="sr-mtr-value mt-1 text-lg">{@mtr_dashboard.trace_count}</div>
            </div>
          </div>
        </div>
        <div id="device-mtr-destination-latency-trend" class="sr-mtr-subpanel p-3">
          <div class="sr-mtr-muted text-xs mb-1">Destination Latency Trend</div>
          <.srql_sparkline points={@trends.latency} />
        </div>
      </div>

      <div class="sr-ui-table-shell">
        <table class={ui_table_class(size: "sm", class: "sr-mtr-table")}>
          <thead>
            <tr>
              <th>Time</th>
              <th>Target</th>
              <th>Status</th>
              <th>Hops</th>
              <th>Protocol</th>
              <th>Check</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{job, index} <- Enum.with_index(@pending_jobs)} class="hover opacity-80">
              <td class="whitespace-nowrap text-xs">
                <.user_time
                  id={"device-mtr-job-#{mtr_job_time_key(job, index)}-inserted-at"}
                  value={job.inserted_at}
                  timezone={@timezone}
                  style={:compact}
                />
              </td>
              <td class="font-mono text-sm">
                {(job.payload || %{})["target"] || @fallback_target || "-"}
              </td>
              <td>
                <.ui_badge size="sm" variant={pending_status_variant(job.status)}>
                  {job.status |> to_string() |> String.replace("_", " ") |> String.upcase()}
                </.ui_badge>
              </td>
              <td class="text-center">-</td>
              <td>
                <.ui_badge size="sm" variant="ghost">
                  {String.upcase((job.payload || %{})["protocol"] || "icmp")}
                </.ui_badge>
              </td>
              <td class="text-xs">pending</td>
              <td class="sr-mtr-muted text-xs">{job.id}</td>
            </tr>
            <tr :for={{trace, index} <- Enum.with_index(@traces)} class="hover">
              <td class="whitespace-nowrap text-xs">
                <.user_time
                  id={"device-mtr-trace-#{mtr_time_key(trace, index)}-time"}
                  value={trace["time"]}
                  timezone={@timezone}
                  style={:compact}
                />
              </td>
              <td class="font-mono text-sm">{trace["target"]}</td>
              <td>
                <.ui_badge :if={trace["target_reached"]} size="sm" variant="success">
                  Reached
                </.ui_badge>
                <.ui_badge :if={!trace["target_reached"]} size="sm" variant="error">
                  Unreachable
                </.ui_badge>
              </td>
              <td class="text-center">{trace["total_hops"]}</td>
              <td>
                <.ui_badge size="sm" variant="ghost">
                  {String.upcase(trace["protocol"] || "icmp")}
                </.ui_badge>
              </td>
              <td class="text-xs">{trace["check_name"] || "-"}</td>
              <td>
                <.ui_button
                  type="button"
                  phx-click="view_mtr_trace"
                  phx-value-id={trace["id"]}
                  size="xs"
                  variant="ghost"
                >
                  View
                </.ui_button>
              </td>
            </tr>
            <tr :if={@pending_jobs == [] and @traces == []}>
              <td colspan="7" class="sr-mtr-muted text-center py-8">
                No MTR traces found for this device.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <div class="flex items-center justify-between gap-3 border-t border-sr-line pt-4">
        <div class="sr-mtr-muted text-sm">
          {mtr_device_page_label(@page, @total_count)}
        </div>
        <div class="flex items-center gap-1">
          <.ui_button
            :if={@page > 1}
            patch={mtr_device_page_path(@device_uid, @page - 1)}
            size="sm"
            variant="outline"
          >
            <.icon name="hero-chevron-left" class="size-4" /> Prev
          </.ui_button>
          <.ui_button :if={@page <= 1} type="button" size="sm" variant="outline" disabled>
            <.icon name="hero-chevron-left" class="size-4" /> Prev
          </.ui_button>
          <span class="inline-flex min-h-9 items-center px-2 text-sm text-sr-muted">
            {@page} / {mtr_device_total_pages(@total_count, @page_size)}
          </span>
          <.ui_button
            :if={@page < mtr_device_total_pages(@total_count, @page_size)}
            patch={mtr_device_page_path(@device_uid, @page + 1)}
            size="sm"
            variant="outline"
          >
            Next <.icon name="hero-chevron-right" class="size-4" />
          </.ui_button>
          <.ui_button
            :if={@page >= mtr_device_total_pages(@total_count, @page_size)}
            type="button"
            size="sm"
            variant="outline"
            disabled
          >
            Next <.icon name="hero-chevron-right" class="size-4" />
          </.ui_button>
        </div>
      </div>
    </div>
    """
  end

  attr(:show, :boolean, default: false)
  attr(:trace, :map, default: nil)
  attr(:hops, :list, default: [])
  attr(:timezone, :string, default: "Etc/UTC")

  def mtr_trace_modal(assigns) do
    assigns = assign(assigns, :hop_dashboard, mtr_hop_dashboard(assigns.trace, assigns.hops))

    ~H"""
    <%= if @show and @trace do %>
      <dialog
        id="device-mtr-trace-details-modal"
        class="sr-ui-modal sr-ui-modal-open"
        phx-hook="DialogTopLayer"
        data-cancel="close_mtr_trace_modal"
      >
        <div class="sr-ui-modal-box sr-ui-modal-box-lg">
          <div class="mb-4 flex items-start justify-between gap-3">
            <div class="min-w-0">
              <h3 class="text-lg font-semibold tracking-tight text-sr-ink">MTR Trace Details</h3>
              <p class="mt-0.5 text-xs text-sr-muted">
                Path health for this probe — hop latency width, loss tint.
              </p>
            </div>
            <.ui_button type="button" phx-click="close_mtr_trace_modal" size="sm" variant="ghost">
              Close
            </.ui_button>
          </div>

          <div class="mb-4 grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
            <div class="min-w-0 rounded-lg border border-sr-line bg-sr-subtle/40 px-3 py-2.5">
              <div class="sr-mtr-label">Target</div>
              <div class="mt-1 truncate font-mono text-sm text-sr-ink" title={@trace["target"]}>
                {@trace["target"]}
              </div>
            </div>
            <div class="min-w-0 rounded-lg border border-sr-line bg-sr-subtle/40 px-3 py-2.5">
              <div class="sr-mtr-label">Agent</div>
              <div class="mt-1 truncate font-mono text-sm text-sr-ink" title={@trace["agent_id"]}>
                {@trace["agent_id"]}
              </div>
            </div>
            <div class="min-w-0 rounded-lg border border-sr-line bg-sr-subtle/40 px-3 py-2.5">
              <div class="sr-mtr-label">Protocol</div>
              <div class="mt-1 text-sm font-medium text-sr-ink">
                {String.upcase(@trace["protocol"] || "icmp")}
              </div>
            </div>
            <div class="min-w-0 rounded-lg border border-sr-line bg-sr-subtle/40 px-3 py-2.5">
              <div class="sr-mtr-label">Time</div>
              <div class="mt-1 font-mono text-sm text-sr-ink">
                <.user_time
                  id={"device-mtr-trace-modal-#{mtr_time_key(@trace, 0)}-time"}
                  value={@trace["time"]}
                  timezone={@timezone}
                  style={:compact}
                />
              </div>
            </div>
          </div>

          <div
            :if={@hops != []}
            class="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4"
          >
            <div class="sr-mtr-card p-4">
              <div class="sr-mtr-label">Hop Count</div>
              <div class="sr-mtr-value mt-2 text-2xl tabular-nums">{@hop_dashboard.hop_count}</div>
            </div>
            <div class="sr-mtr-card p-4">
              <div class="sr-mtr-label">Destination Loss</div>
              <div class={[
                "mt-2 text-2xl font-semibold tabular-nums",
                loss_class_for_modal(@hop_dashboard.destination_loss_pct)
              ]}>
                {format_pct_mtr(@hop_dashboard.destination_loss_pct)}
              </div>
            </div>
            <div class="sr-mtr-card p-4">
              <div class="sr-mtr-label">Peak Hop Avg RTT</div>
              <div class="sr-mtr-value mt-2 text-2xl tabular-nums">
                {format_us_mtr(@hop_dashboard.max_avg_us)}
              </div>
            </div>
            <div class="sr-mtr-card p-4">
              <div class="sr-mtr-label">Max Hop Loss</div>
              <div class="sr-mtr-value mt-2 text-2xl tabular-nums">
                {format_pct_mtr(@hop_dashboard.max_loss_pct)}
              </div>
            </div>
          </div>

          <div
            :if={@hops != []}
            class="sr-mtr-panel mb-4 p-4"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <h4 class="sr-mtr-title font-semibold">Hop Health</h4>
              <div class="sr-mtr-muted text-xs">latency width · loss tint</div>
            </div>
            <div class="mt-4 space-y-3">
              <div :for={hop <- @hops} class="space-y-1.5">
                <div class="flex items-baseline justify-between gap-3 text-xs">
                  <span class="min-w-0 truncate font-mono text-sr-ink">
                    <span class="text-sr-muted">hop {hop["hop_number"]}</span>
                    <span class="text-sr-muted"> · </span>
                    <span title={hop["addr"] || "???"}>{hop["addr"] || "???"}</span>
                  </span>
                  <span class="shrink-0 tabular-nums text-sr-muted">
                    {format_us_mtr(hop["avg_us"])}
                    <span class="mx-1 text-sr-line">·</span>
                    <span class={loss_class_for_modal(hop["loss_pct"])}>
                      {format_pct_mtr(hop["loss_pct"])}
                    </span>
                  </span>
                </div>
                <div class="sr-mtr-track h-2">
                  <div
                    class={[
                      "h-full rounded-full transition-all",
                      hop_loss_bar_class(hop["loss_pct"])
                    ]}
                    style={"width: #{mtr_hop_latency_bar_width(hop, @hop_dashboard.max_avg_us)}"}
                  >
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div class="sr-ui-table-shell overflow-x-auto">
            <table class={ui_table_class(size: "sm", class: "sr-mtr-table w-full min-w-[40rem]")}>
              <thead>
                <tr>
                  <th class="w-14">Hop</th>
                  <th>Address</th>
                  <th>Hostname</th>
                  <th class="text-right">Loss %</th>
                  <th class="text-right">Last</th>
                  <th class="text-right">Avg</th>
                  <th class="text-right">Min</th>
                  <th class="text-right">Max</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={hop <- @hops}>
                  <td class="text-center font-mono tabular-nums">{hop["hop_number"]}</td>
                  <td class="font-mono text-sm">{hop["addr"] || "???"}</td>
                  <td class="max-w-[14rem] truncate text-sm" title={hop["hostname"]}>
                    {hop["hostname"] || "-"}
                  </td>
                  <td class={[
                    "text-right font-mono text-sm tabular-nums",
                    loss_class_for_modal(hop["loss_pct"])
                  ]}>
                    {format_pct_mtr(hop["loss_pct"])}
                  </td>
                  <td class="text-right font-mono text-sm tabular-nums">
                    {format_us_mtr(hop["last_us"])}
                  </td>
                  <td class="text-right font-mono text-sm tabular-nums">
                    {format_us_mtr(hop["avg_us"])}
                  </td>
                  <td class="text-right font-mono text-sm tabular-nums">
                    {format_us_mtr(hop["min_us"])}
                  </td>
                  <td class="text-right font-mono text-sm tabular-nums">
                    {format_us_mtr(hop["max_us"])}
                  </td>
                </tr>
                <tr :if={@hops == []}>
                  <td colspan="8" class="sr-mtr-muted py-4 text-center">
                    No hop data available
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </dialog>
    <% end %>
    """
  end

  defp mtr_job_time_key(job, index) do
    stable_time_key([Map.get(job, :id), Map.get(job, "id")], index)
  end

  defp mtr_time_key(trace, index) do
    stable_time_key(
      [Map.get(trace, "id"), Map.get(trace, :id), Map.get(trace, "target"), Map.get(trace, :target)],
      index
    )
  end

  defp stable_time_key(candidates, index) do
    Enum.find_value(candidates, &mtr_id_fragment/1) || Integer.to_string(index)
  end

  defp mtr_id_fragment(value) when value in [nil, ""], do: nil

  defp mtr_id_fragment(value) do
    case value |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-") |> String.trim("-") do
      "" -> nil
      fragment -> fragment
    end
  end

  defp mtr_retention_status_label(%{status: :ok}), do: "policy synced"
  defp mtr_retention_status_label(%{status: :mismatch}), do: "policy mismatch"
  defp mtr_retention_status_label(%{status: :missing}), do: "policy missing"
  defp mtr_retention_status_label(%{status: :degraded}), do: "status unavailable"
  defp mtr_retention_status_label(_), do: "status unavailable"

  defp mtr_retention_status_class(%{status: :ok}), do: "text-success"

  defp mtr_retention_status_class(%{status: status}) when status in [:mismatch, :missing], do: "text-warning"

  defp mtr_retention_status_class(%{status: :degraded}), do: "text-error"
  defp mtr_retention_status_class(_), do: "sr-mtr-muted"

  defp mtr_device_total_pages(total_count, page_size) do
    max(1, ceil((total_count || 0) / max(page_size || 50, 1)))
  end

  defp mtr_device_page_label(page, total_count) when total_count > 0 do
    "Showing page #{page} (#{total_count} retained matches)"
  end

  defp mtr_device_page_label(_page, _total_count), do: "No retained matches"

  defp mtr_device_page_path(device_uid, page) do
    ~p"/devices/#{device_uid}?tab=mtr&mtr_page=#{page}"
  end

  defp pending_status_variant(:queued), do: "ghost"
  defp pending_status_variant(:sent), do: "info"
  defp pending_status_variant(:acknowledged), do: "info"
  defp pending_status_variant(:running), do: "warning"
  defp pending_status_variant(_), do: "ghost"

  defp mtr_trace_dashboard(traces, pending_jobs) do
    traces = List.wrap(traces)
    pending_jobs = List.wrap(pending_jobs)
    reached_count = Enum.count(traces, &mtr_trace_reached?/1)
    trace_count = length(traces)
    failed_count = max(trace_count - reached_count, 0)

    avg_hops =
      traces
      |> Enum.map(&mtr_trace_total_hops/1)
      |> Enum.reject(&(&1 <= 0))
      |> average_mtr_number()

    {destination_sent, destination_received, weighted_rtt_us, rtt_reply_count, endpoint_sample_count} =
      Enum.reduce(traces, {0, 0, 0, 0, 0}, fn trace, {sent, received, weighted_rtt, rtt_replies, samples} ->
        sent_count = mtr_trace_metric(trace, "destination_sent")
        received_count = mtr_trace_metric(trace, "destination_received")
        loss_received_count = if sent_count > 0, do: received_count, else: 0
        samples = if mtr_destination_observation?(trace), do: samples + 1, else: samples

        {weighted_rtt, rtt_replies} =
          case mtr_trace_rtt_us(trace) do
            nil -> {weighted_rtt, rtt_replies}
            avg_us -> {weighted_rtt + avg_us * received_count, rtt_replies + received_count}
          end

        {
          sent + sent_count,
          received + loss_received_count,
          weighted_rtt,
          rtt_replies,
          samples
        }
      end)

    avg_latency_us =
      case rtt_reply_count do
        0 -> nil
        _ -> round(weighted_rtt_us / rtt_reply_count)
      end

    destination_loss_pct =
      case destination_sent do
        0 -> nil
        _ -> Float.round(100.0 * (destination_sent - destination_received) / destination_sent, 1)
      end

    success_rate =
      reached_count
      |> positive_ratio(trace_count)
      |> Kernel.*(100)
      |> Float.round(1)

    %{
      pending_count: length(pending_jobs),
      trace_count: trace_count,
      reached_count: reached_count,
      failed_count: failed_count,
      success_rate: success_rate,
      avg_hops: Float.round(avg_hops, 1),
      avg_latency_label: format_us_mtr(avg_latency_us),
      destination_loss_pct: destination_loss_pct,
      endpoint_sample_count: endpoint_sample_count
    }
  end

  defp recent_mtr_trace_bars(traces) do
    traces
    |> List.wrap()
    |> Enum.take(8)
  end

  defp mtr_trace_reached?(trace) when is_map(trace) do
    value = Map.get(trace, "target_reached")
    value in [true, "true", 1, "1"]
  end

  defp mtr_trace_reached?(_trace), do: false

  defp mtr_trace_total_hops(trace) when is_map(trace) do
    case Map.get(trace, "total_hops") do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      _ -> 0
    end
  end

  defp mtr_trace_total_hops(_trace), do: 0

  defp mtr_trace_metric(trace, key) when is_map(trace) do
    case Map.get(trace, key) do
      value when is_integer(value) and value > 0 -> value
      value when is_float(value) and value > 0 -> round(value)
      _ -> 0
    end
  end

  defp mtr_trace_metric(_trace, _key), do: 0

  defp mtr_trace_rtt_us(trace) when is_map(trace) do
    case Map.get(trace, "destination_avg_us") do
      value when is_integer(value) and value >= 0 -> value
      value when is_float(value) and value >= 0 -> round(value)
      _ -> nil
    end
  end

  defp mtr_trace_rtt_us(_trace), do: nil

  defp mtr_destination_observation?(trace) when is_map(trace) do
    is_number(Map.get(trace, "destination_sent"))
  end

  defp mtr_destination_observation?(_trace), do: false

  defp mtr_radial_value(value) when is_number(value) do
    value
    |> round()
    |> min(100)
    |> max(0)
  end

  defp mtr_radial_value(_), do: 0

  defp mtr_reachability_tone(value) when is_number(value) and value < 80, do: "is-error"
  defp mtr_reachability_tone(value) when is_number(value) and value < 95, do: "is-warning"
  defp mtr_reachability_tone(_), do: "is-success"

  defp average_mtr_number([]), do: 0.0
  defp average_mtr_number(values), do: Enum.sum(values) / length(values)

  defp positive_ratio(_value, total) when total in [0, 0.0, nil], do: 0.0
  defp positive_ratio(value, total), do: min(1.0, max(value / total, 0.0))

  defp format_us_mtr(nil), do: "-"
  defp format_us_mtr(0), do: "0.0ms"

  defp format_us_mtr(us) when is_integer(us) do
    cond do
      us >= 1_000_000 -> "#{Float.round(us / 1_000_000, 1)}s"
      us >= 1_000 -> "#{Float.round(us / 1_000, 1)}ms"
      true -> "#{us}us"
    end
  end

  defp format_us_mtr(_), do: "-"

  defp format_pct_mtr(nil), do: "-"
  defp format_pct_mtr(pct) when is_float(pct), do: "#{Float.round(pct, 1)}%"
  defp format_pct_mtr(pct) when is_integer(pct), do: "#{pct}%"
  defp format_pct_mtr(_), do: "-"

  defp loss_class_for_modal(pct) when is_number(pct) and pct >= 50, do: "text-error"
  defp loss_class_for_modal(pct) when is_number(pct) and pct >= 10, do: "text-warning"
  defp loss_class_for_modal(_), do: ""

  defp mtr_hop_dashboard(trace, hops) do
    hops = List.wrap(hops)

    avg_loss_pct =
      hops
      |> Enum.map(&hop_loss_pct/1)
      |> Enum.reject(&is_nil/1)
      |> average_mtr_number()

    max_avg_us =
      hops
      |> Enum.map(&hop_avg_us/1)
      |> Enum.reject(&(&1 <= 0))
      |> Enum.max(fn -> 0 end)

    max_loss_pct =
      hops
      |> Enum.map(&hop_loss_pct/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 0.0 end)

    %{
      hop_count: length(hops),
      avg_loss_pct: Float.round(avg_loss_pct, 1),
      max_avg_us: max_avg_us,
      max_loss_pct: max_loss_pct,
      destination_loss_pct: destination_loss_pct(trace, hops)
    }
  end

  defp destination_loss_pct(trace, hops) do
    with true <- mtr_trace_reached?(trace),
         total_hops when total_hops > 0 <- mtr_trace_total_hops(trace),
         hop when is_map(hop) <- latest_mtr_hop(hops, total_hops),
         sent when sent > 0 <- mtr_hop_metric(hop, "sent") do
      received = mtr_hop_metric(hop, "received")
      Float.round(100.0 * (sent - received) / sent, 1)
    else
      _ -> nil
    end
  end

  defp latest_mtr_hop(hops, hop_number) do
    hops
    |> Enum.filter(&(mtr_hop_number(&1) == hop_number))
    |> case do
      [] -> nil
      terminal_hops -> Enum.max_by(terminal_hops, &mtr_hop_recency_key/1)
    end
  end

  defp mtr_hop_recency_key(hop) do
    {mtr_hop_time_key(Map.get(hop, "time")), Map.get(hop, "id") || ""}
  end

  defp mtr_hop_time_key(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp mtr_hop_time_key(%NaiveDateTime{} = value) do
    NaiveDateTime.diff(value, ~N[1970-01-01 00:00:00], :microsecond)
  end

  defp mtr_hop_time_key(_value), do: -1

  defp mtr_hop_number(hop) when is_map(hop) do
    case Map.get(hop, "hop_number") do
      value when is_integer(value) -> value
      value when is_float(value) -> round(value)
      _ -> 0
    end
  end

  defp mtr_hop_number(_hop), do: 0

  defp mtr_hop_metric(hop, key) when is_map(hop) do
    case Map.get(hop, key) do
      value when is_integer(value) and value >= 0 -> value
      value when is_float(value) and value >= 0 -> round(value)
      _ -> 0
    end
  end

  defp mtr_hop_metric(_hop, _key), do: 0

  defp hop_avg_us(hop) when is_map(hop) do
    case hop["avg_us"] do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      _ -> 0
    end
  end

  defp hop_avg_us(_hop), do: 0

  defp hop_loss_pct(hop) when is_map(hop) do
    case hop["loss_pct"] do
      value when is_integer(value) -> value * 1.0
      value when is_float(value) -> value
      _ -> nil
    end
  end

  defp hop_loss_pct(_hop), do: nil

  defp mtr_hop_latency_bar_width(hop, max_avg_us) do
    hop
    |> hop_avg_us()
    |> positive_ratio(max_avg_us)
    |> Kernel.*(100)
    |> Float.round(1)
    |> then(&"#{&1}%")
  end

  defp hop_loss_bar_class(pct) when is_number(pct) and pct >= 50, do: "bg-error"
  defp hop_loss_bar_class(pct) when is_number(pct) and pct >= 10, do: "bg-warning"
  defp hop_loss_bar_class(_pct), do: "bg-success"
end
