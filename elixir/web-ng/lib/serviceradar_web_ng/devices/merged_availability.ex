defmodule ServiceRadarWebNG.Devices.MergedAvailability do
  @moduledoc """
  Reads a device's canonical availability (`add-merged-device-availability`, design
  Decision 9) for the pages and the device API.

  Core's resolver owns `ocsf_devices.availability_state` and its provenance, conflict
  flag and per-agent summary. Web-ng computes no availability of its own: the badge,
  the "up from N of M agents" summary and the negative-control indicators are read
  from those columns, the same value SRQL sorts and counts by.

  `availability_agents` is written only by the resolver, so it is `nil` for a device the
  resolver has not decided yet; callers render no agent summary then.
  """

  import Ecto.Query

  alias ServiceRadarWebNG.Repo

  @states %{"available" => :available, "unavailable" => :unavailable, "unknown" => :unknown}
  @agent_counters ~w(up down stale total blocked_verified policy_violation inconclusive_control)

  @type state :: :available | :unavailable | :unknown

  @type t :: %{
          state: state(),
          decided_by: map() | nil,
          changed_at: DateTime.t() | nil,
          conflict: boolean(),
          agents: map() | nil
        }

  @doc """
  Loads the canonical availability of `device_uids`, keyed by uid. Uids that match no
  device are absent. The caller has already authorized the devices it lists.
  """
  @spec load([String.t()]) :: %{String.t() => t()}
  def load(device_uids) when is_list(device_uids) do
    case device_uids |> Enum.filter(&is_binary/1) |> Enum.uniq() do
      [] ->
        %{}

      uids ->
        from(d in "ocsf_devices",
          where: field(d, :uid) in ^uids,
          select: %{
            uid: field(d, :uid),
            availability_state: field(d, :availability_state),
            availability_decided_by: field(d, :availability_decided_by),
            availability_changed_at: field(d, :availability_changed_at),
            availability_conflict: field(d, :availability_conflict),
            availability_agents: field(d, :availability_agents)
          }
        )
        |> Repo.all()
        |> Map.new(&{&1.uid, from_columns(&1)})
    end
  end

  @doc "Builds the summary from the `availability_*` columns, atom- or string-keyed."
  @spec from_columns(map()) :: t()
  def from_columns(columns) when is_map(columns) do
    %{
      state: state(column(columns, :availability_state)),
      decided_by: map_or_nil(column(columns, :availability_decided_by)),
      changed_at: datetime(column(columns, :availability_changed_at)),
      conflict: column(columns, :availability_conflict) == true,
      agents: agents(column(columns, :availability_agents))
    }
  end

  @doc "The canonical state from its stored text; anything else reads as `:unknown`."
  @spec state(term()) :: state()
  def state(value) when is_atom(value) and value in [:available, :unavailable, :unknown], do: value
  def state(value) when is_binary(value), do: Map.get(@states, value, :unknown)
  def state(_value), do: :unknown

  @doc """
  The per-agent reachability shown next to the badge, or `nil` when the resolver has
  not summarized the device's agents (not decided yet) or no agent probes it and
  no negative control is expected.

  `partial?` is set whenever a fresh non-control agent cannot reach the device, so the
  merged badge never hides that result.
  """
  @spec reachability(t() | map() | nil) :: map() | nil
  def reachability(%{agents: agents}), do: reachability(agents)

  def reachability(agents) when is_map(agents) do
    counters = agents(agents)

    if counters["total"] > 0 or counters["blocked_verified"] > 0 or
         counters["policy_violation"] > 0 do
      %{
        up: counters["up"],
        down: counters["down"],
        total: counters["total"],
        partial?: counters["down"] > 0,
        blocked_verified: counters["blocked_verified"],
        policy_violation: counters["policy_violation"],
        inconclusive_control: counters["inconclusive_control"]
      }
    end
  end

  def reachability(_agents), do: nil

  @doc """
  The availability fields the device API returns next to `is_available`: the state
  (the only source of `unknown`), its provenance, conflict flag, change time and agent
  counters.
  """
  @spec api_fields(t() | nil) :: map()
  def api_fields(nil), do: api_fields(%{state: :unknown, decided_by: nil, changed_at: nil, conflict: false, agents: nil})

  def api_fields(summary) do
    %{
      "availability_state" => Atom.to_string(summary.state),
      "availability_decided_by" => summary.decided_by,
      "availability_changed_at" => summary.changed_at,
      "availability_conflict" => summary.conflict,
      "availability_agents" => summary.agents
    }
  end

  defp agents(value) when is_map(value) do
    Map.new(@agent_counters, fn key -> {key, counter(Map.get(value, key))} end)
  end

  defp agents(_value), do: nil

  defp counter(value) when is_integer(value) and value >= 0, do: value
  defp counter(_value), do: 0

  defp column(columns, key), do: Map.get(columns, key, Map.get(columns, Atom.to_string(key)))

  defp map_or_nil(value) when is_map(value), do: value
  defp map_or_nil(_value), do: nil

  defp datetime(%DateTime{} = value), do: value
  defp datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
          _ -> nil
        end
    end
  end

  defp datetime(_value), do: nil
end
