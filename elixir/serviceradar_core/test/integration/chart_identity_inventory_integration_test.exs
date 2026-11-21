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
      publish: {allow: ["metrics.core.>"]}
      subscribe: {allow: ["_INBOX.>"], deny: ["$SYS.>"]}
    - user: "#{@web}"
      publish: {allow: ["metrics.web.>"]}
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

  test "adopts an unheld chart identity once, with its static grant", ctx do
    core = leaf(ctx.root, cn: "example-core", ou: "Kubernetes", o: "ExampleOrg")
    put_certificate(ctx, "core.pem", core)

    assert {:ok, report} = Inventory.reconcile(ctx.inputs)

    assert identity(report, @core_subject) == %{
             subject: @core_subject,
             status: :adopted,
             fingerprint: fingerprint(core),
             reason: nil
           }

    assert identity(report, @web_subject).reason == :no_inventory_certificate

    component_id = Inventory.component_id(@core_subject)
    assert {:ok, component} = Ash.get(ManagedComponent, component_id, ctx.opts)
    assert component.component_type == "nats-client"
    assert component.partition_id == "example-partition"
    assert component.nats_permissions["publish"] == ["metrics.core.>"]
    assert component.nats_permissions["subscribe"] == ["_INBOX.>"]
    assert component.nats_permissions["subscribe_deny"] == ["$SYS.>"]

    assert {:ok, [certificate]} = certificates(@core_subject, ctx.opts)
    assert certificate.fingerprint == fingerprint(core)
    assert certificate.component_id == component_id

    assert {:ok, snapshot} = Authority.snapshot()
    assert fingerprint(core) in snapshot.allowed_fingerprints

    # A second pass finds it recorded and writes nothing more.
    assert {:ok, again} = Inventory.reconcile(ctx.inputs)
    assert identity(again, @core_subject).status == :adopted
    assert {:ok, [_only]} = certificates(@core_subject, ctx.opts)
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

    assert {:ok, report} = Inventory.reconcile(ctx.inputs)
    assert identity(report, @core_subject).status == :not_adopted
    assert identity(report, @core_subject).reason == :recorded_not_authorized
  end

  test "adopts nothing while an infrastructure certificate has no stored subject", ctx do
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
    assert report.legacy_certificates == 1
    assert identity(report, @core_subject).status == :not_adopted
    assert identity(report, @core_subject).reason == :legacy_certificates_without_subject
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
    File.write!(Path.join(ctx.inputs.certificates_dir, "notes.pem"), "not a certificate")

    assert {:ok, report} = Inventory.reconcile(ctx.inputs)

    assert report.unlisted == [
             %{file: "notes.pem", reason: :invalid_certificate},
             %{file: "stranger.pem", reason: :not_a_chart_identity}
           ]

    assert {:ok, []} = certificates("CN=example-stranger,O=ExampleOrg,OU=Kubernetes", ctx.opts)
  end

  test "an unreadable identities file is an error and nothing is written", ctx do
    core = leaf(ctx.root, cn: "example-core", ou: "Kubernetes", o: "ExampleOrg")
    put_certificate(ctx, "core.pem", core)
    File.write!(ctx.inputs.identities_file, "not: a list\n")

    assert Inventory.reconcile(ctx.inputs) == {:error, :invalid_chart_identities}
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

  # A certificate for `attributes`, signed by `root`.
  defp leaf(root, attributes, serial \\ 100) do
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(root.cert, :otp)

    rdns =
      Enum.map(attributes, fn {type, value} ->
        [{:AttributeTypeAndValue, Map.fetch!(@oids, type), {:utf8String, value}}]
      end)

    tbs
    |> put_elem(2, serial)
    |> put_elem(6, {:rdnSequence, rdns})
    |> :public_key.pkix_sign(root.key)
  end

  defp fingerprint(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end
