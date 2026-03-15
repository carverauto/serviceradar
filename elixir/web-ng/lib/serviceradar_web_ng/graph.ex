defmodule ServiceRadarWebNG.Graph do
  @moduledoc """
  Graph query interface for executing openCypher queries against Apache AGE.

  This module delegates to `ServiceRadar.Graph` from serviceradar_core, which provides
  the shared implementation for AGE query execution with proper agtype handling.

  ServiceRadar uses the `serviceradar` AGE graph (see `docs/docs/age-graph-schema.md`).
  """

  use Boundary,
    deps: [ServiceRadarWebNG],
    exports: :all

  alias ServiceRadarWebNG.Repo

  @doc """
  Executes an openCypher query and returns the raw `Postgrex.Result`.

  Returns `{:ok, result}` or `{:error, reason}`.

  ## Examples

      {:ok, result} = ServiceRadarWebNG.Graph.cypher("MATCH (n:Device) RETURN n")
  """
  def cypher(cypher_query) when is_binary(cypher_query) do
    ServiceRadar.Graph.query(cypher_query, repo: Repo)
  end

  @doc """
  Executes an openCypher query and parses each returned row into an Elixir value.

  ## Examples

      {:ok, devices} = ServiceRadarWebNG.Graph.query("MATCH (n:Device) RETURN n")
  """
  def query(cypher_query) when is_binary(cypher_query) do
    ServiceRadar.Graph.query(cypher_query, repo: Repo)
  end

  @doc """
  Executes a Cypher query for side effects, discarding results.

  Use this for MERGE, CREATE, SET, and DELETE operations.

  ## Examples

      :ok = ServiceRadarWebNG.Graph.execute("MERGE (n:Device {id: 'abc'})")
  """
  def execute(cypher_query) when is_binary(cypher_query) do
    ServiceRadar.Graph.execute(cypher_query, repo: Repo)
  end

  @doc """
  Escapes a value for safe inclusion in Cypher queries.

  Delegates to `ServiceRadar.Graph.escape/1`.
  """
  defdelegate escape(value), to: ServiceRadar.Graph
end
