defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.MtrJobs do
  @moduledoc """
  MTR bulk jobs for the Active Scans tab.

  An MTR bulk job is an `mtr.bulk_run` agent command, not a sweep execution, so
  it has its own loader. Each command is normalized into a scan row with the
  same vocabulary the tab uses for sweeps (status, name, agent, start,
  duration, progress) plus the MTR-specific protocol set and reach count.
  """

  import Ash.Expr

  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Observability.MtrPolicy

  require Ash.Query

  @command_type "mtr.bulk_run"
  @active_statuses [:queued, :sent, :acknowledged, :running]
  @recent_limit 10

  @doc """
  MTR bulk jobs that have not reached a terminal state, newest first.

  Returns `:forbidden` when the viewer may not read agent commands, which a
  custom role profile can arrange even when it grants the sweep permissions.
  """
  @spec load_running(term()) :: {:ok, [map()]} | :forbidden
  def load_running(scope) do
    AgentCommand
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(expr(command_type == ^@command_type and status in ^@active_statuses))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(@recent_limit)
    |> read_rows(scope)
  end

  @doc "The most recent terminal MTR bulk jobs, newest first; see `load_running/1`."
  @spec load_recent(term()) :: {:ok, [map()]} | :forbidden
  def load_recent(scope) do
    AgentCommand
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(expr(command_type == ^@command_type and status not in ^@active_statuses))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(@recent_limit)
    |> read_rows(scope)
  end

  defp read_rows(query, scope) do
    case Ash.read(query, scope: scope) do
      {:ok, commands} -> {:ok, normalize_all(commands, policy_names(scope))}
      {:error, %Ash.Error.Forbidden{}} -> :forbidden
      {:error, _reason} -> {:ok, []}
    end
  end

  @doc "Normalizes commands into scan rows; `policy_names` maps policy id to name."
  @spec normalize_all([map()], map()) :: [map()]
  def normalize_all(commands, policy_names) do
    Enum.map(List.wrap(commands), &normalize(&1, policy_names))
  end

  @doc false
  def normalize(command, policy_names) do
    payload = field(command, :payload) || %{}
    context = field(command, :context) || %{}
    progress = latest_payload(command)
    targets = List.wrap(Map.get(payload, "targets"))
    protocols = protocols(payload, progress)
    policy_id = Map.get(context, "mtr_policy_id")

    %{
      kind: :mtr,
      id: to_string(field(command, :id)),
      status: field(command, :status),
      name: Map.get(policy_names, policy_id) || if(policy_id, do: "MTR profile", else: "Manual"),
      agent_id: field(command, :agent_id),
      protocols: protocols,
      started_at: field(command, :started_at) || field(command, :inserted_at),
      completed_at: field(command, :completed_at),
      duration_ms: int(Map.get(progress, "duration_ms")),
      total: int(Map.get(progress, "total_targets")) || length(targets) * max(length(protocols), 1),
      completed: int(Map.get(progress, "completed_targets")) || 0,
      failed: int(Map.get(progress, "failed_targets")) || 0,
      timed_out: int(Map.get(progress, "timed_out_targets")) || 0,
      reached: int(Map.get(progress, "reached_targets")),
      progress_percent: field(command, :progress_percent) || 0,
      message: field(command, :message)
    }
  end

  @doc "Terminal jobs that finished with at least one failed target count as degraded."
  @spec status_variant(map()) :: String.t()
  def status_variant(%{status: :completed, failed: failed}) when failed > 0, do: "warning"
  def status_variant(%{status: :completed}), do: "success"
  def status_variant(%{status: status}) when status in [:failed, :expired, :offline], do: "error"
  def status_variant(%{status: :canceled}), do: "ghost"
  def status_variant(_row), do: "info"

  @doc "Display label for a job's status."
  @spec status_label(map()) :: String.t()
  def status_label(%{status: status}) when is_atom(status) and not is_nil(status),
    do: status |> Atom.to_string() |> String.capitalize()

  def status_label(_row), do: "Unknown"

  @doc "The protocol set shown for a job, e.g. \"ICMP + TCP\"."
  @spec protocol_label(map()) :: String.t()
  def protocol_label(%{protocols: []}), do: "ICMP"
  def protocol_label(%{protocols: protocols}), do: Enum.map_join(protocols, " + ", &String.upcase/1)

  # A job result carries the final counters; until then the latest progress
  # report does.
  defp latest_payload(command) do
    case field(command, :result_payload) do
      %{"total_targets" => _} = result -> result
      _ -> field(command, :progress_payload) || %{}
    end
  end

  defp protocols(payload, progress) do
    names =
      case Map.get(progress, "protocols") || Map.get(payload, "protocols") do
        [_ | _] = protocols -> protocols
        _ -> List.wrap(Map.get(payload, "protocol"))
      end

    names
    |> Enum.map(&(&1 |> to_string() |> String.downcase()))
    |> then(fn names -> Enum.filter(["icmp", "udp", "tcp"], &(&1 in names)) end)
  end

  defp policy_names(scope) do
    case Ash.read(MtrPolicy, scope: scope) do
      {:ok, policies} -> Map.new(policies, &{to_string(&1.id), &1.name})
      {:error, _reason} -> %{}
    end
  end

  defp field(record, key), do: Map.get(record, key)

  defp int(value) when is_integer(value), do: value
  defp int(value) when is_float(value), do: round(value)
  defp int(_value), do: nil
end
