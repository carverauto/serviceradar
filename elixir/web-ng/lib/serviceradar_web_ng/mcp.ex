defmodule ServiceRadarWebNG.Mcp do
  @moduledoc """
  Ash domain exposing the v1 MCP tool allowlist.

  Tools call `ServiceRadarWebNG.Api.Access` only. Do not register generic
  Inventory/Identity resource CRUD here.
  """

  use Ash.Domain, extensions: [AshAi]

  use Boundary,
    top_level?: true,
    deps: [
      ServiceRadarWebNG,
      ServiceRadarWebNG.Accounts,
      ServiceRadarWebNG.Auth
    ],
    exports: :all

  alias ServiceRadarWebNG.Mcp.Tools

  @v1_tools [:execute_srql, :lookup_srql_docs, :get_srql_catalog, :list_devices, :get_device]
  @v1_resources [:srql_grammar, :srql_entities, :srql_cookbook]

  @spec v1_tools() :: [atom()]
  def v1_tools, do: @v1_tools

  @spec v1_resources() :: [atom()]
  def v1_resources, do: @v1_resources

  @doc """
  Sent on MCP initialize. Keep this short: clients inject it into the model
  prompt. Grammar and recipes live on resources, not here.
  """
  @spec instructions() :: String.t()
  def instructions do
    String.trim("""
    ServiceRadar MCP is read-only. SRQL is a key:value language, not SQL.

    When you need syntax or fields, call lookup_srql_docs with a short query
    (entity id, operator, or task), e.g. "devices", "time:", "ssh", "stats".
    Then call execute_srql. Every query needs exactly one in:<entity> token.

    Full manuals (optional): serviceradar://srql/grammar, serviceradar://srql/entities,
    serviceradar://srql/cookbook. get_srql_catalog with entity=<id> returns one field map.

    list_devices and get_device bind identifiers; they are not SRQL. Do not invent SQL, JSON filters, or /api/mcp.
    """)
  end

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
    tool(:lookup_srql_docs, Tools, :lookup_srql_docs)
    tool(:get_srql_catalog, Tools, :get_srql_catalog)
    tool(:list_devices, Tools, :list_devices)
    tool(:get_device, Tools, :get_device)
  end

  mcp_resources do
    mcp_resource(:srql_grammar, "serviceradar://srql/grammar", Tools, :srql_grammar,
      title: "SRQL grammar",
      mime_type: "text/markdown"
    )

    mcp_resource(:srql_entities, "serviceradar://srql/entities", Tools, :srql_entities,
      title: "SRQL entity index",
      mime_type: "text/markdown"
    )

    mcp_resource(:srql_cookbook, "serviceradar://srql/cookbook", Tools, :srql_cookbook,
      title: "SRQL cookbook",
      mime_type: "text/markdown"
    )
  end

  authorization do
    require_actor?(true)
    authorize(:by_default)
  end
end
