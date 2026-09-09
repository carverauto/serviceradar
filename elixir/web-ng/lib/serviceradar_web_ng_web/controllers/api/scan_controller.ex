defmodule ServiceRadarWebNGWeb.Api.ScanController do
  @moduledoc """
  REST API for ad-hoc network scans (external tools).

  * `POST /api/v1/scans` - start a scan (`scans.execute`)
  * `GET  /api/v1/scans/:id` - run status (`scans.read`)
  * `GET  /api/v1/scans/:id/results` - results (`scans.read`)

  Honors the inventory-scoping guardrail (409 with the offending IPs).
  """
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Scans.ScanPolicySettings
  alias ServiceRadar.Scans.ScanResult
  alias ServiceRadar.Scans.ScanRun
  alias ServiceRadarWebNG.RBAC

  @valid_modes ~w(icmp tcp mtr)

  def create(conn, params) do
    scope = conn.assigns[:current_scope]

    with :ok <- require_permission(scope, "scans.execute"),
         {:ok, agent_id} <- fetch_agent(params),
         {:ok, targets} <- fetch_targets(params),
         {:ok, modes} <- fetch_modes(params),
         ports = normalize_ports(params["ports"]),
         :ok <- validate_tcp_ports(modes, ports),
         :ok <- check_inventory(scope, targets) do
      attrs = %{
        agent_id: agent_id,
        modes: modes,
        ports: ports,
        targets: targets,
        target_count: length(targets),
        options: %{"mtr_protocol" => params["mtr_protocol"] || "icmp"}
      }

      case ScanRun.create(attrs, scope: scope) do
        {:ok, run} ->
          case AgentCommandBus.dispatch_adhoc_scan(agent_id, targets,
                 scan_run_id: run.id,
                 modes: modes,
                 ports: ports,
                 mtr_protocol: params["mtr_protocol"]
               ) do
            {:ok, command_id} ->
              ScanRun.update_status(run, %{scan_command_id: command_id}, scope: scope)

              conn
              |> put_status(:accepted)
              |> json(%{"id" => run.id, "status" => "pending", "command_id" => command_id})

            {:error, reason} ->
              ScanRun.update_status(run, %{status: :failed, error: inspect(reason)}, scope: scope)
              error(conn, :bad_gateway, "dispatch_failed", inspect(reason))
          end

        {:error, reason} ->
          error(conn, :unprocessable_entity, "invalid_scan", inspect(reason))
      end
    else
      {:error, :forbidden} -> error(conn, :forbidden, "forbidden", "missing scans.execute permission")
      {:error, {:blocked, missing}} -> blocked(conn, missing)
      {:error, code, message} -> error(conn, :bad_request, code, message)
    end
  end

  def show(conn, %{"id" => id}) do
    scope = conn.assigns[:current_scope]

    with :ok <- require_permission(scope, "scans.read"),
         {:ok, run} <- get_run(scope, id) do
      json(conn, %{"data" => run_to_map(run)})
    else
      {:error, :forbidden} -> error(conn, :forbidden, "forbidden", "missing scans.read permission")
      {:error, :not_found} -> error(conn, :not_found, "not_found", "scan not found")
    end
  end

  def results(conn, %{"id" => id}) do
    scope = conn.assigns[:current_scope]

    with :ok <- require_permission(scope, "scans.read"),
         {:ok, rows} <- get_results(scope, id) do
      json(conn, %{"data" => Enum.map(rows, &result_to_map/1)})
    else
      {:error, :forbidden} -> error(conn, :forbidden, "forbidden", "missing scans.read permission")
      {:error, :not_found} -> error(conn, :not_found, "not_found", "scan not found")
    end
  end

  # --- helpers ---

  defp require_permission(scope, permission) do
    if RBAC.can?(scope, permission), do: :ok, else: {:error, :forbidden}
  end

  defp fetch_agent(params) do
    case params["agent_id"] do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, "invalid_agent", "agent_id is required"}
    end
  end

  defp fetch_targets(params) do
    targets =
      params
      |> Map.get("targets", [])
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if targets == [], do: {:error, "invalid_targets", "at least one target is required"}, else: {:ok, targets}
  end

  defp fetch_modes(params) do
    modes =
      params
      |> Map.get("modes", ["icmp"])
      |> List.wrap()
      |> Enum.map(&(&1 |> to_string() |> String.downcase()))
      |> Enum.filter(&(&1 in @valid_modes))
      |> Enum.uniq()

    if modes == [], do: {:error, "invalid_modes", "at least one of icmp/tcp/mtr is required"}, else: {:ok, modes}
  end

  defp normalize_ports(ports) do
    ports
    |> List.wrap()
    |> Enum.map(fn
      p when is_integer(p) ->
        p

      p when is_binary(p) ->
        case Integer.parse(p) do
          {n, ""} -> n
          _ -> nil
        end

      _ ->
        nil
    end)
    |> Enum.filter(&(is_integer(&1) and &1 > 0 and &1 <= 65_535))
    |> Enum.uniq()
  end

  defp validate_tcp_ports(modes, ports) do
    if "tcp" in modes and ports == [], do: {:error, "missing_ports", "tcp mode requires ports"}, else: :ok
  end

  defp check_inventory(scope, targets) do
    if restrict?(scope) do
      missing = Enum.reject(targets, &ip_in_inventory?(&1, scope))
      if missing == [], do: :ok, else: {:error, {:blocked, missing}}
    else
      :ok
    end
  end

  defp restrict?(scope) do
    case ScanPolicySettings.get_settings(scope: scope) do
      {:ok, %{restrict_to_inventory: v}} -> v == true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp ip_in_inventory?(ip, scope) do
    # get_by_ip is an Ash read: {:ok, [Device.t()]} | {:error, _}, never {:ok, nil}.
    case Device.get_by_ip(ip, false, scope: scope) do
      {:ok, []} -> false
      {:ok, _} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp get_run(scope, id) do
    case ScanRun.get(id, scope: scope) do
      {:ok, run} when not is_nil(run) -> {:ok, run}
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  defp get_results(scope, id) do
    case ScanResult.by_scan_run(id, scope: scope) do
      {:ok, rows} -> {:ok, rows}
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  defp run_to_map(run) do
    %{
      "id" => run.id,
      "agent_id" => run.agent_id,
      "modes" => Enum.map(run.modes, &to_string/1),
      "ports" => run.ports,
      "target_count" => run.target_count,
      "status" => to_string(run.status),
      "hosts_up" => run.hosts_up,
      "ports_open" => run.ports_open,
      "started_at" => run.started_at,
      "finished_at" => run.finished_at
    }
  end

  defp result_to_map(row) do
    %{
      "target_ip" => row.target_ip,
      "mode" => row.mode,
      "port" => row.port,
      "available" => row.available,
      "response_ms" => row.response_ms,
      "service" => row.service,
      "time" => row.time
    }
  end

  defp blocked(conn, missing) do
    conn
    |> put_status(:conflict)
    |> json(%{"error" => "targets_not_in_inventory", "missing" => missing})
  end

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{"error" => code, "message" => message})
  end
end
