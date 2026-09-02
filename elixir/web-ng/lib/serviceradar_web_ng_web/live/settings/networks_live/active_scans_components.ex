defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.ActiveScansComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  # Statistics Cards Component
  attr :running, :list, required: true
  attr :recent, :list, required: true
  attr :groups, :list, required: true
  attr :timezone, :string, required: true

  def scan_statistics(assigns) do
    # Calculate stats from recent executions
    completed_recent = Enum.filter(assigns.recent, &(&1.status == :completed))

    latest_completed = latest_execution(completed_recent)
    latest_group_name = execution_group_name(latest_completed, assigns.groups)

    total_hosts = if latest_completed, do: latest_completed.hosts_total || 0, else: 0
    available_hosts = if latest_completed, do: latest_completed.hosts_available || 0, else: 0

    avg_success_rate = average_success_rate(completed_recent)

    failed_count = Enum.count(assigns.recent, &(&1.status == :failed))

    # Aggregate scanner metrics from recent completions
    aggregate_metrics = aggregate_scanner_metrics(completed_recent)

    assigns =
      assigns
      |> assign(:total_hosts, total_hosts)
      |> assign(:available_hosts, available_hosts)
      |> assign(:avg_success_rate, avg_success_rate)
      |> assign(:failed_count, failed_count)
      |> assign(:completed_count, length(completed_recent))
      |> assign(:aggregate_metrics, aggregate_metrics)
      |> assign(:latest_completed, latest_completed)
      |> assign(:latest_group_name, latest_group_name)

    ~H"""
    <div class="space-y-4">
      <!-- Main Stats -->
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div class="bg-sr-subtle/50 rounded-lg p-4">
          <div class="text-xs text-sr-muted uppercase tracking-wide">Running</div>
          <div class="text-2xl font-bold mt-1 flex items-center gap-2">
            {length(@running)}
            <span :if={length(@running) > 0} class="size-2 rounded-full bg-success animate-pulse"></span>
          </div>
        </div>
        <div id="active-scans-latest-execution" class="bg-sr-subtle/50 rounded-lg p-4">
          <div class="text-xs text-sr-muted uppercase tracking-wide">Latest Execution</div>
          <div class="text-2xl font-bold mt-1">{format_number(@total_hosts)} hosts</div>
          <div class="text-xs text-sr-muted">
            <%= if @latest_group_name do %>
              {@latest_group_name} •
            <% end %>
            {format_number(@available_hosts)} available
            <%= if @latest_completed do %>
              •
              <.user_time
                id="settings-active-scan-latest-completed-at"
                value={@latest_completed.completed_at || @latest_completed.updated_at}
                timezone={@timezone}
                style={:compact}
              />
            <% end %>
          </div>
        </div>
        <div class="bg-sr-subtle/50 rounded-lg p-4">
          <div class="text-xs text-sr-muted uppercase tracking-wide">Avg Success Rate</div>
          <div class={"text-2xl font-bold mt-1 #{success_rate_color(@avg_success_rate)}"}>
            {@avg_success_rate}%
          </div>
        </div>
        <div class="bg-sr-subtle/50 rounded-lg p-4">
          <div class="text-xs text-sr-muted uppercase tracking-wide">Recent Executions</div>
          <div class="text-2xl font-bold mt-1">{@completed_count}</div>
          <div :if={@failed_count > 0} class="text-xs text-error">{@failed_count} failed</div>
        </div>
      </div>

      <!-- Scanner Metrics Summary (only if we have metrics) -->
      <div :if={@aggregate_metrics.has_data} class="bg-sr-subtle/30 rounded-lg p-4">
        <div class="flex items-center gap-2 mb-3">
          <.icon name="hero-chart-bar" class="size-4 text-sr-muted" />
          <span class="text-xs text-sr-muted uppercase tracking-wide">
            Scanner Performance (Recent Scans)
          </span>
        </div>
        <div class="grid grid-cols-2 md:grid-cols-6 gap-4 text-sm">
          <div>
            <div class="text-sr-muted text-xs">Packets Sent</div>
            <div class="font-semibold font-mono">
              {format_number(@aggregate_metrics.packets_sent)}
            </div>
          </div>
          <div>
            <div class="text-sr-muted text-xs">Packets Received</div>
            <div class="font-semibold font-mono">
              {format_number(@aggregate_metrics.packets_recv)}
            </div>
          </div>
          <div>
            <div class="text-sr-muted text-xs">Avg Drop Rate</div>
            <div class={"font-semibold font-mono #{if to_float(@aggregate_metrics.avg_drop_rate) > 1.0, do: "text-warning", else: ""}"}>
              {Float.round(to_float(@aggregate_metrics.avg_drop_rate), 2)}%
            </div>
          </div>
          <div>
            <div class="text-sr-muted text-xs">Total Retries</div>
            <div class="font-semibold font-mono">
              {format_number(@aggregate_metrics.retries_successful)}/{format_number(
                @aggregate_metrics.retries_attempted
              )}
            </div>
          </div>
          <div>
            <div class="text-sr-muted text-xs">Throttle Waits</div>
            <div class={"font-semibold font-mono #{if @aggregate_metrics.throttle_waits > 0, do: "text-info", else: ""}"}>
              {format_number(@aggregate_metrics.throttle_waits)}
            </div>
            <div class="text-[11px] text-sr-muted">
              rate {format_number(@aggregate_metrics.rate_limit_waits)} / ports {format_number(
                @aggregate_metrics.source_port_waits
              )}
            </div>
          </div>
          <div>
            <div class="text-sr-muted text-xs">Throttle Time</div>
            <div class={"font-semibold font-mono #{if @aggregate_metrics.throttle_wait_time_ms > 0, do: "text-info", else: ""}"}>
              {format_duration(@aggregate_metrics.throttle_wait_time_ms)}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def average_success_rate([]), do: 0.0

  def average_success_rate(executions) do
    executions
    |> Enum.map(&execution_success_rate/1)
    |> Enum.sum()
    |> Kernel./(length(executions))
    |> Float.round(1)
  end

  def execution_success_rate(execution) do
    case execution.hosts_total do
      total when is_integer(total) and total > 0 ->
        (execution.hosts_available || 0) / total * 100

      _ ->
        0
    end
  end

  def aggregate_scanner_metrics(executions) do
    executions_with_metrics =
      Enum.filter(executions, fn e ->
        e.scanner_metrics && e.scanner_metrics != %{}
      end)

    if Enum.empty?(executions_with_metrics) do
      %{has_data: false}
    else
      packets_sent =
        Enum.reduce(executions_with_metrics, 0, fn e, acc ->
          acc + (get_in(e.scanner_metrics, ["packets_sent"]) || 0)
        end)

      packets_recv =
        Enum.reduce(executions_with_metrics, 0, fn e, acc ->
          acc + (get_in(e.scanner_metrics, ["packets_recv"]) || 0)
        end)

      retries_attempted =
        Enum.reduce(executions_with_metrics, 0, fn e, acc ->
          acc + (get_in(e.scanner_metrics, ["retries_attempted"]) || 0)
        end)

      retries_successful =
        Enum.reduce(executions_with_metrics, 0, fn e, acc ->
          acc + (get_in(e.scanner_metrics, ["retries_successful"]) || 0)
        end)

      rate_limit_deferrals =
        sum_scanner_metric(executions_with_metrics, "rate_limit_deferrals")

      rate_limit_waits = sum_scanner_metric(executions_with_metrics, "rate_limit_waits")
      source_port_waits = sum_scanner_metric(executions_with_metrics, "source_port_waits")
      throttle_waits = rate_limit_waits + source_port_waits

      throttle_waits =
        if throttle_waits > 0 do
          throttle_waits
        else
          rate_limit_deferrals
        end

      rate_limit_wait_time_ms = sum_scanner_metric(executions_with_metrics, "rate_limit_wait_time_ms")
      source_port_wait_time_ms = sum_scanner_metric(executions_with_metrics, "source_port_wait_time_ms")
      throttle_wait_time_ms = rate_limit_wait_time_ms + source_port_wait_time_ms

      # Calculate average drop rate
      drop_rates =
        Enum.map(executions_with_metrics, fn e -> get_in(e.scanner_metrics, ["rx_drop_rate_percent"]) || 0.0 end)

      avg_drop_rate =
        if Enum.empty?(drop_rates) do
          0.0
        else
          Enum.sum(drop_rates) / length(drop_rates)
        end

      %{
        has_data: true,
        packets_sent: packets_sent,
        packets_recv: packets_recv,
        retries_attempted: retries_attempted,
        retries_successful: retries_successful,
        rate_limit_deferrals: rate_limit_deferrals,
        rate_limit_waits: rate_limit_waits,
        source_port_waits: source_port_waits,
        throttle_waits: throttle_waits,
        rate_limit_wait_time_ms: rate_limit_wait_time_ms,
        source_port_wait_time_ms: source_port_wait_time_ms,
        throttle_wait_time_ms: throttle_wait_time_ms,
        avg_drop_rate: avg_drop_rate
      }
    end
  end

  def sum_scanner_metric(executions, key) do
    Enum.reduce(executions, 0, fn execution, acc ->
      acc + (get_in(execution.scanner_metrics, [key]) || 0)
    end)
  end

  def throttle_waits(rate_limit_waits, source_port_waits, legacy_deferrals) do
    waits = rate_limit_waits + source_port_waits

    if waits > 0, do: waits, else: legacy_deferrals
  end

  # Computes progress data for running scan card (extracted to reduce complexity)
  def compute_scan_progress(execution, progress) do
    started_at = Map.get(execution, :started_at)

    elapsed_ms =
      if started_at, do: DateTime.diff(DateTime.utc_now(), started_at, :millisecond), else: 0

    {hosts_processed, hosts_available, hosts_failed, hosts_total, batch_info} =
      if progress do
        batch =
          if progress.total_batches, do: "Batch #{progress.batch_num}/#{progress.total_batches}"

        {progress.hosts_processed, progress.hosts_available, progress.hosts_failed, progress.hosts_total, batch}
      else
        processed = Map.get(execution, :hosts_available, 0) + Map.get(execution, :hosts_failed, 0)

        {processed, Map.get(execution, :hosts_available) || 0, Map.get(execution, :hosts_failed) || 0,
         Map.get(execution, :hosts_total), nil}
      end

    hosts_total_display = compute_hosts_total_display(hosts_total, hosts_processed)

    %{
      elapsed_ms: elapsed_ms,
      hosts_processed: hosts_processed,
      hosts_available: hosts_available,
      hosts_failed: hosts_failed,
      hosts_total: hosts_total,
      hosts_total_display: hosts_total_display,
      batch_info: batch_info,
      has_progress: progress != nil
    }
  end

  def compute_hosts_total_display(hosts_total, hosts_processed) do
    cond do
      is_number(hosts_total) and hosts_total > 0 -> hosts_total
      is_number(hosts_processed) and hosts_processed > 0 -> hosts_processed
      true -> "—"
    end
  end

  # Running Scan Card Component
  attr :execution, :map, required: true
  attr :group, :map, default: nil
  attr :progress, :map, default: nil
  attr :timezone, :string, required: true

  def running_scan_card(assigns) do
    progress_data = compute_scan_progress(assigns.execution, assigns.progress)

    assigns =
      assigns
      |> assign(:elapsed_ms, progress_data.elapsed_ms)
      |> assign(:hosts_processed, progress_data.hosts_processed)
      |> assign(:hosts_available, progress_data.hosts_available)
      |> assign(:hosts_failed, progress_data.hosts_failed)
      |> assign(:hosts_total, progress_data.hosts_total)
      |> assign(:hosts_total_display, progress_data.hosts_total_display)
      |> assign(:batch_info, progress_data.batch_info)
      |> assign(:has_progress, progress_data.has_progress)

    ~H"""
    <div class="bg-sr-subtle/30 rounded-lg p-4 border border-sr-line">
      <div class="flex items-start justify-between">
        <div class="flex items-center gap-3">
          <div class="relative">
            <.ui_spinner size="sm" />
          </div>
          <div>
            <div class="font-medium">
              {if @group, do: @group.name, else: "Unknown Group"}
            </div>
            <div class="text-xs text-sr-muted flex items-center gap-2">
              <span :if={Map.get(@execution, :agent_id)}>
                <.icon name="hero-server" class="size-3 inline" />
                {Map.get(@execution, :agent_id)}
              </span>
              <span>
                Started
                <.relative_time
                  id={"settings-active-scan-#{@execution.id}-started-at"}
                  value={Map.get(@execution, :started_at)}
                  timezone={@timezone}
                />
              </span>
            </div>
          </div>
        </div>
        <div class="text-right">
          <div class="text-sm font-mono">{format_duration(@elapsed_ms)}</div>
          <div class="text-xs text-sr-muted">
            <span class="text-success">{@hosts_available}</span>
            <span :if={@hosts_failed > 0} class="text-error ml-1">/ {@hosts_failed} failed</span>
            <span>
              of {@hosts_total_display} hosts
            </span>
          </div>
          <div :if={@batch_info} class="text-xs text-sr-muted mt-0.5">
            {@batch_info}
          </div>
        </div>
      </div>

      <!-- Progress bar with real-time updates -->
      <div class="mt-3">
        <div class="h-1.5 bg-sr-control rounded-full overflow-hidden">
          <div
            class="h-full bg-success transition-all duration-300"
            style={"width: #{batch_progress_percent(@progress)}%"}
          >
          </div>
        </div>
        <div
          :if={@has_progress && @progress.total_batches}
          class="flex justify-between text-xs text-sr-muted mt-1"
        >
          <span>Processing...</span>
          <span>{batch_progress_percent(@progress)}%</span>
        </div>
      </div>
    </div>
    """
  end

  # Recent Execution Row Component
  attr :execution, :map, required: true
  attr :group, :map, default: nil
  attr :timezone, :string, required: true

  def recent_execution_row(assigns) do
    has_metrics = assigns.execution.scanner_metrics && assigns.execution.scanner_metrics != %{}
    assigns = assign(assigns, :has_metrics, has_metrics)

    ~H"""
    <tr class="hover:bg-sr-subtle/40">
      <td>
        <.execution_status_badge status={@execution.status} />
      </td>
      <td>
        <div class="font-medium">
          {if @group, do: @group.name, else: "Unknown Group"}
        </div>
        <div :if={@execution.agent_id} class="text-xs text-sr-muted">
          {@execution.agent_id}
        </div>
      </td>
      <td class="text-xs text-sr-muted">
        <.relative_time
          id={"settings-active-scan-#{@execution.id}-recent-started-at"}
          value={@execution.started_at}
          timezone={@timezone}
        />
      </td>
      <td class="font-mono text-xs">
        {format_duration(@execution.duration_ms)}
      </td>
      <td class="text-xs">
        <span :if={@execution.hosts_total}>
          {@execution.hosts_available || 0} / {@execution.hosts_total}
        </span>
        <span :if={!@execution.hosts_total} class="text-sr-muted">—</span>
      </td>
      <td>
        <.success_rate_badge execution={@execution} />
      </td>
      <td>
        <details :if={@has_metrics} class="sr-ui-dropdown group relative inline-block text-left">
          <summary class="sr-ui-dropdown-trigger list-none cursor-pointer outline-none focus-visible:ring-2 focus-visible:ring-sr-focus [&::-webkit-details-marker]:hidden">
            <span class="pointer-events-none inline-flex items-center">
              <.ui_icon_button size="xs" variant="ghost" aria-label="Scanner metrics">
                <.icon name="hero-chart-bar" class="size-4" />
              </.ui_icon_button>
            </span>
          </summary>
          <div class="absolute right-0 z-[var(--sr-z-menu)] mt-1.5 w-80 rounded-sr-surface border border-sr-line bg-sr-raised p-3 shadow-sr-raised">
            <h3 class="mb-2 text-sm font-semibold text-sr-ink">Scanner Metrics</h3>
            <.scanner_metrics_grid metrics={@execution.scanner_metrics} />
          </div>
        </details>
        <span :if={!@has_metrics} class="text-sr-muted text-xs">—</span>
      </td>
    </tr>
    """
  end

  # Scanner Metrics Grid Component
  attr :metrics, :map, required: true

  def scanner_metrics_grid(assigns) do
    metrics = assigns.metrics || %{}
    rate_limit_waits = Map.get(metrics, "rate_limit_waits") || 0
    source_port_waits = Map.get(metrics, "source_port_waits") || 0
    rate_limit_wait_time_ms = Map.get(metrics, "rate_limit_wait_time_ms") || 0
    source_port_wait_time_ms = Map.get(metrics, "source_port_wait_time_ms") || 0
    legacy_deferrals = Map.get(metrics, "rate_limit_deferrals") || 0

    assigns =
      assigns
      |> assign(:packets_sent, Map.get(metrics, "packets_sent", 0))
      |> assign(:packets_recv, Map.get(metrics, "packets_recv", 0))
      |> assign(:packets_dropped, Map.get(metrics, "packets_dropped", 0))
      |> assign(:retries_attempted, Map.get(metrics, "retries_attempted", 0))
      |> assign(:retries_successful, Map.get(metrics, "retries_successful", 0))
      |> assign(:rate_limit_deferrals, legacy_deferrals)
      |> assign(:rate_limit_waits, rate_limit_waits)
      |> assign(:source_port_waits, source_port_waits)
      |> assign(:rate_limit_wait_time_ms, rate_limit_wait_time_ms)
      |> assign(:source_port_wait_time_ms, source_port_wait_time_ms)
      |> assign(:rx_drop_rate_percent, Map.get(metrics, "rx_drop_rate_percent", 0.0))
      |> assign(:port_exhaustion_count, Map.get(metrics, "port_exhaustion_count", 0))
      |> assign(:throttle_waits, throttle_waits(rate_limit_waits, source_port_waits, legacy_deferrals))
      |> assign(:throttle_wait_time_ms, rate_limit_wait_time_ms + source_port_wait_time_ms)

    ~H"""
    <div class="grid grid-cols-2 gap-2 text-xs">
      <div class="bg-sr-subtle/50 rounded p-2">
        <div class="text-sr-muted">Packets Sent</div>
        <div class="font-semibold font-mono">{format_number(@packets_sent)}</div>
      </div>
      <div class="bg-sr-subtle/50 rounded p-2">
        <div class="text-sr-muted">Packets Received</div>
        <div class="font-semibold font-mono">{format_number(@packets_recv)}</div>
      </div>
      <div class="bg-sr-subtle/50 rounded p-2">
        <div class="text-sr-muted">Packets Dropped</div>
        <div class={"font-semibold font-mono #{if @packets_dropped > 0, do: "text-warning", else: ""}"}>
          {format_number(@packets_dropped)}
        </div>
      </div>
      <div class="bg-sr-subtle/50 rounded p-2">
        <div class="text-sr-muted">RX Drop Rate</div>
        <div class={"font-semibold font-mono #{if to_float(@rx_drop_rate_percent) > 1.0, do: "text-warning", else: ""}"}>
          {Float.round(to_float(@rx_drop_rate_percent), 2)}%
        </div>
      </div>
      <div class="bg-sr-subtle/50 rounded p-2">
        <div class="text-sr-muted">Retries</div>
        <div class="font-semibold font-mono">
          {format_number(@retries_successful)}/{format_number(@retries_attempted)}
        </div>
      </div>
      <div class="bg-sr-subtle/50 rounded p-2">
        <div class="text-sr-muted">Throttle Waits</div>
        <div class={"font-semibold font-mono #{if @throttle_waits > 0, do: "text-info", else: ""}"}>
          {format_number(@throttle_waits)}
        </div>
        <div class="text-[11px] text-sr-muted">
          rate {format_number(@rate_limit_waits)} / ports {format_number(@source_port_waits)}
        </div>
      </div>
      <div :if={@throttle_wait_time_ms > 0} class="bg-sr-subtle/50 rounded p-2">
        <div class="text-sr-muted">Throttle Time</div>
        <div class="font-semibold font-mono text-info">
          {format_duration(@throttle_wait_time_ms)}
        </div>
      </div>
      <div :if={@port_exhaustion_count > 0} class="col-span-2 bg-error/10 rounded p-2">
        <div class="text-error/80">Port Exhaustion Events</div>
        <div class="font-semibold font-mono text-error">{format_number(@port_exhaustion_count)}</div>
      </div>
    </div>
    """
  end

  def format_number(nil), do: "0"
  def format_number(n) when is_float(n), do: n |> Float.round(2) |> to_string()

  def format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}/, "\\0,")
    |> String.reverse()
    |> String.trim_leading(",")
  end

  def format_number(n), do: to_string(n)

  # Convert any number to float for Float.round/2 compatibility
  def to_float(nil), do: 0.0
  def to_float(n) when is_float(n), do: n
  def to_float(n) when is_integer(n), do: n * 1.0
  def to_float(n) when is_number(n), do: n * 1.0

  # Execution Status Badge
  attr :status, :atom, required: true

  def execution_status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium",
      status_badge_class(@status)
    ]}>
      <.icon name={status_icon(@status)} class="size-3" />
      {status_label(@status)}
    </span>
    """
  end

  # Success Rate Badge
  attr :execution, :map, required: true

  def success_rate_badge(assigns) do
    rate =
      if assigns.execution.hosts_total && assigns.execution.hosts_total > 0 do
        Float.round((assigns.execution.hosts_available || 0) / assigns.execution.hosts_total * 100, 1)
      end

    assigns = assign(assigns, :rate, rate)

    ~H"""
    <span :if={@rate} class={"text-xs font-medium #{success_rate_color(@rate)}"}>
      {@rate}%
    </span>
    <span :if={!@rate} class="text-xs text-sr-muted">—</span>
    """
  end

  # Helper functions for Active Scans panel

  def status_badge_class(:completed), do: "bg-success/20 text-success"
  def status_badge_class(:failed), do: "bg-error/20 text-error"
  def status_badge_class(:running), do: "bg-info/20 text-info"
  def status_badge_class(_), do: "bg-sr-subtle text-sr-muted"

  def status_icon(:completed), do: "hero-check-circle"
  def status_icon(:failed), do: "hero-x-circle"
  def status_icon(:running), do: "hero-arrow-path"
  def status_icon(_), do: "hero-clock"

  def status_label(:completed), do: "Completed"
  def status_label(:failed), do: "Failed"
  def status_label(:running), do: "Running"
  def status_label(:pending), do: "Pending"
  def status_label(_), do: "Unknown"

  def success_rate_color(rate) when rate >= 90, do: "text-success"
  def success_rate_color(rate) when rate >= 70, do: "text-warning"
  def success_rate_color(_rate), do: "text-error"

  # Calculate progress percentage from batch info
  def batch_progress_percent(%{batch_num: batch_num, total_batches: total_batches})
      when is_integer(batch_num) and is_integer(total_batches) and total_batches > 0 do
    Float.round(batch_num / total_batches * 100, 1)
  end

  def batch_progress_percent(_), do: 0

  def format_relative_time(nil), do: "—"

  def format_relative_time(%DateTime{} = dt) do
    diff_seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff_seconds < 60 -> "#{diff_seconds}s ago"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)}h ago"
      true -> "#{div(diff_seconds, 86_400)}d ago"
    end
  end

  def format_relative_time(_), do: "—"

  attr :id, :string, required: true
  attr :value, :any, required: true
  attr :timezone, :string, required: true

  defp relative_time(assigns) do
    absolute? =
      case assigns.value do
        %DateTime{} = value -> DateTime.diff(DateTime.utc_now(), value, :second) >= 86_400
        _ -> false
      end

    assigns
    |> assign(:absolute?, absolute?)
    |> then(fn assigns ->
      ~H"""
      <%= if @absolute? do %>
        <.user_time
          id={@id}
          value={@value}
          timezone={@timezone}
          style={:compact}
          fallback="—"
        />
      <% else %>
        {format_relative_time(@value)}
      <% end %>
      """
    end)
  end

  def format_duration(nil), do: "—"
  def format_duration(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"

  def format_duration(ms) when is_integer(ms) and ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"

  def format_duration(ms) when is_integer(ms) do
    minutes = div(ms, 60_000)
    seconds = div(rem(ms, 60_000), 1000)
    "#{minutes}m #{seconds}s"
  end

  def format_duration(_), do: "—"

  def group_last_run_at(%{last_run_at: %DateTime{} = last_run_at}), do: last_run_at

  def group_last_run_at(group) do
    case latest_group_execution(group) do
      %{completed_at: %DateTime{} = completed_at} -> completed_at
      %{started_at: %DateTime{} = started_at} -> started_at
      _ -> nil
    end
  end

  def persisted_sweep_command_status(group) do
    case latest_group_execution(group) do
      %{status: :completed} -> %{state: :success}
      %{status: :failed} -> %{state: :error}
      %{status: :running} -> %{state: :progress}
      %{status: :pending} -> %{state: :sent}
      _ -> nil
    end
  end

  defp latest_group_execution(%{executions: [%{} = execution | _]}), do: execution
  defp latest_group_execution(_group), do: nil

  defp latest_execution(executions) do
    Enum.max_by(executions, &latest_execution_time/1, fn -> nil end)
  end

  defp execution_group_name(nil, _groups), do: nil

  defp execution_group_name(execution, groups) do
    case Enum.find(groups, &(Map.get(&1, :id) == Map.get(execution, :sweep_group_id))) do
      nil -> nil
      group -> Map.get(group, :name)
    end
  end

  defp latest_execution_time(execution) do
    Map.get(execution, :completed_at) ||
      Map.get(execution, :updated_at) ||
      Map.get(execution, :started_at) ||
      DateTime.from_unix!(0)
  end
end
