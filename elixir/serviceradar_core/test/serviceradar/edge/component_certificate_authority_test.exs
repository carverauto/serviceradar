defmodule ServiceRadar.Edge.ComponentCertificateAuthorityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.ComponentCertificateAuthority, as: Authority

  @now ~U[2026-01-01 00:00:00Z]
  @first String.duplicate("a", 64)
  @second String.duplicate("b", 64)

  setup do
    component = %{component_id: "example-core", generation: 1, blocked: false}

    certificate = %{
      fingerprint: @first,
      issuer_fingerprint: String.duplicate("c", 64),
      serial_number: "17",
      component_id: component.component_id,
      generation: 1,
      not_before: DateTime.shift(@now, minute: -1),
      not_after: DateTime.shift(@now, hour: 1)
    }

    snapshot = %{
      version: 1,
      generated_at: @now,
      valid_until: DateTime.shift(@now, second: 30),
      components: [component],
      certificates: [certificate],
      revocations: []
    }

    %{snapshot: snapshot, component: component, certificate: certificate}
  end

  test "revocation selects full fingerprint even when issuer and serial coincide", ctx do
    second = %{ctx.certificate | fingerprint: @second}

    snapshot = %{
      ctx.snapshot
      | certificates: [ctx.certificate, second],
        revocations: [
          %{component_id: "example-core", generation: 1, fingerprint: @first}
        ]
    }

    assert {:error, :certificate_revoked} =
             Authority.authorize(snapshot, "example-core", @first, @now)

    assert :ok = Authority.authorize(snapshot, "example-core", @second, @now)

    assert {:error, :unknown_certificate} =
             Authority.authorize(snapshot, "example-core", String.duplicate("d", 64), @now)

    assert {:error, :unknown_component} =
             Authority.authorize(snapshot, "unknown-component", @second, @now)
  end

  test "re-enrollment admits only the successor generation", ctx do
    blocked = %{ctx.snapshot | components: [%{ctx.component | blocked: true}]}

    assert {:error, :component_revoked} =
             Authority.authorize(blocked, "example-core", @first, @now)

    reenrolled = %{ctx.snapshot | components: [%{ctx.component | generation: 2}]}

    assert {:error, :stale_generation} =
             Authority.authorize(reenrolled, "example-core", @first, @now)

    successor = %{ctx.certificate | generation: 2, fingerprint: @second}

    reenrolled = %{
      reenrolled
      | certificates: [ctx.certificate, successor],
        revocations: [
          %{component_id: "example-core", generation: 1, fingerprint: nil}
        ]
    }

    assert :ok = Authority.authorize(reenrolled, "example-core", @second, @now)
  end

  test "receiver lease and certificate validity have independent strict boundaries", ctx do
    assert :ok = Authority.authorize(ctx.snapshot, "example-core", @first, @now)

    for now <- [DateTime.shift(@now, second: -1), DateTime.shift(@now, second: 30)] do
      assert {:error, :stale_snapshot} =
               Authority.authorize(ctx.snapshot, "example-core", @first, now)
    end

    overlong = %{ctx.snapshot | valid_until: DateTime.shift(@now, second: 31)}
    assert {:error, :stale_snapshot} = Authority.authorize(overlong, "example-core", @first, @now)

    for cert <- [
          %{ctx.certificate | not_before: DateTime.shift(@now, second: 1)},
          %{ctx.certificate | not_after: @now}
        ] do
      assert {:error, :certificate_not_valid} =
               Authority.authorize(
                 %{ctx.snapshot | certificates: [cert]},
                 "example-core",
                 @first,
                 @now
               )
    end

    assert {:error, :invalid_snapshot} = Authority.authorize(%{}, "example-core", @first, @now)
  end
end
