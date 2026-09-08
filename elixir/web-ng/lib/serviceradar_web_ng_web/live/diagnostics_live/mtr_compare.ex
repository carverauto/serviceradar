defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrCompare do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import Ash.Expr

  alias Ash.Page.Keyset
  alias ServiceRadar.Observability.MtrHop
  alias ServiceRadar.Observability.MtrTrace
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrData

  require Ash.Query

  @mode_trace "trace"
  @mode_window "window"
  @preset_today_vs_yesterday "today_vs_yesterday"
  @preset_today_vs_yesterday_elapsed "today_vs_yesterday_elapsed"
  @preset_last_6h "last_6h"
  @preset_last_24h "last_24h"
  @preset_custom "custom"
  @protocols ["", "icmp", "udp", "tcp"]
  @reached_filters ["", "reached", "unreachable"]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "MTR Path Comparison")
     |> assign(:page_path, "/diagnostics/mtr/compare")
     |> assign(:mode, @mode_window)
     |> assign(:recent_traces, [])
     |> assign(:trace_a, nil)
     |> assign(:trace_b, nil)
     |> assign(:hops_a, [])
     |> assign(:hops_b, [])
     |> assign(:diff, [])
     |> assign(:window_state, default_window_state())
     |> assign(:window_comparison, nil)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = load_recent_traces(socket)
    mode = normalize_mode(Map.get(params, "mode"), params)

    socket =
      socket
      |> assign(:mode, mode)
      |> assign(:error, nil)

    socket =
      case mode do
        @mode_trace -> load_trace_mode(socket, params)
        @mode_window -> load_window_mode(socket, params)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("compare_trace", %{"a" => a, "b" => b}, socket) do
    if a != "" and b != "" and a != b do
      {:noreply, push_patch(socket, to: compare_path(%{"mode" => @mode_trace, "a" => a, "b" => b}))}
    else
      {:noreply,
       socket
       |> assign(:error, "Select two different traces to compare")
       |> clear_trace_comparison()}
    end
  end

  def handle_event("compare_windows", %{"window" => window_params}, socket) do
    params =
      %{
        "mode" => @mode_window,
        "preset" => Map.get(window_params, "preset", @preset_today_vs_yesterday),
        "target" => Map.get(window_params, "target", ""),
        "agent" => Map.get(window_params, "agent", ""),
        "protocol" => Map.get(window_params, "protocol", ""),
        "reached" => Map.get(window_params, "reached", "")
      }
      |> maybe_put_custom_window_params(window_params)
      |> reject_blank_params()

    {:noreply, push_patch(socket, to: compare_path(params))}
  end

  defp load_trace_mode(socket, params) do
    socket =
      socket
      |> assign(:window_comparison, nil)
      |> assign(:window_state, default_window_state())

    case {Map.get(params, "a"), Map.get(params, "b")} do
      {a, b} when is_binary(a) and is_binary(b) and a != "" and b != "" ->
        load_comparison(socket, a, b)

      _ ->
        clear_trace_comparison(socket)
    end
  end

  defp load_window_mode(socket, params) do
    state = window_state_from_params(params)

    case MtrData.compare_windows(
           window_a: state.window_a,
           window_b: state.window_b,
           target_filter: state.target_filter,
           agent_filter: state.agent_filter,
           protocol: state.protocol,
           reached: state.reached,
           bucket_count: 24,
           signature_limit: 6
         ) do
      {:ok, comparison} ->
        socket
        |> clear_trace_comparison()
        |> assign(:window_state, state)
        |> assign(:window_comparison, comparison)

      {:error, reason} ->
        socket
        |> clear_trace_comparison()
        |> assign(:window_state, state)
        |> assign(:window_comparison, nil)
        |> assign(:error, "Failed to compare windows: #{inspect(reason)}")
    end
  end

  defp clear_trace_comparison(socket) do
    socket
    |> assign(:trace_a, nil)
    |> assign(:trace_b, nil)
    |> assign(:hops_a, [])
    |> assign(:hops_b, [])
    |> assign(:diff, [])
  end

  defp load_recent_traces(socket) do
    query =
      MtrTrace
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.sort(time: :desc)
      |> Ash.Query.limit(75)

    case Ash.read(query, scope: socket.assigns.current_scope) do
      {:ok, %Keyset{results: results}} ->
        assign(socket, :recent_traces, Enum.map(results, &trace_to_compare_map/1))

      {:ok, results} when is_list(results) ->
        assign(socket, :recent_traces, Enum.map(results, &trace_to_compare_map/1))

      {:error, _reason} ->
        assign(socket, :recent_traces, [])
    end
  end

  defp load_comparison(socket, trace_id_a, trace_id_b) do
    scope = socket.assigns.current_scope

    with {:ok, trace_a, hops_a} <- load_trace_with_hops(trace_id_a, scope),
         {:ok, trace_b, hops_b} <- load_trace_with_hops(trace_id_b, scope) do
      diff = compute_diff(hops_a, hops_b)

      socket
      |> assign(:trace_a, trace_a)
      |> assign(:trace_b, trace_b)
      |> assign(:hops_a, hops_a)
      |> assign(:hops_b, hops_b)
      |> assign(:diff, diff)
      |> assign(:error, nil)
    else
      {:error, reason} ->
        assign(socket, :error, "Failed to load traces: #{inspect(reason)}")
    end
  end

  defp load_trace_with_hops(trace_id, scope) do
    with {:ok, trace_uuid} <- Ecto.UUID.cast(trace_id),
         {:ok, trace} <- read_trace(trace_uuid, scope),
         {:ok, hops} <- read_trace_hops(trace_uuid, scope) do
      {:ok, trace_to_compare_map(trace), Enum.map(hops, &hop_to_compare_map/1)}
    else
      :error -> {:error, "Invalid trace id"}
      {:error, :not_found} -> {:error, "Trace not found"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_trace(trace_uuid, scope) do
    query =
      MtrTrace
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(expr(id == ^trace_uuid))
      |> Ash.Query.limit(1)

    case Ash.read(query, scope: scope) do
      {:ok, %Keyset{results: [trace | _]}} -> {:ok, trace}
      {:ok, [trace | _]} -> {:ok, trace}
      {:ok, %Keyset{results: []}} -> {:error, :not_found}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_trace_hops(trace_uuid, scope) do
    query =
      MtrHop
      |> Ash.Query.for_read(:by_trace, %{trace_id: trace_uuid})
      |> Ash.Query.sort(hop_number: :asc)
      |> Ash.Query.limit(256)

    case Ash.read(query, scope: scope) do
      {:ok, %Keyset{results: results}} -> {:ok, results}
      {:ok, results} when is_list(results) -> {:ok, results}
      {:error, reason} -> {:error, reason}
    end
  end

  defp trace_to_compare_map(trace) do
    %{
      "id" => trace.id && to_string(trace.id),
      "time" => trace.time,
      "agent_id" => trace.agent_id,
      "target" => trace.target,
      "target_ip" => trace.target_ip,
      "target_reached" => trace.target_reached,
      "total_hops" => trace.total_hops,
      "protocol" => trace.protocol,
      "ip_version" => trace.ip_version
    }
  end

  defp hop_to_compare_map(hop) do
    %{
      "hop_number" => hop.hop_number,
      "addr" => hop.addr,
      "hostname" => hop.hostname,
      "asn" => hop.asn,
      "asn_org" => hop.asn_org,
      "loss_pct" => hop.loss_pct,
      "avg_us" => hop.avg_us,
      "min_us" => hop.min_us,
      "max_us" => hop.max_us
    }
  end

  # Build a unified diff list: [{hop_number, hop_a, hop_b, status}]
  # status: :same, :changed, :added, :removed
  defp compute_diff(hops_a, hops_b) do
    map_a = Map.new(hops_a, fn h -> {h["hop_number"], h} end)
    map_b = Map.new(hops_b, fn h -> {h["hop_number"], h} end)

    all_hops =
      (Map.keys(map_a) ++ Map.keys(map_b))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(all_hops, fn hop_num ->
      a = Map.get(map_a, hop_num)
      b = Map.get(map_b, hop_num)

      status =
        cond do
          is_nil(a) -> :added
          is_nil(b) -> :removed
          (a["addr"] || "") != (b["addr"] || "") -> :changed
          true -> :same
        end

      {hop_num, a, b, status}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      srql={%{enabled: false, page_path: @page_path}}
    >
      <div class="p-4 md:p-6 space-y-6">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div class="flex items-center gap-3">
            <.ui_button navigate={~p"/diagnostics/mtr"} size="sm" variant="ghost">
              <.icon name="hero-chevron-left" class="size-4" /> Back
            </.ui_button>
            <div>
              <h1 class="text-2xl font-bold">MTR Comparison</h1>
              <p class="sr-mtr-muted mt-1 text-sm">
                Compare individual paths or aggregate windows like today versus yesterday.
              </p>
            </div>
          </div>

          <div class="flex flex-wrap gap-1">
            <.ui_button
              patch={compare_path(%{"mode" => mode_window()})}
              size="sm"
              variant={if(@mode == mode_window(), do: "primary", else: "outline")}
              active={@mode == mode_window()}
            >
              Time Windows
            </.ui_button>
            <.ui_button
              patch={compare_path(%{"mode" => mode_trace()})}
              size="sm"
              variant={if(@mode == mode_trace(), do: "primary", else: "outline")}
              active={@mode == mode_trace()}
            >
              Trace Pair
            </.ui_button>
          </div>
        </div>

        <div :if={@error} class={ui_alert_class("error")}>
          <span>{@error}</span>
        </div>

        <%= if @mode == mode_trace() do %>
          <.trace_pair_controls recent_traces={@recent_traces} trace_a={@trace_a} trace_b={@trace_b} />
          <.trace_pair_result
            trace_a={@trace_a}
            trace_b={@trace_b}
            diff={@diff}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
          />
        <% else %>
          <.window_controls state={@window_state} />
          <.window_result
            state={@window_state}
            comparison={@window_comparison}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
          />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr(:recent_traces, :list, required: true)
  attr(:trace_a, :map, default: nil)
  attr(:trace_b, :map, default: nil)

  defp trace_pair_controls(assigns) do
    ~H"""
    <form phx-submit="compare_trace" class="sr-mtr-panel p-4">
      <div class="grid grid-cols-1 gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] lg:items-end">
        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Trace A</span>
          </label>
          <select name="a" class={ui_field_class(size: "sm", class: "w-full")}>
            <option value="">Select trace...</option>
            <%= for t <- @recent_traces do %>
              <option value={t["id"]} selected={@trace_a && @trace_a["id"] == t["id"]}>
                {trace_option_label(t)}
              </option>
            <% end %>
          </select>
        </div>
        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Trace B</span>
          </label>
          <select name="b" class={ui_field_class(size: "sm", class: "w-full")}>
            <option value="">Select trace...</option>
            <%= for t <- @recent_traces do %>
              <option value={t["id"]} selected={@trace_b && @trace_b["id"] == t["id"]}>
                {trace_option_label(t)}
              </option>
            <% end %>
          </select>
        </div>
        <.ui_button type="submit" size="sm" variant="primary">Compare Traces</.ui_button>
      </div>
    </form>
    """
  end

  attr(:trace_a, :map, default: nil)
  attr(:trace_b, :map, default: nil)
  attr(:diff, :list, default: [])
  attr(:timezone, :string, default: "Etc/UTC")

  defp trace_pair_result(assigns) do
    ~H"""
    <div :if={@trace_a && @trace_b} class="space-y-4">
      <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <.trace_summary_card side="a" label="Trace A" trace={@trace_a} timezone={@timezone} />
        <.trace_summary_card side="b" label="Trace B" trace={@trace_b} timezone={@timezone} />
      </div>

      <div class="sr-ui-table-shell">
        <table class={ui_table_class(size: "sm", class: "sr-mtr-table")}>
          <thead>
            <tr>
              <th class="w-12">Hop</th>
              <th class="w-8"></th>
              <th>Address A</th>
              <th class="text-right">Avg A</th>
              <th class="text-right">Loss A</th>
              <th>Address B</th>
              <th class="text-right">Avg B</th>
              <th class="text-right">Loss B</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{hop_num, a, b, status} <- @diff} class={diff_row_class(status)}>
              <td class="font-mono text-center">{hop_num}</td>
              <td>{diff_icon(status)}</td>
              <td class="font-mono text-sm">{hop_addr(a)}</td>
              <td class="text-right font-mono text-sm">{hop_val(a, "avg_us")}</td>
              <td class="text-right font-mono text-sm">{hop_pct(a, "loss_pct")}</td>
              <td class="font-mono text-sm">{hop_addr(b)}</td>
              <td class="text-right font-mono text-sm">{hop_val(b, "avg_us")}</td>
              <td class="text-right font-mono text-sm">{hop_pct(b, "loss_pct")}</td>
            </tr>
            <tr :if={@diff == []}>
              <td colspan="8" class="text-center py-4 sr-mtr-muted">
                No hop data to compare
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:side, :string, required: true)
  attr(:trace, :map, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  defp trace_summary_card(assigns) do
    ~H"""
    <div class="sr-mtr-card p-4">
      <div class="sr-mtr-label">{@label}</div>
      <div class="font-mono text-sm sr-mtr-title mt-1">{@trace["target"]}</div>
      <div class="sr-mtr-muted text-xs mt-1">
        <.user_time
          id={"mtr-compare-trace-#{@side}-#{stable_trace_identity(@trace)}-time"}
          value={@trace["time"]}
          timezone={@timezone}
          style={:compact}
          fallback="-"
        /> - {@trace["agent_id"]} - {String.upcase(@trace["protocol"] || "icmp")}
      </div>
    </div>
    """
  end

  attr(:state, :map, required: true)

  defp window_controls(assigns) do
    ~H"""
    <form phx-submit="compare_windows" class="sr-mtr-panel p-4 space-y-4">
      <div class="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-6">
        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Preset</span>
          </label>
          <select name="window[preset]" class={ui_field_class(size: "sm", class: "w-full")}>
            <%= for {label, value} <- preset_options() do %>
              <option value={value} selected={@state.preset == value}>{label}</option>
            <% end %>
          </select>
        </div>

        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Target</span>
          </label>
          <input
            name="window[target]"
            value={@state.target_filter}
            class={ui_field_class(size: "sm", class: "w-full")}
            placeholder="target or IP"
          />
        </div>

        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Source Agent</span>
          </label>
          <input
            name="window[agent]"
            value={@state.agent_filter}
            class={ui_field_class(size: "sm", class: "w-full")}
            placeholder="any agent"
          />
        </div>

        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Protocol</span>
          </label>
          <select name="window[protocol]" class={ui_field_class(size: "sm", class: "w-full")}>
            <%= for protocol <- protocol_options() do %>
              <option value={protocol} selected={@state.protocol == protocol}>
                {if protocol == "", do: "Any", else: String.upcase(protocol)}
              </option>
            <% end %>
          </select>
        </div>

        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Reachability</span>
          </label>
          <select name="window[reached]" class={ui_field_class(size: "sm", class: "w-full")}>
            <%= for reached <- reached_filter_options() do %>
              <option value={reached} selected={@state.reached == reached}>
                {reached_label(reached)}
              </option>
            <% end %>
          </select>
        </div>

        <div class="flex flex-col gap-1.5 justify-end">
          <.ui_button type="submit" size="sm" variant="primary">Compare Windows</.ui_button>
        </div>
      </div>

      <div class={[
        "grid grid-cols-1 gap-3 lg:grid-cols-4",
        if(@state.preset == preset_custom(), do: "", else: "hidden")
      ]}>
        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Window A Start (UTC)</span>
          </label>
          <input
            type="datetime-local"
            name="window[a_start]"
            value={window_input_value(@state.window_a.start)}
            class={ui_field_class(size: "sm", class: "w-full")}
          />
        </div>
        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Window A End (UTC)</span>
          </label>
          <input
            type="datetime-local"
            name="window[a_end]"
            value={window_input_value(@state.window_a.end)}
            class={ui_field_class(size: "sm", class: "w-full")}
          />
        </div>
        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Window B Start (UTC)</span>
          </label>
          <input
            type="datetime-local"
            name="window[b_start]"
            value={window_input_value(@state.window_b.start)}
            class={ui_field_class(size: "sm", class: "w-full")}
          />
        </div>
        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Window B End (UTC)</span>
          </label>
          <input
            type="datetime-local"
            name="window[b_end]"
            value={window_input_value(@state.window_b.end)}
            class={ui_field_class(size: "sm", class: "w-full")}
          />
        </div>
      </div>
    </form>
    """
  end

  attr(:state, :map, required: true)
  attr(:comparison, :map, default: nil)
  attr(:timezone, :string, default: "Etc/UTC")

  defp window_result(assigns) do
    ~H"""
    <div :if={@comparison} class="space-y-4">
      <div class="grid grid-cols-1 gap-4 xl:grid-cols-2">
        <.window_summary_header side={:a} state={@state} summary={@comparison.a} timezone={@timezone} />
        <.window_summary_header side={:b} state={@state} summary={@comparison.b} timezone={@timezone} />
      </div>

      <.comparison_baseline_notice comparison={@comparison} state={@state} />

      <div class="grid grid-cols-1 gap-4 xl:grid-cols-5">
        <.compare_metric_card
          label="Reachability"
          a_value={format_percent(@comparison.a.success_rate)}
          b_value={format_percent(@comparison.b.success_rate)}
          delta={@comparison.deltas.success_rate}
          unit="points"
          higher_is_better={true}
          a_path={diagnostics_window_path(@state, :a)}
          b_path={diagnostics_window_path(@state, :b)}
        />
        <.compare_metric_card
          label="Trace Volume"
          a_value={@comparison.a.trace_count}
          b_value={@comparison.b.trace_count}
          delta={@comparison.deltas.trace_count}
          unit="traces"
          higher_is_better={true}
          a_path={diagnostics_window_path(@state, :a)}
          b_path={diagnostics_window_path(@state, :b)}
        />
        <.compare_metric_card
          id="mtr-compare-destination-latency"
          label="Destination Latency"
          a_value={format_us(@comparison.a.avg_destination_us)}
          b_value={format_us(@comparison.b.avg_destination_us)}
          delta={@comparison.deltas.avg_destination_us}
          unit="latency_us"
          higher_is_better={false}
          a_path={diagnostics_window_path(@state, :a)}
          b_path={diagnostics_window_path(@state, :b)}
        />
        <.compare_metric_card
          id="mtr-compare-destination-loss"
          label="Destination Loss"
          a_value={format_percent(@comparison.a.destination_loss_pct)}
          b_value={format_percent(@comparison.b.destination_loss_pct)}
          delta={@comparison.deltas.destination_loss_pct}
          unit="points"
          higher_is_better={false}
          a_path={diagnostics_window_path(@state, :a)}
          b_path={diagnostics_window_path(@state, :b)}
        />
        <.compare_metric_card
          label="Hop Depth"
          a_value={@comparison.a.avg_hops}
          b_value={@comparison.b.avg_hops}
          delta={@comparison.deltas.avg_hops}
          unit="hops"
          higher_is_better={false}
          a_path={diagnostics_window_path(@state, :a)}
          b_path={diagnostics_window_path(@state, :b)}
        />
      </div>

      <div class="grid grid-cols-1 gap-4 xl:grid-cols-2">
        <.window_timeline
          title={@comparison.a.label}
          rows={@comparison.a.timeline}
          state={@state}
          timezone={@timezone}
        />
        <.window_timeline
          title={@comparison.b.label}
          rows={@comparison.b.timeline}
          state={@state}
          timezone={@timezone}
        />
      </div>

      <div class="grid grid-cols-1 gap-4 xl:grid-cols-2">
        <.route_signature_panel
          title={"#{@comparison.a.label} Dominant Routes"}
          signatures={@comparison.a.route_signatures}
        />
        <.route_signature_panel
          title={"#{@comparison.b.label} Dominant Routes"}
          signatures={@comparison.b.route_signatures}
        />
      </div>

      <.agent_matrix rows={@comparison.agents} state={@state} />
    </div>
    """
  end

  attr(:comparison, :map, required: true)
  attr(:state, :map, required: true)

  defp comparison_baseline_notice(assigns) do
    ~H"""
    <div class={["sr-mtr-baseline-note p-3", baseline_note_class(@comparison)]}>
      <div class="flex flex-col gap-2 md:flex-row md:items-center md:justify-between">
        <div class="min-w-0">
          <div class="sr-mtr-label">{baseline_note_label(@comparison)}</div>
          <div class="sr-mtr-title mt-1 text-sm font-medium">
            {baseline_note_text(@comparison)}
          </div>
        </div>
        <.ui_button
          :if={@state.preset == preset_today_vs_yesterday()}
          navigate={compare_elapsed_path(@state)}
          size="xs"
          variant="outline"
          class="shrink-0"
        >
          Compare same hours
        </.ui_button>
      </div>
    </div>
    """
  end

  attr(:side, :atom, required: true)
  attr(:state, :map, required: true)
  attr(:summary, :map, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  defp window_summary_header(assigns) do
    ~H"""
    <.link
      navigate={diagnostics_window_path(@state, @side)}
      class="sr-mtr-card sr-mtr-clickable-card block p-4"
      title={"View #{@summary.label} traces"}
    >
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0">
          <div class="sr-mtr-label">{@summary.label}</div>
          <div class="sr-mtr-title mt-1 text-lg font-semibold">
            <.user_time
              id={"mtr-compare-window-#{@side}-start-time"}
              value={@summary.start}
              timezone={@timezone}
              style={:compact}
            /> to
            <.user_time
              id={"mtr-compare-window-#{@side}-end-time"}
              value={@summary.end}
              timezone={@timezone}
              style={:compact}
            />
          </div>
          <div class="sr-mtr-muted mt-1 text-sm">
            {@summary.trace_count} traces, {@summary.agent_count} agents, {@summary.target_count} targets
          </div>
        </div>
        <div class="flex shrink-0 flex-col items-end gap-3">
          <div
            class={[
              "radial-progress sr-mtr-radial text-sm font-semibold",
              reachability_radial_class(@summary.success_rate)
            ]}
            style={"--value: #{radial_value(@summary.success_rate)};"}
            role="progressbar"
            aria-label={"#{@summary.label} reachability"}
          >
            {radial_value(@summary.success_rate)}%
          </div>
          <div class="pointer-events-none inline-flex min-h-9 items-center justify-center rounded-sr-control border border-sr-line-strong px-3 text-sm font-semibold text-sr-ink">
            View Traces
          </div>
        </div>
      </div>
    </.link>
    """
  end

  attr(:label, :string, required: true)
  attr(:id, :string, default: nil)
  attr(:a_value, :any, required: true)
  attr(:b_value, :any, required: true)
  attr(:delta, :any, required: true)
  attr(:unit, :string, default: "")
  attr(:higher_is_better, :boolean, default: true)
  attr(:a_path, :string, required: true)
  attr(:b_path, :string, required: true)

  defp compare_metric_card(assigns) do
    ~H"""
    <div id={@id} class="sr-mtr-card p-4">
      <div class="sr-mtr-label">{@label}</div>
      <div class="mt-3 grid grid-cols-2 gap-3">
        <.link
          navigate={@a_path}
          class="sr-mtr-metric-link block rounded-md p-2"
          title={"View Window A traces for #{@label}"}
        >
          <div class="sr-mtr-muted text-xs">Window A</div>
          <div class="sr-mtr-value text-2xl">{@a_value}</div>
        </.link>
        <.link
          navigate={@b_path}
          class="sr-mtr-metric-link block rounded-md p-2"
          title={"View Window B traces for #{@label}"}
        >
          <div class="sr-mtr-muted text-xs">Window B</div>
          <div class="sr-mtr-value text-2xl">{@b_value}</div>
        </.link>
      </div>
      <.ui_badge
        size="sm"
        variant={delta_badge_variant(@delta, @higher_is_better)}
        class="mt-3 sr-mtr-metric-delta"
      >
        {format_delta(@delta, @unit)}
      </.ui_badge>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:state, :map, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  defp window_timeline(assigns) do
    ~H"""
    <div class="sr-mtr-panel p-4">
      <div class="flex items-center justify-between gap-3">
        <h3 class="sr-mtr-title font-semibold">{@title} Availability Timeline</h3>
        <div class="sr-mtr-muted text-xs">left to right</div>
      </div>
      <div class="sr-mtr-outcome-strip mt-4" role="list">
        <.link
          :for={{row, row_index} <- Enum.with_index(@rows)}
          navigate={diagnostics_bucket_path(row, @state)}
          role="listitem"
          class={["group relative sr-mtr-outcome-dot", timeline_bucket_class(row)]}
        >
          <span
            role="tooltip"
            class="pointer-events-none absolute bottom-full left-1/2 z-40 mb-2 flex w-max -translate-x-1/2 items-center gap-1 rounded border border-sr-line bg-sr-raised px-2 py-1 text-xs text-sr-ink opacity-0 shadow-sr-raised transition-opacity group-hover:opacity-100 group-focus-visible:opacity-100"
          >
            <.user_time
              id={"mtr-compare-bucket-#{bucket_identity(row, row_index)}-start-time"}
              value={Map.get(row, "bucket_start")}
              timezone={@timezone}
              style={:compact}
            /> to
            <.user_time
              id={"mtr-compare-bucket-#{bucket_identity(row, row_index)}-end-time"}
              value={Map.get(row, "bucket_end")}
              timezone={@timezone}
              style={:compact}
            />: {timeline_bucket_counts(row)}
          </span>
        </.link>
      </div>
      <div class="mt-3 flex flex-wrap gap-3 text-xs">
        <span class="sr-mtr-muted">Buckets {length(@rows)}</span>
        <span class="sr-mtr-muted">
          Empty {Enum.count(@rows, &((Map.get(&1, "trace_count") || 0) == 0))}
        </span>
      </div>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:signatures, :list, required: true)

  defp route_signature_panel(assigns) do
    ~H"""
    <div class="sr-mtr-panel p-4">
      <div class="flex items-center justify-between gap-3">
        <h3 class="sr-mtr-title font-semibold">{@title}</h3>
        <div class="sr-mtr-muted text-xs">most common first</div>
      </div>
      <div class="mt-4 space-y-3">
        <.link
          :for={signature <- Enum.filter(@signatures, & &1["representative_trace_id"])}
          navigate={~p"/diagnostics/mtr/#{signature["representative_trace_id"]}"}
          class="sr-mtr-subpanel sr-mtr-clickable-card block p-3"
          title="Inspect representative trace"
        >
          <div class="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
            <div class="min-w-0">
              <div class="font-mono text-xs sr-mtr-title break-words">
                {signature["path_preview"]}
              </div>
              <div class="sr-mtr-muted mt-1 text-xs">
                {signature["trace_count"]} traces, {signature["agent_count"]} agents
              </div>
            </div>
            <div class="pointer-events-none inline-flex min-h-7 shrink-0 items-center justify-center rounded-sr-control border border-sr-line-strong px-2 text-xs font-semibold text-sr-ink">
              Inspect
            </div>
          </div>
        </.link>
        <div
          :for={signature <- Enum.reject(@signatures, & &1["representative_trace_id"])}
          class="sr-mtr-subpanel p-3"
        >
          <div class="font-mono text-xs sr-mtr-title break-words">
            {signature["path_preview"]}
          </div>
          <div class="sr-mtr-muted mt-1 text-xs">
            {signature["trace_count"]} traces, {signature["agent_count"]} agents
          </div>
        </div>
        <div :if={@signatures == []} class="sr-mtr-muted text-sm">
          No route signatures in this window.
        </div>
      </div>
    </div>
    """
  end

  attr(:rows, :list, required: true)
  attr(:state, :map, required: true)

  defp agent_matrix(assigns) do
    ~H"""
    <div class="sr-mtr-panel p-4">
      <div class="flex items-center justify-between gap-3">
        <h3 class="sr-mtr-title font-semibold">Source Agent Comparison</h3>
        <div class="sr-mtr-muted text-xs">reachability by source</div>
      </div>
      <div class="mt-4 overflow-x-auto">
        <table class={ui_table_class(size: "sm", class: "sr-mtr-table")}>
          <thead>
            <tr>
              <th>Agent</th>
              <th class="text-right">Window A</th>
              <th class="text-right">Window B</th>
              <th class="text-right">Delta</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows}>
              <td class="font-mono text-xs">
                <.link
                  navigate={compare_agent_path(@state, row["agent_id"])}
                  class="text-sr-brand hover:underline sr-mtr-title"
                  title={"Compare only #{row["agent_id"]}"}
                >
                  {row["agent_id"]}
                </.link>
              </td>
              <td class="text-right">
                <.link
                  navigate={diagnostics_agent_window_path(@state, :a, row["agent_id"])}
                  class="text-sr-brand hover:underline sr-mtr-title"
                  title={"View Window A traces for #{row["agent_id"]}"}
                >
                  {format_percent(row["a_success_rate"])} ({row["a_trace_count"]})
                </.link>
              </td>
              <td class="text-right">
                <.link
                  navigate={diagnostics_agent_window_path(@state, :b, row["agent_id"])}
                  class="text-sr-brand hover:underline sr-mtr-title"
                  title={"View Window B traces for #{row["agent_id"]}"}
                >
                  {format_percent(row["b_success_rate"])} ({row["b_trace_count"]})
                </.link>
              </td>
              <td class="text-right">
                <.ui_badge
                  size="sm"
                  variant={
                    delta_badge_variant(
                      (row["a_success_rate"] || 0) - (row["b_success_rate"] || 0),
                      true
                    )
                  }
                >
                  {format_delta((row["a_success_rate"] || 0) - (row["b_success_rate"] || 0), "points")}
                </.ui_badge>
              </td>
            </tr>
            <tr :if={@rows == []}>
              <td colspan="4" class="sr-mtr-muted text-center py-4">
                No source-agent data in the selected windows.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp default_window_state do
    window_state_from_params(%{})
  end

  defp window_state_from_params(params) do
    preset = normalize_preset(Map.get(params, "preset"))
    now = DateTime.truncate(DateTime.utc_now(), :second)
    {window_a, window_b} = preset_windows(preset, params, now)

    %{
      preset: preset,
      target_filter: normalize_text(Map.get(params, "target")),
      agent_filter: normalize_text(Map.get(params, "agent")),
      protocol: normalize_protocol(Map.get(params, "protocol")),
      reached: normalize_reached(Map.get(params, "reached")),
      window_a: window_a,
      window_b: window_b
    }
  end

  defp preset_windows(@preset_today_vs_yesterday, _params, now) do
    today_start = start_of_utc_day(now)
    yesterday_start = DateTime.add(today_start, -1, :day)

    {
      %{label: "Today so far", start: today_start, end: now},
      %{label: "Yesterday full day", start: yesterday_start, end: today_start}
    }
  end

  defp preset_windows(@preset_today_vs_yesterday_elapsed, _params, now) do
    today_start = start_of_utc_day(now)
    elapsed = max(DateTime.diff(now, today_start, :second), 60)
    yesterday_start = DateTime.add(today_start, -1, :day)

    {
      %{label: "Today so far", start: today_start, end: now},
      %{label: "Yesterday same hours", start: yesterday_start, end: DateTime.add(yesterday_start, elapsed, :second)}
    }
  end

  defp preset_windows(@preset_last_6h, _params, now), do: rolling_windows(now, 6, "Last 6 hours", "Previous 6 hours")

  defp preset_windows(@preset_last_24h, _params, now), do: rolling_windows(now, 24, "Last 24 hours", "Previous 24 hours")

  defp preset_windows(@preset_custom, params, now) do
    {fallback_a, fallback_b} = rolling_windows(now, 6, "Window A", "Window B")

    {
      ensure_valid_window(
        %{
          label: "Window A",
          start: parse_param_datetime(Map.get(params, "a_start"), fallback_a.start),
          end: parse_param_datetime(Map.get(params, "a_end"), fallback_a.end)
        },
        fallback_a
      ),
      ensure_valid_window(
        %{
          label: "Window B",
          start: parse_param_datetime(Map.get(params, "b_start"), fallback_b.start),
          end: parse_param_datetime(Map.get(params, "b_end"), fallback_b.end)
        },
        fallback_b
      )
    }
  end

  defp rolling_windows(now, hours, label_a, label_b) do
    seconds = hours * 3600
    a_start = DateTime.add(now, -seconds, :second)
    b_end = a_start
    b_start = DateTime.add(b_end, -seconds, :second)

    {
      %{label: label_a, start: a_start, end: now},
      %{label: label_b, start: b_start, end: b_end}
    }
  end

  defp start_of_utc_day(%DateTime{} = dt) do
    dt
    |> DateTime.to_date()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp ensure_valid_window(%{start: start_time, end: end_time} = window, fallback) do
    if DateTime.before?(start_time, end_time), do: window, else: fallback
  end

  defp parse_param_datetime(nil, fallback), do: fallback
  defp parse_param_datetime("", fallback), do: fallback

  defp parse_param_datetime(value, fallback) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        fallback

      String.ends_with?(value, "Z") ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
          {:error, _} -> fallback
        end

      true ->
        value
        |> String.replace(" ", "T")
        |> then(fn normalized ->
          normalized =
            if Regex.match?(~r/T\d\d:\d\d$/, normalized), do: normalized <> ":00", else: normalized

          case NaiveDateTime.from_iso8601(normalized) do
            {:ok, ndt} -> ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)
            {:error, _} -> fallback
          end
        end)
    end
  end

  defp normalize_mode(@mode_trace, _params), do: @mode_trace
  defp normalize_mode(@mode_window, _params), do: @mode_window
  defp normalize_mode(_mode, %{"a" => a, "b" => b}) when is_binary(a) and is_binary(b), do: @mode_trace
  defp normalize_mode(_mode, _params), do: @mode_window

  defp normalize_preset(value)
       when value in [
              @preset_today_vs_yesterday,
              @preset_today_vs_yesterday_elapsed,
              @preset_last_6h,
              @preset_last_24h,
              @preset_custom
            ], do: value

  defp normalize_preset(_), do: @preset_today_vs_yesterday

  defp normalize_text(nil), do: ""
  defp normalize_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_text(value), do: value |> to_string() |> String.trim()

  defp normalize_protocol(value) when value in @protocols, do: value
  defp normalize_protocol(_), do: ""

  defp normalize_reached(value) when value in @reached_filters, do: value
  defp normalize_reached(_), do: ""

  defp maybe_put_custom_window_params(%{"preset" => @preset_custom} = params, window_params) do
    params
    |> Map.put("a_start", Map.get(window_params, "a_start", ""))
    |> Map.put("a_end", Map.get(window_params, "a_end", ""))
    |> Map.put("b_start", Map.get(window_params, "b_start", ""))
    |> Map.put("b_end", Map.get(window_params, "b_end", ""))
  end

  defp maybe_put_custom_window_params(params, _window_params), do: params

  defp reject_blank_params(params) do
    params
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp compare_path(params) do
    params = reject_blank_params(params)
    query = URI.encode_query(params)
    if query == "", do: ~p"/diagnostics/mtr/compare", else: "/diagnostics/mtr/compare?#{query}"
  end

  defp diagnostics_window_path(state, side) do
    window = if side == :a, do: state.window_a, else: state.window_b
    query = diagnostics_query(window, state)
    "/diagnostics/mtr?#{URI.encode_query(%{"q" => query, "limit" => 50})}"
  end

  defp diagnostics_agent_window_path(state, side, agent_id) do
    state
    |> Map.put(:agent_filter, normalize_text(agent_id))
    |> diagnostics_window_path(side)
  end

  defp compare_agent_path(state, agent_id) do
    state
    |> window_state_to_params()
    |> Map.put("agent", normalize_text(agent_id))
    |> compare_path()
  end

  defp compare_elapsed_path(state) do
    state
    |> Map.put(:preset, @preset_today_vs_yesterday_elapsed)
    |> window_state_to_params()
    |> compare_path()
  end

  defp diagnostics_bucket_path(row, state) do
    window = %{
      start: Map.get(row, "bucket_start"),
      end: Map.get(row, "bucket_end")
    }

    query = diagnostics_query(window, state)
    "/diagnostics/mtr?#{URI.encode_query(%{"q" => query, "limit" => 50})}"
  end

  defp diagnostics_query(window, state) do
    [
      "in:mtr_traces",
      "time:[#{DateTime.to_iso8601(window.start)},#{DateTime.to_iso8601(window.end)}]",
      if(state.target_filter == "", do: nil, else: "target:#{state.target_filter}"),
      if(state.agent_filter == "", do: nil, else: "agent_id:#{state.agent_filter}"),
      if(state.protocol == "", do: nil, else: "protocol:#{state.protocol}"),
      if(state.reached == "reached", do: "target_reached:true"),
      if(state.reached == "unreachable", do: "target_reached:false"),
      "sort:time:desc"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp window_state_to_params(state) do
    maybe_put_custom_state_window_params(
      %{
        "mode" => @mode_window,
        "preset" => state.preset,
        "target" => state.target_filter,
        "agent" => state.agent_filter,
        "protocol" => state.protocol,
        "reached" => state.reached
      },
      state
    )
  end

  defp maybe_put_custom_state_window_params(%{"preset" => @preset_custom} = params, state) do
    params
    |> Map.put("a_start", window_param_value(state.window_a.start))
    |> Map.put("a_end", window_param_value(state.window_a.end))
    |> Map.put("b_start", window_param_value(state.window_b.start))
    |> Map.put("b_end", window_param_value(state.window_b.end))
  end

  defp maybe_put_custom_state_window_params(params, _state), do: params

  defp window_param_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp window_param_value(_), do: ""

  defp preset_options do
    [
      {"Today vs Yesterday Full Day", @preset_today_vs_yesterday},
      {"Today vs Yesterday Same Hours", @preset_today_vs_yesterday_elapsed},
      {"Rolling 6h vs Previous 6h", @preset_last_6h},
      {"Rolling 24h vs Previous 24h", @preset_last_24h},
      {"Custom Windows", @preset_custom}
    ]
  end

  defp protocol_options, do: @protocols
  defp reached_filter_options, do: @reached_filters
  defp mode_trace, do: @mode_trace
  defp mode_window, do: @mode_window
  defp preset_custom, do: @preset_custom
  defp preset_today_vs_yesterday, do: @preset_today_vs_yesterday

  defp reached_label("reached"), do: "Reached"
  defp reached_label("unreachable"), do: "Unreachable"
  defp reached_label(_), do: "Any"

  defp trace_option_label(t) do
    "#{t["target"]} (#{t["agent_id"]}) · #{short_trace_id(t["id"])}"
  end

  defp short_trace_id(id) when is_binary(id) and byte_size(id) > 8, do: String.slice(id, 0, 8)
  defp short_trace_id(id), do: to_string(id || "unknown")

  defp baseline_note_class(%{elapsed_aligned?: true}), do: "is-aligned"
  defp baseline_note_class(_comparison), do: "is-skewed"

  defp baseline_note_label(%{elapsed_aligned?: true}), do: "Elapsed-aligned comparison"
  defp baseline_note_label(_comparison), do: "Full-day baseline"

  defp baseline_note_text(%{elapsed_aligned?: true} = comparison) do
    "Both windows cover #{format_duration(window_duration_seconds(comparison.a))}, so deltas are normalized by elapsed time."
  end

  defp baseline_note_text(comparison) do
    "Window A covers #{format_duration(window_duration_seconds(comparison.a))}; Window B covers #{format_duration(window_duration_seconds(comparison.b))}. Deltas include different amounts of time, so use sample counts and trace drilldowns when judging severity."
  end

  defp window_duration_seconds(%{start: %DateTime{} = start_time, end: %DateTime{} = end_time}) do
    max(DateTime.diff(end_time, start_time, :second), 0)
  end

  defp window_duration_seconds(_window), do: 0

  defp format_duration(seconds) when is_integer(seconds) and seconds >= 86_400 do
    days = div(seconds, 86_400)
    hours = seconds |> rem(86_400) |> div(3600)

    case hours do
      0 -> "#{days}d"
      _ -> "#{days}d #{hours}h"
    end
  end

  defp format_duration(seconds) when is_integer(seconds) and seconds >= 3600 do
    hours = div(seconds, 3600)
    minutes = seconds |> rem(3600) |> div(60)

    case minutes do
      0 -> "#{hours}h"
      _ -> "#{hours}h #{minutes}m"
    end
  end

  defp format_duration(seconds) when is_integer(seconds), do: "#{max(div(seconds, 60), 1)}m"

  defp window_input_value(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%dT%H:%M")
  defp window_input_value(_), do: ""

  defp hop_addr(nil), do: "-"
  defp hop_addr(hop), do: hop["addr"] || "???"

  defp hop_val(nil, _key), do: "-"

  defp hop_val(hop, key) do
    case hop[key] do
      nil -> "-"
      0 -> "-"
      us when is_integer(us) and us >= 1000 -> "#{Float.round(us / 1000, 1)}ms"
      us when is_integer(us) -> "#{us}us"
      _ -> "-"
    end
  end

  defp hop_pct(nil, _key), do: "-"

  defp hop_pct(hop, key) do
    case hop[key] do
      nil -> "-"
      pct when is_float(pct) -> "#{Float.round(pct, 1)}%"
      pct when is_integer(pct) -> "#{pct}%"
      _ -> "-"
    end
  end

  defp format_percent(value) when is_integer(value) or is_float(value), do: "#{Float.round(value / 1, 1)}%"
  defp format_percent(_), do: "-"

  defp format_us(value) when value == 0, do: "0.0ms"
  defp format_us(value) when is_integer(value), do: format_us(value * 1.0)

  defp format_us(value) when is_float(value) do
    cond do
      value < 0 -> "-"
      value >= 1_000_000 -> "#{Float.round(value / 1_000_000, 1)}s"
      value >= 1_000 -> "#{Float.round(value / 1_000, 1)}ms"
      true -> "#{Float.round(value, 1)}us"
    end
  end

  defp format_us(_), do: "-"

  defp format_delta(delta, "latency_us") when delta == 0, do: "0us"

  defp format_delta(delta, "latency_us") when is_integer(delta) or is_float(delta) do
    sign = if delta > 0, do: "+", else: "-"
    formatted = delta |> abs() |> format_us()
    "#{sign}#{formatted}"
  end

  defp format_delta(delta, unit) when is_integer(delta) or is_float(delta) do
    sign = if delta > 0, do: "+", else: ""
    value = if is_float(delta), do: Float.round(delta, 1), else: delta
    suffix = if unit == "", do: "", else: " #{unit}"
    "#{sign}#{value}#{suffix}"
  end

  defp format_delta(_, _unit), do: "-"

  defp delta_badge_variant(delta, higher_is_better) when is_number(delta) do
    cond do
      delta == 0 -> "ghost"
      (delta > 0 and higher_is_better) or (delta < 0 and not higher_is_better) -> "success"
      true -> "error"
    end
  end

  defp delta_badge_variant(_delta, _higher_is_better), do: "ghost"

  defp timeline_bucket_class(row) do
    trace_count = Map.get(row, "trace_count") || 0
    reached_count = Map.get(row, "reached_count") || 0
    failed_count = Map.get(row, "failed_count") || 0

    cond do
      trace_count == 0 -> "is-empty"
      failed_count > 0 and reached_count == 0 -> "is-failed"
      failed_count > 0 -> "is-warning"
      true -> "is-reached"
    end
  end

  defp timeline_bucket_counts(row) do
    trace_count = Map.get(row, "trace_count") || 0
    reached_count = Map.get(row, "reached_count") || 0
    failed_count = Map.get(row, "failed_count") || 0

    "#{trace_count} traces, #{reached_count} reached, #{failed_count} failed"
  end

  defp stable_trace_identity(trace) do
    trace
    |> then(fn trace ->
      Enum.find(
        [Map.get(trace, "id"), Map.get(trace, "trace_id"), Map.get(trace, :id), Map.get(trace, :trace_id)],
        "unknown",
        &(&1 not in [nil, ""])
      )
    end)
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "unknown"
      identity -> identity
    end
  end

  defp bucket_identity(%{"bucket_start" => %DateTime{} = datetime}, _index), do: DateTime.to_unix(datetime, :millisecond)

  defp bucket_identity(%{"bucket_start" => %NaiveDateTime{} = datetime}, _index),
    do: datetime |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

  defp bucket_identity(_row, index), do: index

  defp radial_value(value) when is_integer(value) or is_float(value) do
    value
    |> max(0)
    |> min(100)
    |> round()
  end

  defp radial_value(_), do: 0

  defp reachability_radial_class(value) when is_integer(value) or is_float(value) do
    cond do
      value >= 95 -> ""
      value >= 80 -> "is-warning"
      true -> "is-error"
    end
  end

  defp reachability_radial_class(_), do: "is-error"

  defp diff_row_class(:changed), do: "bg-warning/10"
  defp diff_row_class(:added), do: "bg-info/10"
  defp diff_row_class(:removed), do: "bg-error/10"
  defp diff_row_class(_), do: ""

  defp diff_icon(:changed), do: Phoenix.HTML.raw(~s(<span class="text-warning" title="Changed">~</span>))
  defp diff_icon(:added), do: Phoenix.HTML.raw(~s(<span class="text-info" title="New hop">+</span>))
  defp diff_icon(:removed), do: Phoenix.HTML.raw(~s(<span class="text-error" title="Missing hop">-</span>))
  defp diff_icon(_), do: ""
end
