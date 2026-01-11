defmodule ServiceRadarWebNG.Infrastructure do
  @moduledoc """
  Infrastructure context - delegates to Ash resources.

  This module provides backward-compatible functions that delegate
  to the underlying Ash resources in ServiceRadar.Infrastructure.
  """

  alias ServiceRadar.Infrastructure.{Agent, Gateway}

  require Ash.Query

  @doc """
  Lists gateways with pagination.

  ## Options
    * `:limit` - Maximum number of gateways to return (default: 200)
    * `:offset` - Number of gateways to skip (default: 0)
    * `:actor` - The actor for authorization (optional for backward compat)
  """
  def list_gateways(opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)
    offset = Keyword.get(opts, :offset, 0)
    actor = Keyword.get(opts, :actor)

    query_opts = build_query_opts(actor)

    Gateway
    |> Ash.Query.sort(last_seen: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.offset(offset)
    |> Ash.read(query_opts)
    |> case do
      {:ok, gateways} -> gateways
      {:error, _} -> []
    end
  end

  @doc """
  Gets a gateway by ID.

  Returns `nil` if gateway not found.
  """
  def get_gateway(id, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    query_opts = build_query_opts(actor)

    Gateway
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(query_opts)
    |> case do
      {:ok, gateway} -> gateway
      {:error, _} -> nil
    end
  end

  @doc """
  Lists agents with pagination.

  ## Options
    * `:limit` - Maximum number of agents to return (default: 200)
    * `:offset` - Number of agents to skip (default: 0)
    * `:actor` - The actor for authorization (optional for backward compat)
  """
  def list_agents(opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)
    offset = Keyword.get(opts, :offset, 0)
    actor = Keyword.get(opts, :actor)

    query_opts = build_query_opts(actor)

    Agent
    |> Ash.Query.sort(last_seen: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.offset(offset)
    |> Ash.read(query_opts)
    |> case do
      {:ok, agents} -> agents
      {:error, _} -> []
    end
  end

  @doc """
  Gets an agent by ID.

  Returns `nil` if agent not found.
  """
  def get_agent(id, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    query_opts = build_query_opts(actor)

    Agent
    |> Ash.Query.filter(agent_id == ^id)
    |> Ash.read_one(query_opts)
    |> case do
      {:ok, agent} -> agent
      {:error, _} -> nil
    end
  end

  @doc """
  Lists agents by gateway.
  """
  def list_agents_by_gateway(gateway_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    query_opts = build_query_opts(actor)

    Agent
    |> Ash.Query.filter(gateway_id == ^gateway_id)
    |> Ash.read(query_opts)
    |> case do
      {:ok, agents} -> agents
      {:error, _} -> []
    end
  end

  @doc """
  Lists healthy gateways (seen within last 5 minutes).
  """
  def list_healthy_gateways(opts \\ []) do
    actor = Keyword.get(opts, :actor)
    query_opts = build_query_opts(actor)

    Gateway
    |> Ash.Query.for_read(:healthy)
    |> Ash.read(query_opts)
    |> case do
      {:ok, gateways} -> gateways
      {:error, _} -> []
    end
  end

  # Build query options, skipping authorization if no actor provided
  # (for backward compatibility during migration)
  defp build_query_opts(nil), do: [actor: system_actor(), authorize?: false]
  defp build_query_opts(actor), do: [actor: actor]

  # System actor for backward compatibility when no actor is provided
  defp system_actor do
    %{
      id: "00000000-0000-0000-0000-000000000000",
      email: "system@serviceradar.local",
      role: :super_admin
    }
  end
end
