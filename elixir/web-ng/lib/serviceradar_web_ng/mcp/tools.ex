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
      Execute a raw SRQL query via the same path as POST /api/query.
      The query argument is passed through as SRQL, not treated as a bound identifier.
      """)

      argument :query, :string do
        allow_nil?(false)
        description("Raw SRQL query string (for example in:devices limit:10)")
      end

      argument :limit, :integer do
        allow_nil?(true)
        description("Maximum rows to return")
      end

      run(&Runner.execute_srql/2)
    end

    action :get_srql_catalog, :map do
      description("Return the SRQL catalog via the same path as GET /api/srql/catalog.")

      run(&Runner.get_srql_catalog/2)
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
  end
end
