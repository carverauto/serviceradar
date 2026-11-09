defmodule ServiceRadar.NetworkDiscovery.ContainedDgraphProjectionTest do
  @moduledoc """
  CONTAINS projection against a live Dgraph scratch namespace.

  Virtualization inventory (Proxmox today, other hypervisors through the same
  `HypervisorEnrichmentIngestor` envelope) owns the host-contains-guest
  relationship: the same saved guest/host evidence that projects the
  `HOSTED_ON` edge must project its `CONTAINS` twin. Every id and address is
  invented; the scratch namespace is dropped on exit.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dgraph
  alias ServiceRadar.Inventory.HypervisorEnrichmentIngestor
  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.DgraphPersist
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Pruning
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.DgraphScratch

  require Ash.Query

  @moduletag :integration
  # Three-state fixture gating (see DgraphScratch): unconfigured skips,
  # partial fails loudly in setup_all, configured runs against dgraph-ci.
  @moduletag skip: DgraphScratch.fixture_state() == :unconfigured

  @provider "contained-projection-fixture"
  @observed_at ~U[2030-02-03 04:05:06Z]

  setup_all do
    TestSupport.start_core!()
    DgraphScratch.setup_scratch()
  end

  setup do
    {:ok, actor: SystemActor.system(:contained_dgraph_projection_test)}
  end

  test "projects CONTAINS alongside HOSTED_ON for a saved guest", %{actor: actor} do
    {guest_uid, host_uid} = save_guest_on_host(actor, "twin")

    assert {:ok, _} = HypervisorEnrichmentIngestor.reconcile_hosted_topology()

    assert [{^host_uid, ^guest_uid}] = contained_edges(host_uid)
    assert [{^guest_uid, ^host_uid}] = hosted_edges(guest_uid)
  end

  test "re-ingesting the same inventory does not duplicate the edge", %{actor: actor} do
    {guest_uid, host_uid} = save_guest_on_host(actor, "idempotent")

    assert {:ok, _} = HypervisorEnrichmentIngestor.reconcile_hosted_topology()
    assert {:ok, _} = HypervisorEnrichmentIngestor.reconcile_hosted_topology()

    assert [{^host_uid, ^guest_uid}] = contained_edges(host_uid)
  end

  test "reparenting replaces the containment edge", %{actor: actor} do
    {guest_uid, first_host_uid} = save_guest_on_host(actor, "reparent")
    second_host_uid = host_uid("reparent-second")
    create_host!(actor, "reparent-second", second_host_uid)

    assert {:ok, _} = HypervisorEnrichmentIngestor.reconcile_hosted_topology()
    assert [{^first_host_uid, ^guest_uid}] = contained_edges(first_host_uid)

    guest = get_guest!(guest_uid, actor)

    guest
    |> Ash.Changeset.for_update(:update, %{host_id: host_id!(second_host_uid, actor)},
      actor: actor
    )
    |> Ash.update!(actor: actor)

    assert {:ok, _} = HypervisorEnrichmentIngestor.reconcile_hosted_topology()

    assert [{^second_host_uid, ^guest_uid}] = contained_edges(second_host_uid)
    assert [] = contained_edges(first_host_uid)
  end

  test "retires the edge when its source evidence goes away", %{actor: actor} do
    {guest_uid, host_uid} = save_guest_on_host(actor, "retire")

    assert {:ok, _} = HypervisorEnrichmentIngestor.reconcile_hosted_topology()
    assert [{^host_uid, ^guest_uid}] = contained_edges(host_uid)

    guest_uid |> get_guest!(actor) |> Ash.destroy!(actor: actor)

    assert {:ok, _} = HypervisorEnrichmentIngestor.reconcile_hosted_topology()

    assert [] = contained_edges(host_uid)
    assert [] = hosted_edges(guest_uid)
  end

  test "time prune ages out a stale CONTAINS edge" do
    host = "sr:it-6297-prune-host"
    guest = "sr:it-6297-prune-guest"

    assert :ok =
             DgraphPersist.upsert_contained_link(%{
               guest_device_id: guest,
               host_device_id: host,
               observed_at: "2020-01-01T00:00:00Z"
             })

    assert [{^host, ^guest}] = contained_edges(host)

    Pruning.prune_stale_mapper_evidence_links()

    assert [] = contained_edges(host)
  end

  defp save_guest_on_host(actor, suffix) do
    guest_uid = "sr:it-6297-#{suffix}-guest"
    host_uid = host_uid(suffix)
    host = create_host!(actor, suffix, host_uid)

    VirtualizationGuest
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider: @provider,
        provider_ref: "synthetic-6297-guest-#{suffix}",
        host_id: host.id,
        device_uid: guest_uid,
        name: "synthetic-6297-guest",
        guest_type: "vm",
        observed_at: @observed_at
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    on_exit(fn ->
      destroy_guest(guest_uid)
      destroy_host(host_uid)
    end)

    {guest_uid, host_uid}
  end

  defp host_uid(suffix), do: "sr:it-6297-#{suffix}-host"

  defp create_host!(actor, suffix, uid) do
    host =
      VirtualizationHost
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider: @provider,
          provider_ref: "synthetic-6297-host-#{suffix}",
          device_uid: uid,
          name: "synthetic-6297-host",
          observed_at: @observed_at
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    on_exit(fn -> destroy_host(uid) end)

    host
  end

  defp get_guest!(uid, actor) do
    VirtualizationGuest
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(device_uid == ^uid)
    |> Ash.read_one!(actor: actor)
  end

  defp host_id!(uid, actor) do
    VirtualizationHost
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(device_uid == ^uid)
    |> Ash.read_one!(actor: actor)
    |> Map.fetch!(:id)
  end

  defp destroy_guest(uid) do
    actor = SystemActor.system(:contained_dgraph_projection_test)

    case get_guest!(uid, actor) do
      nil -> :ok
      guest -> Ash.destroy!(guest, actor: actor)
    end
  end

  defp destroy_host(uid) do
    actor = SystemActor.system(:contained_dgraph_projection_test)

    VirtualizationHost
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(device_uid == ^uid)
    |> Ash.read_one!(actor: actor)
    |> case do
      nil -> :ok
      host -> Ash.destroy!(host, actor: actor)
    end
  end

  defp contained_edges(host_uid) do
    assert {:ok, %{"edges" => edges}} =
             Dgraph.query(
               ~s|{ edges(func: eq(topo.ingestor, "hypervisor_enrichment_v1")) @filter(eq(topo.kind, "CONTAINS")) { source: topo.src { id: device.id } target: topo.dst { id: device.id } } }|
             )

    for %{"source" => [%{"id" => source}], "target" => [%{"id" => target}]} <- edges,
        source == host_uid do
      {source, target}
    end
  end

  defp hosted_edges(guest_uid) do
    assert {:ok, %{"edges" => edges}} =
             Dgraph.query(
               ~s|{ edges(func: eq(topo.ingestor, "hypervisor_enrichment_v1")) @filter(eq(topo.kind, "HOSTED_ON")) { source: topo.src { id: device.id } target: topo.dst { id: device.id } } }|
             )

    for %{"source" => [%{"id" => source}], "target" => [%{"id" => target}]} <- edges,
        source == guest_uid do
      {source, target}
    end
  end
end
