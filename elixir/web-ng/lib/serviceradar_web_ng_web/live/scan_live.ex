defmodule ServiceRadarWebNGWeb.ScanLive do
  @moduledoc """
  Ad-hoc network scan console.

  Paste or upload a list of IPs, choose modes (ICMP / TCP+ports / MTR) and the
  egress agent, and run an on-demand scan. Results stream into a table backed by
  the durable `adhoc_scan_results` store; runs are RBAC-gated. When the
  inventory-scoping policy is enabled, targets not already in inventory are
  blocked with a bulk "add missing" affordance.
  """
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Scans.ScanPolicySettings
  alias ServiceRadar.Scans.ScanResult
  alias ServiceRadar.Scans.ScanRun
  alias ServiceRadarWebNG.Devices.ManualDeviceCreator
  alias ServiceRadarWebNG.RBAC

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "scans.read") do
      if connected?(socket), do: Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "agent:commands")

      {:ok,
       socket
       |> assign(:page_title, "Ad-hoc Scan")
       |> assign(:page_path, "/scans")
       |> assign(:can_execute, RBAC.can?(scope, "scans.execute"))
       |> assign(:can_add_devices, RBAC.can_any?(scope, ["devices.create", "devices.import"]))
       |> assign(:agents, list_agents())
       |> assign(:restrict_to_inventory, restrict_to_inventory?(scope))
       |> assign(:form, default_form())
       |> assign(:valid_targets, [])
       |> assign(:invalid_targets, [])
       |> assign(:ports, [])
       |> assign(:missing_ips, [])
       |> assign(:running, false)
       |> assign(:scan_run, nil)
       |> assign(:scan_command_id, nil)
       |> assign(:results, [])
       |> assign(:runs, load_runs(scope))
       |> assign(:error, nil)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to view scans.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("validate", %{"scan" => params}, socket) do
    {:noreply, apply_form(socket, params)}
  end

  def handle_event("run_scan", %{"scan" => params}, socket) do
    scope = socket.assigns.current_scope

    if socket.assigns.can_execute do
      socket = apply_form(socket, params)
      run_scan(socket, scope)
    else
      {:noreply, assign(socket, :error, "You don't have permission to run scans.")}
    end
  end

  def handle_event("add_missing", _params, socket) do
    scope = socket.assigns.current_scope

    if socket.assigns.can_add_devices do
      {added, failed} =
        Enum.reduce(socket.assigns.missing_ips, {0, 0}, fn ip, {ok, bad} ->
          case ManualDeviceCreator.create(scope, %{ip: ip}) do
            {:ok, _} -> {ok + 1, bad}
            {:error, :already_exists} -> {ok + 1, bad}
            {:error, _} -> {ok, bad + 1}
          end
        end)

      {:noreply,
       socket
       |> assign(:missing_ips, [])
       |> put_flash(:info, "Added #{added} device(s) to inventory#{failed_suffix(failed)}.")}
    else
      {:noreply, assign(socket, :error, "You don't have permission to add devices.")}
    end
  end

  def handle_event("select_run", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    {:noreply, socket |> assign(:scan_run, get_run(scope, id)) |> assign(:results, load_results(scope, id))}
  end

  @impl true
  def handle_info({event, %{command_type: "scan.run_adhoc"} = msg}, socket)
      when event in [:command_progress, :command_result] do
    command_id = Map.get(msg, :command_id) || Map.get(msg, "command_id")

    if is_binary(command_id) and command_id == socket.assigns.scan_command_id do
      running? = event != :command_result
      Process.send_after(self(), :refresh_scan, 400)
      {:noreply, assign(socket, :running, running?)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh_scan, socket) do
    scope = socket.assigns.current_scope

    case socket.assigns.scan_run do
      %{id: id} ->
        {:noreply,
         socket
         |> assign(:scan_run, get_run(scope, id))
         |> assign(:results, load_results(scope, id))
         |> assign(:runs, load_runs(scope))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- scan execution ---

  defp run_scan(socket, scope) do
    targets = socket.assigns.valid_targets
    modes = selected_modes(socket.assigns.form)
    agent_id = socket.assigns.form["agent_id"]

    cond do
      targets == [] ->
        {:noreply, assign(socket, :error, "Enter at least one valid target IP.")}

      modes == [] ->
        {:noreply, assign(socket, :error, "Select at least one scan mode.")}

      "tcp" in modes and socket.assigns.ports == [] ->
        {:noreply, assign(socket, :error, "TCP mode requires at least one port.")}

      to_string(agent_id) == "" ->
        {:noreply, assign(socket, :error, "Choose an agent to run the scan from.")}

      true ->
        case inventory_block(socket, scope, targets) do
          {:block, missing} ->
            {:noreply,
             socket
             |> assign(:missing_ips, missing)
             |> assign(:error, "#{length(missing)} target(s) are not in inventory.")}

          :ok ->
            create_and_dispatch(socket, scope, targets, modes, agent_id)
        end
    end
  end

  defp create_and_dispatch(socket, scope, targets, modes, agent_id) do
    attrs = %{
      agent_id: agent_id,
      modes: modes,
      ports: socket.assigns.ports,
      targets: targets,
      target_count: length(targets),
      options: scan_options(socket.assigns.form),
      requested_by: requested_by(scope)
    }

    with {:ok, run} <- ScanRun.create(attrs, actor: scope.user),
         {:ok, command_id} <-
           AgentCommandBus.dispatch_adhoc_scan(agent_id, targets,
             scan_run_id: run.id,
             modes: modes,
             ports: socket.assigns.ports,
             mtr_protocol: socket.assigns.form["mtr_protocol"],
             actor: scope.user
           ) do
      ScanRun.update_status(run, %{scan_command_id: command_id}, actor: scope.user)

      {:noreply,
       socket
       |> assign(:running, true)
       |> assign(:scan_run, run)
       |> assign(:scan_command_id, command_id)
       |> assign(:missing_ips, [])
       |> assign(:error, nil)
       |> assign(:results, [])
       |> put_flash(:info, "Scan queued for #{length(targets)} target(s).")}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :error, "Failed to start scan: #{inspect(reason)}")}
    end
  end

  defp inventory_block(socket, scope, targets) do
    if socket.assigns.restrict_to_inventory do
      missing = Enum.reject(targets, &ip_in_inventory?(&1, scope))
      if missing == [], do: :ok, else: {:block, missing}
    else
      :ok
    end
  end

  # --- data access ---

  defp list_agents do
    AgentCommandBus.list_online_agents()
  rescue
    _ -> []
  end

  defp restrict_to_inventory?(scope) do
    case ScanPolicySettings.get_settings(actor: scope.user) do
      {:ok, %{restrict_to_inventory: value}} -> value == true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp ip_in_inventory?(ip, scope) do
    case Device.get_by_ip(ip, false, actor: scope.user) do
      {:ok, nil} -> false
      {:ok, []} -> false
      {:ok, _} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp load_runs(scope) do
    case ScanRun.list_recent(actor: scope.user) do
      {:ok, runs} -> runs
      _ -> []
    end
  rescue
    _ -> []
  end

  defp get_run(scope, id) do
    case ScanRun.get(id, actor: scope.user) do
      {:ok, run} -> run
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp load_results(scope, id) do
    case ScanResult.by_scan_run(id, actor: scope.user) do
      {:ok, rows} -> Enum.sort_by(rows, &{&1.target_ip, &1.mode, &1.port})
      _ -> []
    end
  rescue
    _ -> []
  end

  # --- form parsing ---

  defp default_form do
    %{
      "targets" => "",
      "ports" => "",
      "agent_id" => "",
      "mode_icmp" => "true",
      "mode_tcp" => "false",
      "mode_mtr" => "false",
      "mtr_protocol" => "icmp"
    }
  end

  defp apply_form(socket, params) do
    form = Map.merge(socket.assigns.form, params)
    {valid, invalid} = parse_targets(form["targets"])

    socket
    |> assign(:form, form)
    |> assign(:valid_targets, valid)
    |> assign(:invalid_targets, invalid)
    |> assign(:ports, parse_ports(form["ports"]))
    |> assign(:error, nil)
  end

  defp parse_targets(text) when is_binary(text) do
    text
    |> String.split(~r/[\s,;]+/, trim: true)
    |> Enum.uniq()
    |> Enum.split_with(&valid_target?/1)
  end

  defp parse_targets(_), do: {[], []}

  defp valid_target?(entry) do
    {host, _cidr} =
      case String.split(entry, "/", parts: 2) do
        [h, c] -> {h, c}
        [h] -> {h, nil}
      end

    match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))
  end

  defp parse_ports(text) when is_binary(text) do
    text
    |> String.split(~r/[\s,;]+/, trim: true)
    |> Enum.map(&parse_port/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp parse_ports(_), do: []

  defp parse_port(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 and n <= 65_535 -> n
      _ -> nil
    end
  end

  defp selected_modes(form) do
    [{"icmp", "mode_icmp"}, {"tcp", "mode_tcp"}, {"mtr", "mode_mtr"}]
    |> Enum.filter(fn {_mode, key} -> form[key] == "true" end)
    |> Enum.map(&elem(&1, 0))
  end

  defp scan_options(form) do
    %{"mtr_protocol" => form["mtr_protocol"] || "icmp"}
  end

  defp requested_by(scope) do
    user = scope.user
    to_string(Map.get(user, :email) || Map.get(user, :id) || "")
  end

  defp failed_suffix(0), do: ""
  defp failed_suffix(n), do: " (#{n} failed)"

  # --- render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 space-y-6 max-w-6xl mx-auto">
      <div>
        <h1 class="text-2xl font-bold">Ad-hoc Network Scan</h1>
        <p class="text-sm opacity-70">
          Scan a list of IPs from a chosen agent using ICMP, TCP ports, and/or MTR.
        </p>
      </div>

      <div :if={@error} class="alert alert-error text-sm">{@error}</div>

      <div :if={@missing_ips != []} class="alert alert-warning flex-col items-start gap-2 text-sm">
        <div>
          These targets are not in inventory (scanning is restricted to known devices):
          <span class="font-mono">{Enum.join(Enum.take(@missing_ips, 20), ", ")}</span>
          <span :if={length(@missing_ips) > 20}>… (+{length(@missing_ips) - 20} more)</span>
        </div>
        <button
          :if={@can_add_devices}
          type="button"
          phx-click="add_missing"
          class="btn btn-sm btn-primary"
        >
          Add {length(@missing_ips)} missing device(s) to inventory
        </button>
      </div>

      <.form for={%{}} as={:scan} phx-change="validate" phx-submit="run_scan" class="space-y-4">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div class="form-control">
            <label class="label">
              <span class="label-text">Targets (IP per line or comma-separated)</span>
            </label>
            <textarea
              name="scan[targets]"
              rows="6"
              class="textarea textarea-bordered font-mono text-sm"
              placeholder="10.0.0.1&#10;10.0.0.2&#10;192.168.1.0/24"
            >{@form["targets"]}</textarea>
            <label class="label">
              <span class="label-text-alt">
                {length(@valid_targets)} valid
                <span :if={@invalid_targets != []} class="text-error">
                  · {length(@invalid_targets)} invalid
                </span>
              </span>
            </label>
          </div>

          <div class="space-y-3">
            <div class="form-control">
              <label class="label"><span class="label-text">Egress agent</span></label>
              <select name="scan[agent_id]" class="select select-bordered">
                <option value="">Select an agent…</option>
                <option
                  :for={agent <- @agents}
                  value={agent_id(agent)}
                  selected={@form["agent_id"] == agent_id(agent)}
                >
                  {agent_id(agent)}
                </option>
              </select>
            </div>

            <div class="flex gap-4">
              <label class="label cursor-pointer gap-2">
                <input type="hidden" name="scan[mode_icmp]" value="false" />
                <input
                  type="checkbox"
                  name="scan[mode_icmp]"
                  value="true"
                  checked={@form["mode_icmp"] == "true"}
                  class="checkbox checkbox-sm"
                />
                <span class="label-text">ICMP</span>
              </label>
              <label class="label cursor-pointer gap-2">
                <input type="hidden" name="scan[mode_tcp]" value="false" />
                <input
                  type="checkbox"
                  name="scan[mode_tcp]"
                  value="true"
                  checked={@form["mode_tcp"] == "true"}
                  class="checkbox checkbox-sm"
                />
                <span class="label-text">TCP</span>
              </label>
              <label class="label cursor-pointer gap-2">
                <input type="hidden" name="scan[mode_mtr]" value="false" />
                <input
                  type="checkbox"
                  name="scan[mode_mtr]"
                  value="true"
                  checked={@form["mode_mtr"] == "true"}
                  class="checkbox checkbox-sm"
                />
                <span class="label-text">MTR</span>
              </label>
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">TCP ports (comma-separated)</span></label>
              <input
                name="scan[ports]"
                value={@form["ports"]}
                placeholder="22, 80, 443"
                class="input input-bordered input-sm"
              />
            </div>
          </div>
        </div>

        <button type="submit" disabled={not @can_execute or @running} class="btn btn-primary">
          {if @running, do: "Scanning…", else: "Run scan"}
        </button>
      </.form>

      <div :if={@scan_run} class="card bg-base-200">
        <div class="card-body p-4">
          <h2 class="card-title text-base">
            Run {String.slice(to_string(@scan_run.id), 0, 8)}
            <span class="badge badge-sm">{@scan_run.status}</span>
          </h2>
          <div class="text-sm opacity-70">
            {@scan_run.target_count} targets · {@scan_run.hosts_up} up · {@scan_run.ports_open} ports open
          </div>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Target</th>
                  <th>Mode</th>
                  <th>Port</th>
                  <th>Available</th>
                  <th>RTT (ms)</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @results}>
                  <td class="font-mono">{row.target_ip}</td>
                  <td>{row.mode}</td>
                  <td>{row.port}</td>
                  <td>
                    <span class={"badge badge-sm " <> if(row.available, do: "badge-success", else: "badge-ghost")}>
                      {if row.available, do: "yes", else: "no"}
                    </span>
                  </td>
                  <td>{format_ms(row.response_ms)}</td>
                </tr>
                <tr :if={@results == []}>
                  <td colspan="5" class="text-center opacity-60">No results yet.</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <div>
        <h2 class="text-lg font-semibold mb-2">Recent runs</h2>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Started</th>
                <th>Agent</th>
                <th>Modes</th>
                <th>Targets</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={run <- @runs}>
                <td>{format_time(run.inserted_at)}</td>
                <td class="font-mono">{run.agent_id}</td>
                <td>{Enum.join(run.modes, ", ")}</td>
                <td>{run.target_count}</td>
                <td><span class="badge badge-sm">{run.status}</span></td>
                <td>
                  <button
                    type="button"
                    phx-click="select_run"
                    phx-value-id={run.id}
                    class="btn btn-xs btn-ghost"
                  >
                    View
                  </button>
                </td>
              </tr>
              <tr :if={@runs == []}>
                <td colspan="6" class="text-center opacity-60">No scans yet.</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp agent_id(agent) when is_map(agent), do: Map.get(agent, :agent_id) || Map.get(agent, "agent_id")
  defp agent_id(agent) when is_binary(agent), do: agent
  defp agent_id(_), do: ""

  defp format_ms(nil), do: "—"
  defp format_ms(ms) when is_number(ms), do: :erlang.float_to_binary(ms / 1.0, decimals: 1)
  defp format_ms(_), do: "—"

  defp format_time(nil), do: "—"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_time(_), do: "—"
end
