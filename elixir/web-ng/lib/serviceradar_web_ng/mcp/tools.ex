defmodule ServiceRadarWebNG.Mcp.Tools do
  @moduledoc """
  Generic Ash actions that implement MCP tools as API facades.
  """

  use Ash.Resource,
    domain: ServiceRadarWebNG.Mcp,
    data_layer: Ash.DataLayer.Simple,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadarWebNG.Mcp.Runner

  resource do
    require_primary_key?(false)
  end

  actions do
    defaults([])

    action :execute_srql, :map do
      description("""
      Execute a raw SRQL query (same path as POST /api/query). SRQL is a
      whitespace-separated key:value language, not SQL. Every query needs
      exactly one in:<entity> token. If you are unsure of syntax or fields,
      call lookup_srql_docs first. The query argument is passed through as
      SRQL, not treated as a bound identifier.
      """)

      argument :query, :string do
        allow_nil?(false)
        description("Raw SRQL, for example in:devices hostname:%core% time:last_24h limit:20")
      end

      argument :limit, :integer do
        allow_nil?(true)
        description("Maximum rows to return")
      end

      run(&Runner.execute_srql/2)
    end

    action :lookup_srql_docs, :map do
      description("""
      Look up SRQL syntax and recipes by short query, like looking up crate
      docs. Pass an entity id (devices, logs, flows), an operator (time:,
      stats, bucket), or a task (ssh, cpu, alerts). Returns matching grammar,
      cookbook, and catalog sections. Prefer this over dumping get_srql_catalog.
      """)

      argument :query, :string do
        allow_nil?(false)
        description("Short lookup, for example devices, time:, ssh traffic, stats")
      end

      run(&Runner.lookup_srql_docs/2)
    end

    action :get_srql_catalog, :map do
      description("""
      Field lists, enums, and control tokens for SRQL entities (same data as
      GET /api/srql/catalog). Pass `entity` (for example devices, logs, flows)
      to load one entity. Omit it only when you need every entity; the full
      map is large. For grammar and recipes read serviceradar://srql/grammar
      and serviceradar://srql/cookbook; for ids read serviceradar://srql/entities.
      """)

      argument :entity, :string do
        allow_nil?(true)
        description("SRQL entity id to return (for example devices). Omit for the full catalog.")
      end

      run(&Runner.get_srql_catalog/2)
    end

    action :srql_grammar, :string do
      description("""
      Compact SRQL grammar for MCP agents: token shape, operators, time,
      stats, bucket, and common mistakes. Not the full human language reference.
      """)

      run(&Runner.srql_grammar/2)
    end

    action :srql_entities, :string do
      description("""
      Markdown table of SRQL entity ids generated from the live catalog.
      Call get_srql_catalog with entity set to one id for fields.
      """)

      run(&Runner.srql_entities/2)
    end

    action :srql_cookbook, :string do
      description("Copy-paste SRQL recipes grouped by task (devices, logs, flows, metrics).")

      run(&Runner.srql_cookbook/2)
    end

    action :list_devices, :map do
      description("List devices via the same Ash read as GET /api/devices.")

      argument(:limit, :integer, allow_nil?: true)
      argument(:offset, :integer, allow_nil?: true)
      argument(:search, :string, allow_nil?: true)
      argument(:status, :string, allow_nil?: true)
      argument(:gateway_id, :string, allow_nil?: true)
      argument(:device_type, :string, allow_nil?: true)

      run(&Runner.list_devices/2)
    end

    action :get_device, :map do
      description("""
      Fetch one device by uid via the same lookup as GET /api/devices/:uid.
      The uid is a bound identifier, not an SRQL fragment.
      """)

      argument :uid, :string do
        allow_nil?(false)
        description("Device uid (opaque identifier, not SRQL)")
      end

      run(&Runner.get_device/2)
    end
  end

  policies do
    policy always() do
      description("MCP tools require an authenticated actor; HTTP already gated mcp scope.")
      authorize_if(actor_present())
    end

    policy always() do
      description("MCP tools also require settings.mcp.manage on the caller.")
      authorize_if({ServiceRadar.Policies.Checks.ActorHasPermission, permission: "settings.mcp.manage"})
    end
  end
end
