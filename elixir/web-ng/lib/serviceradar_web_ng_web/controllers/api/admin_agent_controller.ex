defmodule ServiceRadarWebNGWeb.Api.AdminAgentController do
  @moduledoc """
  Read-only edge view of registered agents for the CLI (`GET /api/admin/agents`).

  Requires `settings.edge.manage`, so a CLI token scoped to `edge.manage` can
  confirm an agent enrolled without needing the full `/api/v2` JSON:API surface.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC

  require Ash.Query

  action_fallback ServiceRadarWebNGWeb.Api.FallbackController

  @default_limit 200
  @max_limit 1000

  @doc "GET /api/admin/agents"
  def index(conn, params) do
    with :ok <- authorize(conn) do
      query =
        Agent
        |> Ash.Query.for_read(:read)
        |> Ash.Query.sort(last_seen_time: :desc_nils_last)
        |> Ash.Query.limit(limit(params["limit"]))

      with {:ok, agents} <- Ash.read(query, actor: actor(conn)) do
        json(conn, %{data: Enum.map(agents, &agent_to_json/1)})
      end
    end
  end

  @doc false
  def agent_to_json(agent) do
    %{
      uid: agent.uid,
      name: agent.name,
      gateway_id: agent.gateway_id,
      status: agent.status,
      last_seen: agent.last_seen_time,
      version: agent.version,
      partition: partition(agent.metadata)
    }
  end

  defp partition(metadata) when is_map(metadata) do
    Map.get(metadata, "partition_id") || Map.get(metadata, "partition") ||
      Map.get(metadata, :partition_id) || Map.get(metadata, :partition)
  end

  defp partition(_), do: nil

  defp limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> min(n, @max_limit)
      _ -> @default_limit
    end
  end

  defp limit(_), do: @default_limit

  defp authorize(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} = scope when not is_nil(user) ->
        if RBAC.can?(scope, "settings.edge.manage"), do: :ok, else: {:error, :forbidden}

      _ ->
        {:error, :unauthorized}
    end
  end

  defp actor(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) -> conn.assigns[:ash_actor] || user
      _ -> nil
    end
  end
end
