defmodule ServiceRadar.SweepJobs.AgentAssignment do
  @moduledoc """
  Canonical normalization and compatibility helpers for sweep-group agent assignments.

  An empty list means every agent in the group partition. A non-empty list means
  exactly the selected agent UIDs.
  """

  @spec normalize(term()) :: [String.t()]
  def normalize(nil), do: []

  def normalize(values) when is_list(values) do
    if Enum.all?(values, &scalar?/1) do
      values
      |> Enum.map(&normalized_scalar/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()
    else
      []
    end
  end

  def normalize(value) do
    if scalar?(value) do
      case normalized_scalar(value) do
        "" -> []
        normalized -> [normalized]
      end
    else
      []
    end
  end

  @spec member?([String.t()], term()) :: boolean()
  def member?(_agent_ids, nil), do: false

  def member?(agent_ids, requester) do
    normalized_agent_ids = normalize(agent_ids)

    case normalize(requester) do
      [agent_id] -> normalized_agent_ids == [] or agent_id in normalized_agent_ids
      [] -> false
    end
  end

  @spec newly_added([String.t()], [String.t()]) :: [String.t()]
  def newly_added(incoming, stored), do: normalize(incoming) -- normalize(stored)

  @spec scalar_mirror([String.t()]) :: String.t() | nil
  def scalar_mirror(agent_ids) do
    case normalize(agent_ids) do
      [agent_id | _rest] -> agent_id
      [] -> nil
    end
  end

  defp scalar?(value),
    do: is_binary(value) or is_atom(value) or is_integer(value) or is_float(value)

  defp normalized_scalar(value), do: value |> to_string() |> String.trim()
end
