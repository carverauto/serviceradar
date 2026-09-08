defmodule ServiceRadarAgentGateway.MetricsPublisherTestHelpers do
  @moduledoc """
  Shared helpers for the per-metric-type publisher tests.

  The 6 `*_metrics_publisher_test.exs` files independently defined a few
  byte-identical helpers. They are extracted here so the test duplication is
  gone too. The ingress-header assertion came in two real variants, preserved
  as two distinct functions:

    * `assert_full_ingress_headers/1` — strict: asserts the full
      `Sr-*` / `Nats-Msg-Id` header set (sysmon, snmp, icmp).
    * `assert_nats_msg_id_header/1` — loose: asserts only that a non-empty
      `Nats-Msg-Id` header is present (rperf, mtr, sweep).
  """

  import ExUnit.Assertions

  @doc """
  Restores a previously-captured application env value, deleting it when the
  prior value was `nil`.
  """
  def restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  def restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)

  @doc "UUIDv8 regex used to validate generated ingress identifiers."
  def uuidv8_pattern do
    ~r/^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  end

  @doc """
  Strict ingress-header assertion: validates the full attested header set.
  """
  def assert_full_ingress_headers(opts) do
    headers =
      opts
      |> Keyword.fetch!(:headers)
      |> Map.new()

    assert headers["Sr-Ingress-Id"] =~ uuidv8_pattern()
    assert Integer.parse(headers["Sr-Ingress-Time-Unix-Nano"]) != :error
    assert headers["Sr-Agent-Id"] == "agent-1"
    assert headers["Sr-Gateway-Id"] == "gateway-1"
    assert headers["Sr-Partition"] == "default"
    assert headers["Sr-Ingest-Identity"] == "agent:agent-1"
    assert headers["Nats-Msg-Id"] == headers["Sr-Ingress-Id"]
  end

  @doc """
  Loose ingress-header assertion: only requires a non-empty `Nats-Msg-Id`.
  """
  def assert_nats_msg_id_header(opts) do
    headers = Keyword.fetch!(opts, :headers)

    Enum.any?(headers, fn
      {"Nats-Msg-Id", value} when is_binary(value) and value != "" -> true
      _ -> false
    end)
  end
end
