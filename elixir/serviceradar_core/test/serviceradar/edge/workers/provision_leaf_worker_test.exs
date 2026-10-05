defmodule ServiceRadar.Edge.Workers.ProvisionLeafWorkerTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.EdgeSite
  alias ServiceRadar.Edge.NatsLeafServer
  alias ServiceRadar.Edge.Workers.ProvisionLeafWorker

  @moduletag :database

  defmodule IssuingStub do
    @moduledoc false
    def issue(edge_site) do
      send(self(), {:issued_for, edge_site.slug})
      {cert, key} = ServiceRadar.Edge.Workers.ProvisionLeafWorkerTest.self_signed()

      {:ok,
       %{
         leaf_cert_pem: cert,
         leaf_key_pem: key,
         server_cert_pem: cert,
         server_key_pem: key,
         ca_chain_pem: cert
       }}
    end
  end

  defmodule UnavailableStub do
    @moduledoc false
    def issue(_edge_site), do: {:error, :gateway_unavailable}
  end

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:test)
    u = :erlang.unique_integer([:positive])

    {:ok, site} =
      EdgeSite
      |> Ash.Changeset.for_create(:create, %{name: "Leaf Site #{u}", slug: "leaf-site-#{u}"})
      |> Ash.create(actor: actor)

    {:ok, leaf_server} =
      NatsLeafServer
      |> Ash.Query.for_read(:by_edge_site, %{edge_site_id: site.id})
      |> Ash.read_one(actor: actor)

    %{actor: actor, site: site, leaf_server: leaf_server}
  end

  test "issues certificates and provisions the pending leaf server", %{
    actor: actor,
    site: site,
    leaf_server: leaf_server
  } do
    assert leaf_server.status == :pending

    assert :ok = ProvisionLeafWorker.perform(job(leaf_server.id), certificate_issuer: IssuingStub)
    assert_received {:issued_for, slug}
    assert slug == site.slug

    provisioned = Ash.get!(NatsLeafServer, leaf_server.id, actor: actor)
    assert provisioned.status == :provisioned
    assert provisioned.leaf_cert_pem =~ "BEGIN CERTIFICATE"
    assert provisioned.server_cert_pem =~ "BEGIN CERTIFICATE"
    assert provisioned.ca_chain_pem =~ "BEGIN CERTIFICATE"
    assert is_binary(provisioned.config_checksum)
    assert %DateTime{} = provisioned.cert_expires_at

    decrypted =
      Ash.load!(provisioned, [:leaf_key_pem_ciphertext, :server_key_pem_ciphertext], actor: actor)

    assert decrypted.leaf_key_pem_ciphertext =~ "PRIVATE KEY"
    assert decrypted.server_key_pem_ciphertext =~ "PRIVATE KEY"
  end

  test "returns an error for retry and stays pending when no gateway can issue", %{
    actor: actor,
    leaf_server: leaf_server
  } do
    assert {:error, :gateway_unavailable} =
             ProvisionLeafWorker.perform(job(leaf_server.id), certificate_issuer: UnavailableStub)

    assert Ash.get!(NatsLeafServer, leaf_server.id, actor: actor).status == :pending
  end

  test "leaves an already provisioned leaf server alone", %{leaf_server: leaf_server} do
    assert :ok = ProvisionLeafWorker.perform(job(leaf_server.id), certificate_issuer: IssuingStub)
    assert_received {:issued_for, _}

    assert :ok = ProvisionLeafWorker.perform(job(leaf_server.id), certificate_issuer: IssuingStub)
    refute_received {:issued_for, _}
  end

  test "cancels when the leaf server no longer exists" do
    assert {:cancel, :leaf_server_not_found} =
             ProvisionLeafWorker.perform(job(Ash.UUID.generate()),
               certificate_issuer: IssuingStub
             )
  end

  @doc false
  def self_signed do
    %{cert: der, key: key} = :public_key.pkix_test_root_cert(~c"leaf-test", [])
    cert_pem = :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
    key_pem = :public_key.pem_encode([:public_key.pem_entry_encode(elem(key, 0), key)])
    {cert_pem, key_pem}
  end

  defp job(leaf_server_id), do: %Oban.Job{args: %{"leaf_server_id" => leaf_server_id}}
end
