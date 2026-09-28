defmodule ServiceRadar.Repo.Migrations.AddMtrTcpHandshakeFields do
  @moduledoc """
  Stores the TCP handshake diagnostics of an MTR trace and per-hop reply
  counters by kind.

  Every column is nullable: nil means the figure was not measured (a non-TCP
  or connect-fallback trace, or an older agent), which is different from a
  measured zero. Both tables are hypertables with compression configured;
  adding nullable columns without a default is supported on them, including
  when chunks are already compressed, and compressed rows read the new columns
  as NULL.
  """
  use Ecto.Migration

  @trace_columns [
    tcp_handshake_ttl: "INTEGER",
    tcp_handshake_attempts: "INTEGER",
    tcp_syn_sent: "INTEGER",
    tcp_synack_received: "INTEGER",
    tcp_rst_received: "INTEGER",
    tcp_syn_unanswered: "INTEGER",
    tcp_syn_drop_pct: "DOUBLE PRECISION",
    tcp_syn_retransmits: "INTEGER",
    tcp_answered_after_retx: "INTEGER",
    tcp_ack_mismatch: "INTEGER",
    tcp_synack_duplicates: "INTEGER",
    tcp_handshake_rtt_min_us: "BIGINT",
    tcp_handshake_rtt_avg_us: "BIGINT",
    tcp_handshake_rtt_max_us: "BIGINT",
    tcp_server_response_us: "BIGINT"
  ]

  @hop_columns [
    reply_time_exceeded: "INTEGER",
    reply_unreachable: "INTEGER",
    reply_synack: "INTEGER",
    reply_rst: "INTEGER"
  ]

  def up do
    schema = prefix() || "platform"

    execute(add_columns(schema, "mtr_traces", @trace_columns))
    execute(add_columns(schema, "mtr_hops", @hop_columns))
  end

  def down do
    schema = prefix() || "platform"

    execute(drop_columns(schema, "mtr_hops", @hop_columns))
    execute(drop_columns(schema, "mtr_traces", @trace_columns))
  end

  defp add_columns(schema, table, columns) do
    clauses =
      Enum.map_join(columns, ",\n  ", fn {name, type} ->
        "ADD COLUMN IF NOT EXISTS #{name} #{type}"
      end)

    "ALTER TABLE #{schema}.#{table}\n  #{clauses}"
  end

  defp drop_columns(schema, table, columns) do
    clauses =
      Enum.map_join(columns, ",\n  ", fn {name, _type} -> "DROP COLUMN IF EXISTS #{name}" end)

    "ALTER TABLE #{schema}.#{table}\n  #{clauses}"
  end
end
