defmodule ServiceRadar.Edge.ChartIdentityInventoryIntegrationTest do
  @moduledoc """
  First adoption of the chart's NATS client certificates, against the database.

  Every certificate, subject and file here is invented for the test.
  """
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ChartIdentityInventory, as: Inventory
  alias ServiceRadar.Edge.ComponentCertificate
  alias ServiceRadar.Edge.ComponentCertificateAuthority, as: Authority
  alias ServiceRadar.Edge.ManagedComponent

  require Ash.Query

  @moduletag :integration
  @moduletag :tmp_dir

  @core "CN=example-core,OU=Kubernetes,O=ExampleOrg"
  @web "CN=example-web,OU=Kubernetes,O=ExampleOrg"
  @core_subject "CN=example-core,O=ExampleOrg,OU=Kubernetes"
  @web_subject "CN=example-web,O=ExampleOrg,OU=Kubernetes"

  @oids %{o: {2, 5, 4, 10}, ou: {2, 5, 4, 11}, cn: {2, 5, 4, 3}}

  setup %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "certs"))

    root = :public_key.pkix_test_root_cert(~c"example-root", [])
    File.write!(Path.join(dir, "root.pem"), pem(root.cert))

    File.write!(Path.join(dir, "identities.yaml"), ~s(- "#{@core}"\n- "#{@web}"\n))

    File.write!(Path.join(dir, "static-users.yaml"), """
    - user: "#{@core}"
      publish: {allow: ["metrics.core.>"], deny: ["metrics.core.private"]}
      subscribe: {allow: [], deny: ["$SYS.>"]}
    - user: "#{@web}"
      publish: {allow: ["metrics.web.>"]}
      subscribe: {allow: ["_INBOX.>"]}
    - user: "CN=example-stranger,OU=Kubernetes,O=ExampleOrg"
      publish: {allow: ["metrics.stranger.>"]}
      subscribe: {allow: ["_INBOX.>"]}
    """)

    inputs = %{
      certificates_dir: Path.join(dir, "certs"),
      identities_file: Path.join(dir, "identities.yaml"),
      root_file: Path.join(dir, "root.pem"),
      static_users_file: Path.join(dir, "static-users.yaml"),
      partition_id: "example-partition"
    }

    %{
      dir: dir,
      root: root,
      inputs: inputs,
      opts: [actor: SystemActor.system(:chart_inventory_test)]
    }
  end

  test "adopts distinct chart identities once with their static grants", ctx do
    core = leaf(ctx.root, cn: "example-core", ou: "Kubernetes", o: "ExampleOrg")
    put_certificate(ctx, "core.pem", core)
    put_certificate(ctx, "core-copy.crt", core)

    web = leaf(ctx.root, [cn: "example-web", ou: "Kubernetes", o: "ExampleOrg"], 101)
    put_certificate(ctx, "web.crt", web)

    assert {:ok, report} = Inventory.reconcile(ctx.inputs)

    assert identity(report, @core_subject) == %{
             subject: @core_subject,
             status: :adopted,
             fingerprint: fingerprint(core),
             reason: nil
           }

    assert identity(report, @web_subject).status == :adopted
    assert {:ok, [core_certificate]} = certificates(@core_subject, ctx.opts)
    assert {:ok, [web_certificate]} = certificates(@web_subject, ctx.opts)
    assert core_certificate.fingerprint == fingerprint(core)
    assert web_certificate.fingerprint == fingerprint(web)
    refute core_certificate.component_id == web_certificate.component_id

    assert {:ok, component} = Ash.get(ManagedComponent, core_certificate.component_id, ctx.opts)
    assert component.component_type == "nats-client"
    assert component.partition_id == "example-partition"

    assert component.nats_permissions == %{
             "publish" => ["metrics.core.>"],
             "publish_deny" => ["metrics.core.private"],
             "subscribe" => [">"],
             "subscribe_deny" => ["$SYS.>"]
           }

    assert {:ok, snapshot} = Authority.snapshot()
    assert fingerprint(core) in snapshot.allowed_fingerprints
    assert fingerprint(web) in snapshot.allowed_fingerprints

    assert {:ok, ^report} = Inventory.reconcile(ctx.inputs)

    for {subject, previous} <- [
          {@core_subject, core_certificate},
          {@web_subject, web_certificate}
        ] do
      assert {:ok, [current]} = certificates(subject, ctx.opts)

      assert {current.fingerprint, current.component_id} ==
               {previous.fingerprint, previous.component_id}
    end

    File.write!(ctx.inputs.static_users_file, "[]")
    assert {:ok, ^report} = Inventory.reconcile(ctx.inputs)
  end

  test "distinct certificates for one subject require every fingerprint to be authorized", ctx do
    attributes = [cn: "example-core", ou: "Kubernetes", o: "ExampleOrg"]
    first = leaf(ctx.root, attributes, 111)
    second = leaf(ctx.root, attributes, 112)
    put_certificate(ctx, "core.pem", first)
    put_certificate(ctx, "renewal.crt", second)
    fingerprints = Enum.sort([fingerprint(first), fingerprint(second)])

    ambiguous = %{
      subject: @core_subject,
      fingerprint: nil,
      fingerprints: fingerprints,
      status: :not_adopted,
      reason: :ambiguous_inventory_certificates
    }

    assert {:ok, report} = Inventory.reconcile(ctx.inputs)
    assert identity(report, @core_subject) == ambiguous
    assert {:ok, []} = certificates(@core_subject, ctx.opts)

    File.rm!(Path.join(ctx.inputs.certificates_dir, "renewal.crt"))
    assert {:ok, report} = Inventory.reconcile(ctx.inputs)
    assert identity(report, @core_subject).status == :adopted
    assert {:ok, [recorded]} = certificates(@core_subject, ctx.opts)

    put_certificate(ctx, "renewal.crt", second)
    assert {:ok, report} = Inventory.reconcile(ctx.inputs)
    assert identity(report, @core_subject) == ambiguous

    assert {:ok, _successor} =
             Authority.record_infrastructure_successor(
               recorded.component_id,
               %{certificate_pem: pem(second) <> pem(ctx.root.cert)},
               ctx.opts
             )

    assert {:ok, report} = Inventory.reconcile(ctx.inputs)
    assert identity(report, @core_subject) == %{ambiguous | status: :adopted, reason: nil}
  end

  test "records the direct issuer when the inventory includes an intermediate", ctx do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    chain = :public_key.pkix_test_data(%{root: ctx.root, intermediates: [[key: key]], peer: []})
    [intermediate] = Enum.reject(chain[:cacerts], &(&1 == ctx.root.cert))

    core =
      sign_leaf(chain[:cert], key, [cn: "example-core", ou: "Kubernetes", o: "ExampleOrg"], 103)

    put_certificate(ctx, "bare.crt", core)

    File.write!(
      Path.join(ctx.inputs.certificates_dir, "core.pem"),
      pem(core) <> pem(intermediate)
    )

    assert {:ok, report} = Inventory.reconcile(ctx.inputs)
    assert identity(report, @core_subject).status == :adopted
    assert {:ok, [certificate]} = certificates(@core_subject, ctx.opts)
    assert certificate.fingerprint == fingerprint(core)
    assert certificate.issuer_fingerprint == fingerprint(intermediate)
  end

  test "writes nothing for a held subject, including after revocation", ctx do
    first = leaf(ctx.root, [cn: "example-core", ou: "Kubernetes", o: "ExampleOrg"], 101)
    put_certificate(ctx, "core.pem", first)
    assert {:ok, _report} = Inventory.reconcile(ctx.inputs)

    assert {:ok, _decision} =
             Authority.revoke_certificate(fingerprint(first), "operator-request", ctx.opts)

    # The chart regenerates the certificate for the same identity.
    second = leaf(ctx.root, [cn: "example-core", ou: "Kubernetes", o: "ExampleOrg"], 102)
    put_certificate(ctx, "core.pem", second)

    assert {:ok, report} = Inventory.reconcile(ctx.inputs)

    assert identity(report, @core_subject) == %{
             subject: @core_subject,
             status: :not_adopted,
             fingerprint: fingerprint(second),
             reason: :held_unrecorded
           }

    assert {:ok, [only]} = certificates(@core_subject, ctx.opts)
    assert only.fingerprint == fingerprint(first)

    assert {:ok, snapshot} = Authority.snapshot()
    refute fingerprint(second) in snapshot.allowed_fingerprints
    refute fingerprint(first) in snapshot.allowed_fingerprints
  end

  test "reports a recorded certificate the authority no longer authorizes", ctx do
    core = leaf(ctx.root, cn: "example-core", ou: "Kubernetes", o: "ExampleOrg")
    put_certificate(ctx, "core.pem", core)
    assert {:ok, _report} = Inventory.reconcile(ctx.inputs)

    assert {:ok, _decision} =
             Authority.revoke_certificate(fingerprint(core), "operator-request", ctx.opts)

    other_root = :public_key.pkix_test_root_cert(~c"example-replacement-root", [])
    File.write!(ctx.inputs.root_file, pem(other_root.cert))

    assert {:ok, report} = Inventory.reconcile(ctx.inputs)
    assert identity(report, @core_subject).status == :not_adopted
    assert identity(report, @core_subject).reason == :recorded_not_authorized
  end

  test "adopts nothing while an infrastructure certificate has no stored subject", ctx do
    assert {:ok, baseline} = Inventory.reconcile(ctx.inputs)
    legacy_id = "example-legacy-#{System.unique_integer([:positive])}"

    assert {:ok, %{num_rows: 1}} =
             ServiceRadar.Repo.query(
               """
               INSERT INTO platform.managed_components
                 (component_id, component_type, partition_id, generation_started_by)
               VALUES ($1, 'nats-client', 'example-partition', 'example-operator')
               """,
               [legacy_id]
             )

    now = DateTime.utc_now()

    assert {:ok, %{num_rows: 1}} =
             ServiceRadar.Repo.query(
               """
               INSERT INTO platform.component_certificates
                 (fingerprint, issuer_fingerprint, serial_number, generation, role,
                  not_before, not_after, component_id)
               VALUES ($1, $1, '17', 1, 'client', $2, $3, $4)
               """,
               [
                 fingerprint("legacy-certificate"),
                 DateTime.shift(now, minute: -1),
                 DateTime.shift(now, hour: 1),
                 legacy_id
               ]
             )

    core = leaf(ctx.root, cn: "example-core", ou: "Kubernetes", o: "ExampleOrg")
    put_certificate(ctx, "core.pem", core)

    assert {:ok, report} = Inventory.reconcile(ctx.inputs)
    assert report.legacy_certificates == baseline.legacy_certificates + 1
    assert identity(report, @core_subject).status == :not_adopted
    assert identity(report, @core_subject).reason == :legacy_certificates_without_subject
    assert {:ok, []} = certificates(@core_subject, ctx.opts)
  end

  test "an expired CA retains the adoption error and reports inventory expiry", ctx do
    core = leaf(ctx.root, cn: "example-core", ou: "Kubernetes", o: "ExampleOrg")

    expired =
      :public_key.pkix_test_root_cert(~c"example-root",
        key: ctx.root.key,
        validity: {{2020, 1, 1}, {2020, 6, 1}}
      )

    File.write!(ctx.inputs.root_file, pem(expired.cert))
    put_certificate(ctx, "core.pem", core)

    assert {:error, :untrusted_issuer} =
             Authority.adopt_existing_certificate(
               %{
                 component_id: "example-expired-issuer",
                 component_type: "nats-client",
                 partition_id: ctx.inputs.partition_id,
                 certificate_pem: pem(core) <> pem(expired.cert),
                 permissions: %{
                   publish: %{allow: ["metrics.core.>"]},
                   subscribe: %{allow: ["_INBOX.>"]}
                 }
               },
               ctx.opts
             )

    assert {:ok, report} = Inventory.reconcile(ctx.inputs)
    assert identity(report, @core_subject).reason == :certificate_not_valid
    assert {:ok, []} = certificates(@core_subject, ctx.opts)
  end

  test "refuses a certificate from another issuer and one with no static user", ctx do
    other_root = :public_key.pkix_test_root_cert(~c"other-root", [])
    foreign = leaf(other_root, cn: "example-core", ou: "Kubernetes", o: "ExampleOrg")
    put_certificate(ctx, "core.pem", foreign)

    web = leaf(ctx.root, cn: "example-web", ou: "Kubernetes", o: "ExampleOrg")
    put_certificate(ctx, "web.pem", web)

    File.write!(ctx.inputs.static_users_file, """
    - user: "#{@core}"
      publish: {allow: ["metrics.core.>"]}
      subscribe: {allow: ["_INBOX.>"]}
    """)

    assert {:ok, report} = Inventory.reconcile(ctx.inputs)
    assert identity(report, @core_subject).reason == :untrusted_issuer
    assert identity(report, @web_subject).reason == :no_static_user
    assert {:ok, []} = certificates(@core_subject, ctx.opts)
    assert {:ok, []} = certificates(@web_subject, ctx.opts)
  end

  test "does not adopt a certificate whose subject the chart does not list", ctx do
    stranger = leaf(ctx.root, cn: "example-stranger", ou: "Kubernetes", o: "ExampleOrg")
    put_certificate(ctx, "stranger.pem", stranger)
    core = leaf(ctx.root, cn: "example-core", ou: "Kubernetes", o: "ExampleOrg")
    put_certificate(ctx, "valid.crt", core)

    dir = ctx.inputs.certificates_dir
    File.write!(Path.join(dir, "notes.txt"), "not a certificate")
    File.write!(Path.join(dir, "broken.pem"), "-----BEGIN CERTIFICATE-----\nAQID\n")
    File.write!(Path.join(dir, "invalid-chain.crt"), pem(core) <> pem(<<1, 2, 3>>))
    bad_key = malformed_public_key(core)
    put_certificate(ctx, "bad-key.crt", bad_key)
    File.write!(Path.join(dir, "bad-issuer.crt"), pem(core) <> pem(bad_key))
    File.write!(Path.join(dir, ".hidden"), "ignored")
    File.mkdir!(Path.join(dir, "nested"))
    File.write!(Path.join(dir, "nested/notes.txt"), "ignored")

    assert {:ok, report} = Inventory.reconcile(ctx.inputs)

    assert report.unlisted == [
             %{file: "bad-issuer.crt", reason: :invalid_certificate},
             %{file: "bad-key.crt", reason: :invalid_certificate},
             %{file: "broken.pem", reason: :invalid_certificate},
             %{file: "invalid-chain.crt", reason: :invalid_certificate},
             %{file: "notes.txt", reason: :invalid_certificate},
             %{file: "stranger.pem", reason: :not_a_chart_identity}
           ]

    assert identity(report, @core_subject).status == :adopted
    assert identity(report, @web_subject).reason == :no_inventory_certificate
    stranger_subject = "CN=example-stranger,O=ExampleOrg,OU=Kubernetes"
    refute identity(report, stranger_subject)
    assert {:ok, []} = certificates(stranger_subject, ctx.opts)
  end

  test "an unreadable or malformed identities file stops all adoption", ctx do
    core = leaf(ctx.root, cn: "example-core", ou: "Kubernetes", o: "ExampleOrg")
    put_certificate(ctx, "core.pem", core)

    missing = %{ctx.inputs | identities_file: Path.join(ctx.dir, "missing.yaml")}
    assert Inventory.reconcile(missing) == {:error, :invalid_chart_identities}
    assert {:ok, []} = certificates(@core_subject, ctx.opts)

    File.write!(ctx.inputs.identities_file, "not: a list\n")
    assert Inventory.reconcile(ctx.inputs) == {:error, :invalid_chart_identities}
    assert {:ok, []} = certificates(@core_subject, ctx.opts)
  end

  test "malformed root PEM or DER stops all adoption", ctx do
    core = leaf(ctx.root, cn: "example-core", ou: "Kubernetes", o: "ExampleOrg")
    put_certificate(ctx, "core.pem", core)

    for malformed <- [
          "-----BEGIN CERTIFICATE-----\nAQID\n",
          pem(<<1, 2, 3>>),
          pem(malformed_public_key(ctx.root.cert))
        ] do
      File.write!(ctx.inputs.root_file, malformed)
      assert Inventory.reconcile(ctx.inputs) == {:error, :invalid_root_certificate}
      assert {:ok, []} = certificates(@core_subject, ctx.opts)
    end
  end

  test "a malformed static user prevents adoption of its valid sibling", ctx do
    core = leaf(ctx.root, cn: "example-core", ou: "Kubernetes", o: "ExampleOrg")
    put_certificate(ctx, "core.pem", core)

    File.write!(ctx.inputs.static_users_file, "- user: CN=example-invalid\n  publish: {}\n", [
      :append
    ])

    assert Inventory.reconcile(ctx.inputs) == {:error, :invalid_static_users}
    assert {:ok, []} = certificates(@core_subject, ctx.opts)
  end

  defp identity(report, subject), do: Enum.find(report.identities, &(&1.subject == subject))

  defp certificates(subject, opts) do
    ComponentCertificate
    |> Ash.Query.filter(subject == ^subject)
    |> Ash.read(opts)
  end

  defp put_certificate(ctx, name, der),
    do: File.write!(Path.join(ctx.inputs.certificates_dir, name), pem(der))

  defp pem(der), do: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])

  defp malformed_public_key(der) do
    {:Certificate, tbs, algorithm, signature} = :public_key.pkix_decode_cert(der, :plain)
    rsa = {:AlgorithmIdentifier, {1, 2, 840, 113_549, 1, 1, 1}, <<5, 0>>}
    spki = {:SubjectPublicKeyInfo, rsa, <<1, 2, 3>>}

    :public_key.der_encode(
      :Certificate,
      {:Certificate, put_elem(tbs, 7, spki), algorithm, signature}
    )
  end

  # A certificate for `attributes`, signed by `root`.
  defp leaf(root, attributes, serial \\ 100) do
    sign_leaf(root.cert, root.key, attributes, serial)
  end

  defp sign_leaf(template, key, attributes, serial) do
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(template, :otp)

    rdns =
      Enum.map(attributes, fn {type, value} ->
        [{:AttributeTypeAndValue, Map.fetch!(@oids, type), {:utf8String, value}}]
      end)

    tbs
    |> put_elem(2, serial)
    |> put_elem(6, {:rdnSequence, rdns})
    |> :public_key.pkix_sign(key)
  end

  defp fingerprint(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end
