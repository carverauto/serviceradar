defmodule ServiceRadar.Bench.SweepIngressFixtures do
  @moduledoc """
  The deterministic fixture generator for the body-pipeline benchmark (task 1.17).

  ONE generator, TWO consumers: `bench/sweep_ingress.exs` measures these fixtures, and
  `test/serviceradar/edge/sweep_bench_fixture_test.exs` verifies them against the digests Go
  recorded and against the outcome each measurement assumes. Duplicating it would let the
  verifier pass while the benchmark measured something else.

  Byte-for-byte the Go generator in `sweep_ingress_benchmark_test.go`. Every host and nested
  message is DISTINCT: reusing one term shares an allocation and understates memory.
  """

  import Bitwise

  alias Serviceradar.Edge.V1, as: V1

  @observed_unix_nano 1_700_000_300_000_000_000

  @icmp_bit 1
  @tcp_syn_bit 2
  @tcp_connect_bit 4
  @mtr_bit 8

  @doc "The seven benchmark fixtures: {name, hosts, mixed?, invalid_last?}."
  def matrix do
    [
      {"hosts_1", 1, false, false},
      {"hosts_100", 100, false, false},
      {"hosts_1000", 1000, false, false},
      {"hosts_2000", 2000, false, false},
      {"hosts_2000_mixed", 2000, true, false},
      {"hosts_2000_invalid_last", 2000, false, true},
      {"hosts_2001_over_ceiling", 2001, false, false}
    ]
  end

  @doc "The record whose SIGNED claims correlate with the batch."
  def record_for(b) do
    claims = %V1.EdgeSourceClaimsV1{
      kind: :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
      context_id: b.source_run_id,
      scope_id: b.target_range_id,
      scope_sha256: b.target_range_sha256,
      target_range_sha256: b.target_range_sha256,
      execution_plan_sha256: b.execution_plan_sha256,
      collection_not_before_unix_nano: b.observed_at_unix_nano - 1_000_000_000,
      collection_expires_unix_nano: b.observed_at_unix_nano + 1_000_000_000
    }

    %V1.EdgeRecordV1{
      compression: :EDGE_RECORD_COMPRESSION_NONE,
      source_authorization: %V1.EdgeSourceAuthorizationV1{
        kind: claims.kind,
        context_id: claims.context_id,
        scope_id: claims.scope_id,
        scope_sha256: claims.scope_sha256,
        capability: %V1.EdgeSignedCapabilityV1{claims: {:source, claims}}
      },
      producer_context: %V1.EdgeProducerContext{
        run_shard: b.execution_shard,
        authority_epoch: b.assignment_epoch
      }
    }
  end

  # --- fixtures -------------------------------------------------------------------------
  # Byte-for-byte the Go generator. Every host is DISTINCT: reusing one term 2000 times
  # shares a single allocation and understates memory and decode cost.

  def uuid(seed), do: <<seed, 0, 0, 0, 0, 0, 0x70, 0, 0x80, 0, 0, 0, 0, 0, 0, 0>>

  def d32(tag), do: for(i <- 0..31, into: <<>>, do: <<rem(tag + i, 256)>>)

  def host(i, mixed?) do
    base = %V1.SweepHostObservationV1{
      address: <<10, i >>> 16 &&& 0xFF, i >>> 8 &&& 0xFF, i &&& 0xFF>>,
      hostname: "host-#{i}",
      observed_at_delta_nano: -1000 - i,
      mode_revision: rem(i, 7) + 1
    }

    icmp = %V1.SweepIcmpSummaryV1{
      outcome: :SWEEP_MODE_OUTCOME_SUCCESS,
      target_reached: true,
      round_trip_micro: 900 + i,
      packet_loss_pct: 0.0,
      sent: 3,
      received: 3
    }

    if mixed? do
      mixed_host(base, icmp, i)
    else
      %{
        base
        | result_mode_bits: @icmp_bit ||| @tcp_syn_bit,
          icmp: icmp,
          tcp: %V1.SweepTcpSummaryV1{
            outcome: :SWEEP_MODE_OUTCOME_SUCCESS,
            tested_count: 1,
            open_count: 1
          },
          open_ports: [
            %V1.SweepOpenPortV1{
              tested_check_index: 1,
              response_time_nano: 4000 + i,
              service: "https"
            }
          ]
      }
    end
  end

  def mixed_host(base, icmp, i) do
    case rem(i, 3) do
      0 ->
        %{base | result_mode_bits: @icmp_bit, icmp: icmp}

      1 ->
        %{
          base
          | # BOTH TCP bits: open_ports references check 1 (TCP_SYN) and port_errors check 2
            # (TCP_CONNECT), and an entry may only name a check whose bit this fragment carries.
            result_mode_bits: @tcp_syn_bit ||| @tcp_connect_bit,
            tcp: %V1.SweepTcpSummaryV1{
              outcome: :SWEEP_MODE_OUTCOME_SUCCESS,
              tested_count: 2,
              open_count: 1
            },
            open_ports: [
              %V1.SweepOpenPortV1{
                tested_check_index: 1,
                response_time_nano: 4000 + i,
                service: "https"
              }
            ],
            port_errors: [%V1.SweepPortErrorV1{tested_check_index: 2, error_code: "refused"}]
        }

      _ ->
        %{
          base
          | result_mode_bits: @mtr_bit,
            mtr: %V1.SweepMtrSummaryV1{
              trace_id: trace_id(i),
              outcome: :MTR_OUTCOME_REACHED,
              target_reached: true,
              final_rtt_micro: 9000 + i,
              packet_loss_pct: 0.0,
              total_hops: rem(i, 12) + 1,
              error_code: ""
            }
        }
    end
  end

  # A UUIDv7 whose 48-bit timestamp sits INSIDE the batch's signed collection window. An
  # arbitrary high seed overflows the window comparison, and correlation then rejects on the
  # first MTR host -- measuring an early refusal rather than the full walk.
  def trace_id(i) do
    ms = div(@observed_unix_nano, 1_000_000) - rem(i, 1000)
    <<ms::48, 0x70, 0, 0x80, 0, 0, 0, 0, 0, 0, 0>>
  end

  def batch(hosts, mixed?, invalid_last?) do
    {checks, bits} =
      if mixed? do
        {[
           icmp_check(),
           tcp_check(),
           %V1.SweepTestV1{
             mode: :SWEEP_MODE_TCP_CONNECT,
             protocol: :TRANSPORT_PROTOCOL_TCP,
             port: 8443
           },
           %V1.SweepTestV1{mode: :SWEEP_MODE_MTR, protocol: :TRANSPORT_PROTOCOL_ICMP}
         ], @icmp_bit ||| @tcp_syn_bit ||| @tcp_connect_bit ||| @mtr_bit}
      else
        {[icmp_check(), tcp_check()], @icmp_bit ||| @tcp_syn_bit}
      end

    list = for i <- 0..(hosts - 1), do: host(i, mixed?)

    list =
      if invalid_last? and list != [] do
        List.update_at(list, -1, &%{&1 | address: <<1>>})
      else
        list
      end

    %V1.SweepObservationBatchV1{
      execution_id: uuid(0x20),
      execution_plan_id: uuid(0x21),
      target_range_id: uuid(0x22),
      execution_plan_sha256: d32(0x10),
      target_range_sha256: d32(0x20),
      availability_policy_id: "policy-1",
      batch_sequence: 1,
      observed_at_unix_nano: @observed_unix_nano,
      source: :SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK,
      source_run_id: uuid(0x23),
      execution_shard: 3,
      assignment_epoch: 5,
      configured_mode_bits: bits,
      tested_checks: checks,
      hosts: list
    }
  end

  def icmp_check, do: %V1.SweepTestV1{mode: :SWEEP_MODE_ICMP, protocol: :TRANSPORT_PROTOCOL_ICMP}

  def tcp_check,
    do: %V1.SweepTestV1{mode: :SWEEP_MODE_TCP_SYN, protocol: :TRANSPORT_PROTOCOL_TCP, port: 443}

  # The record whose SIGNED claims correlate with the batch, so stage 3 measures the whole
  # comparison rather than an early rejection.
end
