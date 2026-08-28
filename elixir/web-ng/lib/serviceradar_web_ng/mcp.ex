defmodule ServiceRadarWebNG.Mcp do
  @moduledoc """
  Ash domain exposing the v1 MCP tool allowlist.

  Tools call `ServiceRadarWebNG.Api.Access` only. Do not register generic
  Inventory/Identity resource CRUD here.
  """

  use Ash.Domain, extensions: [AshAi]

  alias ServiceRadarWebNG.Mcp.Tools

  @v1_tools [:execute_srql, :get_srql_catalog, :list_devices, :get_device]

  @spec v1_tools() :: [atom()]
  def v1_tools, do: @v1_tools

  @doc """
  AshAi schemas nest generic-action arguments under `input`. Accept that
  shape, and also wrap a flat argument map so hand-rolled clients work.
  """
  @spec wrap_tool_arguments(term(), map(), term()) :: {:ok, map()}
  def wrap_tool_arguments(_tool, args, _context) when is_map(args) do
    if Map.has_key?(args, "input") or Map.has_key?(args, :input) do
      {:ok, args}
    else
      {:ok, %{"input" => args}}
    end
  end

  resources do
    resource(Tools)
  end

  tools do
    tool(:execute_srql, Tools, :execute_srql)
    tool(:get_srql_catalog, Tools, :get_srql_catalog)
    tool(:list_devices, Tools, :list_devices)
    tool(:get_device, Tools, :get_device)
  end

  authorization do
    require_actor?(true)
    authorize(:by_default)
  end
end
