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

    action :trace_device_identity, :map do
      description("""
      Explain one device's identity end to end: its current record including
      tombstone fields, the canonical merge chain in both directions, revival
      events, identifier ownership with whether each identifier still matches
      the device's current facts, the shared-identifier evidence component
      with direct evidence separated from transitive connectivity, the identity
      decisions that refused or overrode a merge involving it, and the
      de-duplication tasks those decisions opened for an operator.

      Use this to answer "where did this device go", "why did these two merge",
      "why did these two NOT merge", or "is this MAC still real". Read-only; it
      cannot merge, unmerge, delete, restore or resolve anything. The seed is a bound identifier, not an SRQL fragment.
      """)

      argument :seed, :string do
        allow_nil?(false)

        description("Device uid (sr:<uuid>), IP, or hostname. Tombstoned devices are searched too.")
      end

      argument :limit, :integer do
        allow_nil?(true)
        description("Maximum rows per section (default 50, max 200)")
      end

      run(&Runner.trace_device_identity/2)
    end

    action :explain_identity_reconciliation, :map do
      description("""
      Summarise scheduled identity reconciliation runs: candidates, mergeable
      and blocked components, largest blocked component, merges attempted,
      errors, the configured per-run merge cap, and whether the run stopped
      because it reached that cap. Failed runs are included with their error.

      Pass include_evidence to also return the shared-identifier evidence edges
      for the components a run declined to merge. Read-only.
      """)

      argument :run_id, :string do
        allow_nil?(true)
        description("One run uuid. Omit to list recent runs in the time window.")
      end

      argument :time, :string do
        allow_nil?(true)
        description("Window: last_1h, last_24h (default), last_7d, or last_30d")
      end

      argument :include_evidence, :boolean do
        allow_nil?(true)
        description("Also return evidence edges for blocked components")
      end

      argument :limit, :integer do
        allow_nil?(true)
        description("Maximum runs to return (default 10)")
      end

      run(&Runner.explain_identity_reconciliation/2)
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

    action :horizon_intel_lookup, :map do
      description("""
      Look up Horizon IP, prefix, and ASN intelligence (same path and RBAC as
      GET /api/horizon/v1/intel/lookup). Requires at least one of asn, prefix,
      or ip. Returns CAIDA AS-org, MMDB geo/ASN, cloud CIDR attribution,
      PeeringDB IXP, ServiceRadar prefix tags, and RFC 6811 RPKI ROA validation
      when both asn and prefix are supplied. Read-only; requires
      observability.events.view. Arguments are bound identifiers, not SRQL.
      """)

      argument :asn, :integer do
        allow_nil?(true)
        description("Autonomous System Number (positive 32-bit integer, e.g. 13335)")
      end

      argument :prefix, :string do
        allow_nil?(true)
        description("IPv4 or IPv6 CIDR prefix (e.g. 1.1.1.0/24)")
      end

      argument :ip, :string do
        allow_nil?(true)
        description("IPv4 or IPv6 address (e.g. 1.1.1.1)")
      end

      run(&Runner.horizon_intel_lookup/2)
    end

    action :topology_blast_radius, :map do
      description("""
      Single-query bounded multi-hop inside-to-outside topology graph reasoning
      across ServiceRadar internal devices/interfaces/prefixes and stitched Horizon
      external Internet entities (Vantage, TransitRouter, IXP, Facility, ASN,
      Prefix, AnycastPop, SaasTarget). Supports modes: blast_radius,
      shared_fate_spofs, customer_cone, and multi_hop_trace. Read-only; requires
      observability.events.view. Arguments are bound scalars, not SRQL.
      """)

      argument :mode, :string do
        allow_nil?(false)
        description("Reasoning mode: blast_radius | shared_fate_spofs | customer_cone | multi_hop_trace")
      end

      argument :seed, :string do
        allow_nil?(true)
        description("Seed entity id (sr:<uid>, ASN/asn:<num>, prefix CIDR, IP, IXP, facility, or target id)")
      end

      argument :target, :string do
        allow_nil?(true)
        description("Optional destination entity id for multi_hop_trace shortest-path lookup")
      end

      argument :max_hops, :integer do
        allow_nil?(true)
        description("Maximum traversal hops (clamped 1..8, default 4)")
      end

      argument :limit, :integer do
        allow_nil?(true)
        description("Maximum returned nodes/edges/SPOFs (clamped 1..200, default 50)")
      end

      argument :min_targets, :integer do
        allow_nil?(true)
        description("Minimum shared downstream targets for shared_fate_spofs (clamped 1..200, default 2)")
      end

      run(&Runner.topology_blast_radius/2)
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
