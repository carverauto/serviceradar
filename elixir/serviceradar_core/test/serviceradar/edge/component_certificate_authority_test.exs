defmodule ServiceRadar.Edge.ComponentCertificateAuthorityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.ComponentCertificateAuthority, as: Authority
  alias ServiceRadar.Edge.ManagedComponentNatsPermissions
  alias ServiceRadar.NATS.CertificateAuthorizationToken

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

  test "signed NATS grants exclude denied fingerprints and local server roles" do
    components = [
      %{
        component_id: "example-flow",
        component_type: "flow-collector",
        edge_site_id: "00000000-0000-4000-8000-000000000123"
      },
      %{component_id: "example-leaf", component_type: "nats-leaf"}
    ]

    certificates = [
      %{component_id: "example-flow", fingerprint: @first, role: "client"},
      %{component_id: "example-leaf", fingerprint: @second, role: "local_server"},
      %{component_id: "example-flow", fingerprint: String.duplicate("c", 64), role: "client"}
    ]

    grants =
      ManagedComponentNatsPermissions.snapshot(components, certificates, [
        @first,
        @second
      ])

    assert Map.keys(grants) == [@first]
    assert "flows.raw.netflow" in grants[@first].publish

    assert "$JS.edge_00000000000040008000000000000123.API.STREAM.UPDATE.flows" in grants[@first].publish

    refute ">" in grants[@first].publish
    refute "$JS.API.>" in grants[@first].publish
    refute "logs.syslog" in grants[@first].publish
  end

  test "bmp authorization grant covers a published update subject" do
    site = "00000000-0000-4000-8000-000000000123"

    components = [
      %{
        component_id: "example-bmp",
        component_type: "bmp-collector",
        edge_site_id: site
      },
      %{
        component_id: "example-flow",
        component_type: "flow-collector",
        edge_site_id: site
      }
    ]

    bmp = String.duplicate("d", 64)
    flow = String.duplicate("e", 64)

    grants =
      ManagedComponentNatsPermissions.snapshot(
        components,
        [
          %{component_id: "example-bmp", fingerprint: bmp, role: "client"},
          %{component_id: "example-flow", fingerprint: flow, role: "client"}
        ],
        [bmp, flow]
      )

    published = "arancini.updates.v4_10_0_0_1.64513.1_1"
    bmp_allow = signed_publish_allow(grants[bmp])
    flow_allow = signed_publish_allow(grants[flow])

    assert Enum.any?(bmp_allow, &nats_subject_allows?(&1, published))
    refute Enum.any?(bmp_allow, &nats_subject_allows?(&1, "arancini.updates"))
    refute Enum.any?(bmp_allow, &nats_subject_allows?(&1, "flows.raw.netflow"))
    assert Enum.any?(flow_allow, &nats_subject_allows?(&1, "flows.raw.netflow"))
    assert Enum.any?(flow_allow, &nats_subject_allows?(&1, "flows.raw.sflow"))
    refute Enum.any?(flow_allow, &nats_subject_allows?(&1, "flows.raw.netflow.extra"))
    refute Enum.any?(flow_allow, &nats_subject_allows?(&1, published))
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

  defp signed_publish_allow(permissions) do
    account = CertificateAuthorizationToken.new_key(:account)
    user = CertificateAuthorizationToken.new_key(:user)
    {:ok, signer} = NKEYS.Keypair.from_seed(account.seed)

    token =
      CertificateAuthorizationToken.encode_response(
        %{user_nkey: user.public_key, server_id: account.public_key, fingerprint: "subject"},
        {:allow, Map.put(permissions, :expires_at, 1_800_000_000)},
        signer,
        "EDGE",
        1_700_000_000
      )

    [_, body, _] = String.split(token, ".")
    {:ok, json} = Base.url_decode64(body, padding: false)
    {:ok, claims} = Jason.decode(json)
    [_, user_body, _] = String.split(claims["nats"]["jwt"], ".")
    {:ok, user_json} = Base.url_decode64(user_body, padding: false)
    {:ok, user_claims} = Jason.decode(user_json)
    user_claims["nats"]["pub"]["allow"]
  end

  defp nats_subject_allows?(pattern, subject) do
    match_subject_tokens(String.split(pattern, "."), String.split(subject, "."))
  end

  defp match_subject_tokens([">"], [_ | _]), do: true

  defp match_subject_tokens(["*" | pattern], [_ | subject]),
    do: match_subject_tokens(pattern, subject)

  defp match_subject_tokens([token | pattern], [token | subject]),
    do: match_subject_tokens(pattern, subject)

  defp match_subject_tokens([], []), do: true
  defp match_subject_tokens(_pattern, _subject), do: false
end
