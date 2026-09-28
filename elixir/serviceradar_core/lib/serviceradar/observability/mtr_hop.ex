defmodule ServiceRadar.Observability.MtrHop do
  @moduledoc """
  Per-hop MTR statistics resource.

  Maps to the `mtr_hops` TimescaleDB hypertable. Each row represents one hop
  in an MTR trace with latency, loss, ASN, and MPLS label data.
  Schema is managed by raw SQL migration.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "mtr_hops"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  resource do
    require_primary_key? false
  end

  actions do
    defaults [:read]

    read :by_trace do
      argument :trace_id, :uuid, allow_nil?: false
      filter expr(trace_id == ^arg(:trace_id))
    end

    read :by_addr do
      argument :addr, :string, allow_nil?: false
      filter expr(addr == ^arg(:addr))
    end

    read :recent do
      description "Hops from the last 24 hours"
      filter expr(time > ago(24, :hour))
    end

    create :create do
      accept [
        :id,
        :time,
        :trace_id,
        :target_ip,
        :device_id,
        :hop_number,
        :addr,
        :hostname,
        :ecmp_addrs,
        :asn,
        :asn_org,
        :mpls_labels,
        :sent,
        :received,
        :loss_pct,
        :last_us,
        :avg_us,
        :min_us,
        :max_us,
        :stddev_us,
        :jitter_us,
        :jitter_worst_us,
        :jitter_interarrival_us,
        :unreachable_code,
        :reply_time_exceeded,
        :reply_unreachable,
        :reply_synack,
        :reply_rst
      ]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:create) do
      authorize_if always()
    end
  end

  attributes do
    attribute :id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :time, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When this hop was recorded"
    end

    attribute :trace_id, :uuid do
      allow_nil? false
      public? true
      description "Parent trace ID"
    end

    attribute :target_ip, :string do
      public? true

      description "Owning trace's target, denormalised so hop metrics can be scoped to the device they measured. Nil on rows written before the attribution backfill, which is also its resume marker. Prefer this over device_id."
    end

    attribute :device_id, :string do
      public? true

      description "Owning trace's device_id, denormalised alongside target_ip. On the bulk-scheduled path this is the originating command's id rather than a device uid, so grouping by it yields one row per command."
    end

    attribute :hop_number, :integer do
      allow_nil? false
      public? true
    end

    attribute :addr, :string do
      public? true
      description "Responding IP address (nil for non-responding hops)"
    end

    attribute :hostname, :string do
      public? true
    end

    attribute :ecmp_addrs, {:array, :string} do
      public? true
      description "Additional ECMP addresses seen at this hop"
    end

    attribute :asn, :integer do
      public? true
    end

    attribute :asn_org, :string do
      public? true
    end

    attribute :mpls_labels, :map do
      public? true
      description "MPLS label stack (JSONB)"
    end

    attribute :sent, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :received, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :loss_pct, :float do
      allow_nil? false
      default 0.0
      public? true
    end

    attribute :last_us, :integer do
      public? true
      description "Last RTT in microseconds"
    end

    attribute :avg_us, :integer do
      public? true
      description "Average RTT in microseconds"
    end

    attribute :min_us, :integer do
      public? true
    end

    attribute :max_us, :integer do
      public? true
    end

    attribute :stddev_us, :integer do
      public? true
    end

    attribute :jitter_us, :integer do
      public? true
    end

    attribute :jitter_worst_us, :integer do
      public? true
    end

    attribute :jitter_interarrival_us, :integer do
      public? true
    end

    attribute :unreachable_code, :integer do
      public? true

      description "ICMP Destination Unreachable code this hop returned (ICMPv4 or ICMPv6 numbering)"
    end

    attribute :reply_time_exceeded, :integer do
      public? true
      description "ICMP Time Exceeded replies from this hop"
    end

    attribute :reply_unreachable, :integer do
      public? true
      description "ICMP Destination Unreachable replies from this hop"
    end

    attribute :reply_synack, :integer do
      public? true
      description "TCP SYN-ACK replies from this hop"
    end

    attribute :reply_rst, :integer do
      public? true
      description "TCP RST replies from this hop"
    end

    attribute :created_at, :utc_datetime_usec do
      public? true
    end
  end
end
