defmodule ServiceRadarAgentGateway.MediaSessionHelpers do
  @moduledoc false

  @spec agent_limit_exceeded?(map(), String.t(), pos_integer() | :infinity) :: boolean()
  def agent_limit_exceeded?(sessions, agent_id, limit) when is_map(sessions) do
    limit != :infinity and session_count_for_agent(sessions, agent_id) >= limit
  end

  @spec gateway_limit_exceeded?(map(), pos_integer() | :infinity) :: boolean()
  def gateway_limit_exceeded?(sessions, limit) when is_map(sessions) do
    limit != :infinity and map_size(sessions) >= limit
  end

  @spec configured_limit(atom(), pos_integer()) :: pos_integer() | :infinity
  def configured_limit(key, default) do
    case Application.get_env(:serviceradar_agent_gateway, key, default) do
      :infinity -> :infinity
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  @spec random_id(String.t()) :: String.t()
  def random_id(prefix) do
    suffix =
      8
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    "#{prefix}-#{suffix}"
  end

  defp session_count_for_agent(sessions, agent_id) do
    Enum.count(sessions, fn {_session_id, session} ->
      Map.get(session, :agent_id) == agent_id
    end)
  end
end
