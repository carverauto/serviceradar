defmodule ServiceRadar.Observability.MtrTrace do
  @moduledoc """
  MTR trace execution resource.

  Maps to the `mtr_traces` TimescaleDB hypertable. Each row represents a single
  MTR trace run — target, protocol, reachability status, and path metadata.
  Schema is managed by raw SQL migration.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "mtr_traces"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  resource do
    require_primary_key? false
  end

  actions do
    defaults [:read]

    read :by_device do
      argument :device_id, :string, allow_nil?: false
      filter expr(device_id == ^arg(:device_id))
    end

    read :by_target_ip do
      argument :target_ip, :string, allow_nil?: false
      filter expr(target_ip == ^arg(:target_ip))
    end

    read :by_agent do
      argument :agent_id, :string, allow_nil?: false
      filter expr(agent_id == ^arg(:agent_id))
    end

    read :recent do
      description "Traces from the last 24 hours"
      filter expr(time > ago(24, :hour))
    end

    create :create do
      accept [
        :id,
        :time,
        :agent_id,
        :gateway_id,
        :check_id,
        :check_name,
        :device_id,
        :target,
        :target_ip,
        :target_reached,
        :total_hops,
        :probed_hops,
        :last_responding_hop,
        :protocol,
        :tcp_port,
        :ip_version,
        :packet_size,
        :partition,
        :error,
        :tcp_handshake_ttl,
        :tcp_handshake_attempts,
        :tcp_syn_sent,
        :tcp_synack_received,
        :tcp_rst_received,
        :tcp_syn_unanswered,
        :tcp_syn_drop_pct,
        :tcp_syn_retransmits,
        :tcp_answered_after_retx,
        :tcp_ack_mismatch,
        :tcp_synack_duplicates,
        :tcp_handshake_rtt_min_us,
        :tcp_handshake_rtt_avg_us,
        :tcp_handshake_rtt_max_us,
        :tcp_server_response_us
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
      description "When the trace was executed"
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
    end

    attribute :gateway_id, :string do
      public? true
    end

    attribute :check_id, :string do
      public? true
    end

    attribute :check_name, :string do
      public? true
    end

    attribute :device_id, :string do
      public? true
    end

    attribute :target, :string do
      allow_nil? false
      public? true
      description "Target hostname or IP"
    end

    attribute :target_ip, :string do
      allow_nil? false
      public? true
      description "Resolved target IP address"
    end

    attribute :target_reached, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :total_hops, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :probed_hops, :integer do
      public? true
      description "Deepest TTL probed; for an unreached trace this reflects the run's budget"
    end

    attribute :last_responding_hop, :integer do
      public? true
      description "Deepest hop that returned any reply (0 when none did)"
    end

    attribute :protocol, :string do
      allow_nil? false
      default "icmp"
      public? true
    end

    attribute :tcp_port, :integer do
      public? true
      description "Destination port of a TCP trace"
    end

    attribute :ip_version, :integer do
      allow_nil? false
      default 4
      public? true
    end

    attribute :packet_size, :integer do
      public? true
    end

    attribute :partition, :string do
      public? true
    end

    attribute :error, :string do
      public? true
    end

    attribute :tcp_handshake_ttl, :integer do
      public? true
      description "TTL the destination handshake SYNs were sent with"
    end

    attribute :tcp_handshake_attempts, :integer do
      public? true
      description "Handshakes attempted; each is one SYN plus its retransmissions"
    end

    attribute :tcp_syn_sent, :integer do
      public? true
      description "Destination-phase SYNs sent, retransmissions included"
    end

    attribute :tcp_synack_received, :integer do
      public? true
      description "Handshake attempts the target answered with SYN-ACK"
    end

    attribute :tcp_rst_received, :integer do
      public? true
      description "Handshake attempts the target answered with RST"
    end

    attribute :tcp_syn_unanswered, :integer do
      public? true
      description "Handshake attempts that got no answer after every retransmission"
    end

    attribute :tcp_syn_drop_pct, :float do
      public? true
      description "Unanswered handshakes as a percentage of handshakes attempted"
    end

    attribute :tcp_syn_retransmits, :integer do
      public? true
      description "SYNs re-sent after the per-probe timeout"
    end

    attribute :tcp_answered_after_retx, :integer do
      public? true
      description "Handshakes answered only after a retransmission"
    end

    attribute :tcp_ack_mismatch, :integer do
      public? true
      description "Replies whose acknowledgement matched no SYN of the trace"
    end

    attribute :tcp_synack_duplicates, :integer do
      public? true
      description "Repeated answers to an already-answered handshake"
    end

    attribute :tcp_handshake_rtt_min_us, :integer do
      public? true
      description "Minimum SYN to SYN-ACK/RST time at the destination"
    end

    attribute :tcp_handshake_rtt_avg_us, :integer do
      public? true
      description "Average SYN to SYN-ACK/RST time at the destination"
    end

    attribute :tcp_handshake_rtt_max_us, :integer do
      public? true
      description "Maximum SYN to SYN-ACK/RST time at the destination"
    end

    attribute :tcp_server_response_us, :integer do
      public? true
      description "Estimated time in the target: handshake RTT average minus last transit hop RTT average"
    end

    attribute :created_at, :utc_datetime_usec do
      public? true
    end
  end
end
