defmodule ServiceRadar.Edge.InfrastructureCertificateAdoptionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.CertificateLifetimePolicy
  alias ServiceRadar.Edge.InfrastructureCertificateAdoption, as: Adoption

  test "adopts a static NATS client with its existing grant and public certificate" do
    %{pem: pem, der: der} = self_signed()

    assert {:ok, prepared} =
             Adoption.prepare(
               Map.put(attrs(pem, empty_subscribe()), :component_type, "nats-client")
             )

    assert prepared.component.component_type == "nats-client"
    assert prepared.component.server_hosts == []
    assert prepared.component.permissions["publish"] == ["metrics.example.>"]
    assert prepared.component.permissions["publish_deny"] == []
    assert prepared.component.permissions["subscribe"] == [">"]
    assert prepared.component.permissions["subscribe_deny"] == ["$SYS.>", "flow.example.>"]

    assert prepared.issuance.fingerprint == fingerprint(der)
    assert prepared.issuance.issuer_fingerprint == prepared.issuance.fingerprint
    assert prepared.issuance.serial_number == serial_number(der)
    assert prepared.issuance.role == "client"
    assert prepared.issuance.host_agent_id == nil
    assert prepared.issuance.expected_generation == 1
    assert {:ok, not_after} = CertificateLifetimePolicy.certificate_not_after(pem)
    assert DateTime.compare(prepared.issuance.not_after, not_after) == :eq
    assert DateTime.after?(prepared.issuance.not_after, prepared.issuance.not_before)
  end

  test "records the DER Name when the matcher cannot read a BMPString common name" do
    %{cert: root, key: key} = :public_key.pkix_test_root_cert(~c"example-root", [])
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(root, :otp)
    cn = {:AttributeTypeAndValue, {2, 5, 4, 3}, {:bmpString, [{0, 0, 1, 65}]}}
    name = {:rdnSequence, [[cn]]}
    der = tbs |> put_elem(4, name) |> put_elem(6, name) |> :public_key.pkix_sign(key)
    pem = :public_key.pem_encode([{:Certificate, der, :not_encrypted}])

    assert {:ok, prepared} = Adoption.prepare(attrs(pem, empty_subscribe()))
    assert prepared.issuance.subject == "#300d310b300906035504031e020141"
  end

  test "keeps an explicit allow and uses the issuer certificate that signed the leaf" do
    %{leaf: leaf, issuer: issuer, pem: pem} = signed_chain()

    assert {:ok, prepared} =
             Adoption.prepare(
               attrs(pem, %{
                 publish: %{allow: ["metrics.example.>"]},
                 subscribe: %{allow: ["events.example.>"], deny: ["$SYS.>"]}
               })
             )

    assert prepared.component.permissions["subscribe"] == ["events.example.>"]
    assert prepared.component.permissions["subscribe_deny"] == ["$SYS.>"]
    assert prepared.issuance.fingerprint == fingerprint(leaf)
    assert prepared.issuance.issuer_fingerprint == fingerprint(issuer)
    refute prepared.issuance.issuer_fingerprint == prepared.issuance.fingerprint
  end

  test "refuses private keys, bad issuers, expired certificates, and non-infrastructure types" do
    %{pem: pem} = self_signed()

    assert {:error, :private_key} =
             Adoption.prepare(attrs(pem <> private_key_pem(), empty_subscribe()))

    assert {:error, :issuer_certificate_required} =
             Adoption.prepare(attrs(signed_chain().leaf_pem, empty_subscribe()))

    unrelated = pem <> self_signed(~c"example-other").pem

    assert {:error, :untrusted_issuer} =
             Adoption.prepare(attrs(unrelated, empty_subscribe()))

    expired = self_signed(~c"example-expired", validity: {{2020, 1, 1}, {2020, 6, 1}})

    assert {:error, :certificate_not_valid} =
             Adoption.prepare(attrs(expired.pem, empty_subscribe()))

    assert {:error, :not_infrastructure} =
             Adoption.prepare(
               Map.put(attrs(pem, empty_subscribe()), :component_type, "nats-leaf")
             )
  end

  defp attrs(pem, permissions) do
    %{
      component_id: "example-gateway",
      component_type: "agent-gateway",
      partition_id: "example-partition",
      certificate_pem: pem,
      permissions: permissions
    }
  end

  defp empty_subscribe do
    %{
      publish: %{allow: ["metrics.example.>"], deny: []},
      subscribe: %{allow: [], deny: ["$SYS.>", "flow.example.>"]}
    }
  end

  defp self_signed(name \\ ~c"example-gateway", opts \\ []) do
    %{cert: der} = :public_key.pkix_test_root_cert(name, opts)

    %{
      der: der,
      pem: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
    }
  end

  defp signed_chain do
    alg = [
      {:digest, :sha256},
      {:key, {:namedCurve, :secp256r1}}
    ]

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{root: alg, intermediates: [], peer: alg},
        client_chain: %{root: alg, intermediates: [], peer: alg}
      })

    leaf = Keyword.fetch!(data.client_config, :cert)

    issuer =
      Enum.find(Keyword.fetch!(data.client_config, :cacerts), fn der ->
        match?({:ok, _}, :public_key.pkix_path_validation(der, [leaf], []))
      end)

    %{
      leaf: leaf,
      issuer: issuer,
      leaf_pem: :public_key.pem_encode([{:Certificate, leaf, :not_encrypted}]),
      pem:
        :public_key.pem_encode([
          {:Certificate, leaf, :not_encrypted},
          {:Certificate, issuer, :not_encrypted}
        ])
    }
  end

  defp private_key_pem do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])
  end

  defp fingerprint(der), do: :sha256 |> :crypto.hash(der) |> Base.encode16(case: :lower)

  defp serial_number(der) do
    {:Certificate, tbs, _, _} = :public_key.pkix_decode_cert(der, :plain)

    tbs
    |> elem(2)
    |> Integer.to_string(16)
    |> String.downcase()
  end
end
