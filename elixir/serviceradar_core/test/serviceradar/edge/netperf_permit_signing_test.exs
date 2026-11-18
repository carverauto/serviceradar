defmodule ServiceRadar.Edge.NetperfPermitSigningTest do
  use ExUnit.Case, async: true

  alias Netperf.V1.NetperfPermitV1
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.NetperfPermitSigning

  @test_seed <<1::256>>

  defp test_key, do: IssuerKey.from_seed(@test_seed)

  defp sample_policy(overrides \\ %{}) do
    Map.merge(
      %{
        id: "11111111-1111-1111-1111-111111111111",
        authority_epoch: 3
      },
      overrides
    )
  end

  defp sample_profile(overrides \\ %{}) do
    Map.merge(
      %{
        id: "22222222-2222-2222-2222-222222222222",
        protocol: :tcp,
        direction: :bidirectional,
        bandwidth_bps: 100_000_000,
        duration_sec: 10,
        parallel: 2
      },
      overrides
    )
  end

  defp sample_responder(overrides \\ %{}) do
    Map.merge(
      %{
        agent_uid: "agent-hub-01",
        authority_epoch: 5
      },
      overrides
    )
  end

  test "sign_scheduled produces deterministic UTC-day-aligned permits that verify with IssuerKey" do
    key = test_key()
    now1 = ~U[2026-11-18 01:00:00Z]
    now2 = ~U[2026-11-18 23:59:59Z]

    assert {:ok, %NetperfPermitV1{} = permit1} =
             NetperfPermitSigning.sign_scheduled(
               sample_policy(),
               sample_profile(),
               sample_responder(),
               "agent-spoke-01",
               "default",
               issuer_key: key,
               now: now1
             )

    assert {:ok, %NetperfPermitV1{} = permit2} =
             NetperfPermitSigning.sign_scheduled(
               sample_policy(),
               sample_profile(),
               sample_responder(),
               "agent-spoke-01",
               "default",
               issuer_key: key,
               now: now2
             )

    assert permit1 == permit2
    assert permit1.issuer_id == "serviceradar-core"
    assert permit1.issuer_key_id == key.key_id
    assert permit1.algorithm == "ed25519"
    assert byte_size(permit1.signature) == 64
    assert NetperfPermitSigning.verify(permit1, key.public_key)

    day_start = DateTime.to_unix(~U[2026-11-18 00:00:00Z], :second)
    assert permit1.issued_at_unix == day_start - 300
    assert permit1.expires_at_unix == day_start + 8 * 86_400
    assert permit1.authority_epoch == NetperfPermitSigning.combined_authority_epoch(3, 5)
  end

  test "verify rejects tampering of any signed claim or signature" do
    key = test_key()

    {:ok, permit} =
      NetperfPermitSigning.sign_scheduled(
        sample_policy(),
        sample_profile(),
        sample_responder(),
        "agent-spoke-01",
        "default",
        issuer_key: key,
        now: ~U[2026-11-18 12:00:00Z]
      )

    mutations = [
      %{permit | permit_id: "00000000-0000-0000-0000-000000000000"},
      %{permit | partition_id: "isolated"},
      %{permit | sender_agent_id: "agent-spoke-99"},
      %{permit | responder_agent_id: "agent-hub-99"},
      %{permit | policy_id: "99999999-9999-9999-9999-999999999999"},
      %{permit | max_bandwidth_bps: 1_000_000_000},
      %{permit | max_duration_sec: 30},
      %{permit | max_parallel: 8},
      %{permit | allowed_protocols: [:NETPERF_PROTOCOL_UDP]},
      %{permit | allowed_directions: [:NETPERF_DIRECTION_UPLOAD]},
      %{permit | issued_at_unix: permit.issued_at_unix + 1},
      %{permit | expires_at_unix: permit.expires_at_unix + 1},
      %{permit | authority_epoch: permit.authority_epoch + 1},
      %{permit | issuer_id: "other-issuer"},
      %{permit | issuer_key_id: <<0::128>>},
      %{permit | algorithm: "rsa"},
      %{permit | permit_version: 2},
      %{permit | signature: <<0::512>>}
    ]

    for tampered <- mutations do
      refute NetperfPermitSigning.verify(tampered, key.public_key)
    end

    other_key = IssuerKey.from_seed(<<2::256>>)
    refute NetperfPermitSigning.verify(permit, other_key.public_key)
  end

  test "to_compiled_map and to_proto round-trip through JSON preserving signature verification" do
    key = test_key()

    {:ok, permit} =
      NetperfPermitSigning.sign_on_demand(
        %{
          permit_id: "33333333-3333-3333-3333-333333333333",
          command_id: "44444444-4444-4444-4444-444444444444",
          partition_id: "default",
          sender_agent_id: "agent-spoke-01",
          responder_agent_id: "agent-hub-01",
          protocol: "udp",
          direction: "download",
          bandwidth_bps: 25_000_000,
          duration_sec: 5,
          parallel: 1,
          authority_epoch: 2
        },
        issuer_key: key,
        now: ~U[2026-11-18 12:00:00Z]
      )

    compiled =
      permit |> NetperfPermitSigning.to_compiled_map() |> Jason.encode!() |> Jason.decode!()

    reconstructed = NetperfPermitSigning.to_proto(compiled)

    assert reconstructed == permit
    assert NetperfPermitSigning.verify(reconstructed, key.public_key)
  end

  test "canonical preimage uses domain tag, big-endian widths, and sorted protocol/direction lists" do
    key = test_key()

    {:ok, permit_a} =
      NetperfPermitSigning.sign_claims(
        %{
          permit_id: "p1",
          partition_id: "default",
          sender_agent_id: "s1",
          responder_agent_id: "r1",
          policy_id: "pol1",
          max_bandwidth_bps: 1_000_000,
          max_duration_sec: 5,
          max_parallel: 2,
          allowed_protocols: ["udp", "tcp"],
          allowed_directions: ["upload", "download"],
          issued_at_unix: 1_700_000_000,
          expires_at_unix: 1_700_000_300,
          authority_epoch: 7
        },
        issuer_key: key
      )

    {:ok, permit_b} =
      NetperfPermitSigning.sign_claims(
        %{
          permit_id: "p1",
          partition_id: "default",
          sender_agent_id: "s1",
          responder_agent_id: "r1",
          policy_id: "pol1",
          max_bandwidth_bps: 1_000_000,
          max_duration_sec: 5,
          max_parallel: 2,
          allowed_protocols: [:tcp, :udp],
          allowed_directions: [:download, :upload],
          issued_at_unix: 1_700_000_000,
          expires_at_unix: 1_700_000_300,
          authority_epoch: 7
        },
        issuer_key: key
      )

    preimage_a = NetperfPermitSigning.preimage(permit_a)
    assert preimage_a == NetperfPermitSigning.preimage(permit_b)
    assert permit_a.signature == permit_b.signature
    assert binary_part(preimage_a, 0, 8) == <<30::big-64>>
    assert binary_part(preimage_a, 8, 30) == "serviceradar.netperf.permit.v1"
  end
end
