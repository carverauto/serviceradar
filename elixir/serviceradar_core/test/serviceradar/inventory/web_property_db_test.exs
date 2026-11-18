defmodule ServiceRadar.Inventory.WebPropertyDbTest do
  @moduledoc """
  Database integration tests for L7 `WebProperty`, `WebPropertyBinding`,
  `ServiceCheck.web_property_id`, RBAC policies, and `WebPropertyDiscoveryWorker`.
  """
  use ServiceRadar.DataCase, async: true

  import Ecto.Query

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.WebProperty
  alias ServiceRadar.Inventory.WebPropertyBinding
  alias ServiceRadar.Inventory.WebPropertyDiscoveryWorker
  alias ServiceRadar.Monitoring.ServiceCheck
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:web_property_db_test)}
  end

  test "normalizes canonical_origin, enforces uniqueness, and rotates rum_site_key", %{
    actor: actor
  } do
    {:ok, wp} =
      WebProperty
      |> Ash.Changeset.for_create(:create, %{
        name: "Shop",
        canonical_origin: "HTTPS://Shop.Example.COM:443/checkout?a=1#frag"
      })
      |> Ash.create(actor: actor)

    assert wp.canonical_origin == "https://shop.example.com"
    assert WebProperty.valid_rum_site_key?(wp.rum_site_key)

    assert {:error, _} =
             WebProperty
             |> Ash.Changeset.for_create(:create, %{
               name: "Shop Dup",
               canonical_origin: "https://shop.example.com"
             })
             |> Ash.create(actor: actor)

    old_key = wp.rum_site_key

    {:ok, rotated} =
      wp
      |> Ash.Changeset.for_update(:rotate_rum_site_key, %{})
      |> Ash.update(actor: actor)

    assert rotated.rum_site_key != old_key
    assert WebProperty.valid_rum_site_key?(rotated.rum_site_key)

    assert {:ok, found} = WebProperty.get_by_rum_site_key(rotated.rum_site_key, actor: actor)
    assert found.id == wp.id
    assert {:error, _} = WebProperty.get_by_rum_site_key(old_key, actor: actor)
  end

  test "enforces RBAC permissions devices.view and settings.networks.manage", %{actor: actor} do
    {:ok, wp} =
      WebProperty
      |> Ash.Changeset.for_create(:create, %{
        name: "RBAC Site",
        canonical_origin: "https://rbac-#{System.unique_integer([:positive])}.example.com"
      })
      |> Ash.create(actor: actor)

    viewer = %{id: "viewer-1", role: :viewer, permissions: MapSet.new(["devices.view"])}

    operator = %{
      id: "operator-1",
      role: :operator,
      permissions: MapSet.new(["devices.view", "settings.networks.manage"])
    }

    unprivileged = %{id: "none-1", role: :viewer, permissions: MapSet.new()}

    assert {:ok, [_ | _]} = Ash.read(WebProperty, actor: viewer)
    assert {:error, %Forbidden{}} = Ash.read(WebProperty, actor: unprivileged)

    assert {:error, %Forbidden{}} =
             WebProperty
             |> Ash.Changeset.for_create(:create, %{
               name: "Denied",
               canonical_origin: "https://denied.example.com"
             })
             |> Ash.create(actor: viewer)

    assert {:error, %Forbidden{}} =
             wp
             |> Ash.Changeset.for_update(:rotate_rum_site_key, %{})
             |> Ash.update(actor: viewer)

    assert {:ok, updated} =
             wp
             |> Ash.Changeset.for_update(:update, %{name: "RBAC Updated"})
             |> Ash.update(actor: operator)

    assert updated.name == "RBAC Updated"
  end

  test "supports all three WebPropertyBinding kinds and ServiceCheck.web_property_id", %{
    actor: actor
  } do
    {:ok, wp} =
      WebProperty
      |> Ash.Changeset.for_create(:create, %{
        name: "Bound Site",
        canonical_origin: "https://bound-#{System.unique_integer([:positive])}.example.com"
      })
      |> Ash.create(actor: actor)

    device_uid = "sr:" <> Ecto.UUID.generate()

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: device_uid,
        ip: "198.51.100.40",
        hostname: "origin-host"
      })
      |> Ash.create(actor: actor)

    {:ok, _b1} =
      WebPropertyBinding
      |> Ash.Changeset.for_create(:create, %{
        web_property_id: wp.id,
        binding_kind: :k8s_public_endpoint,
        source: :k8s_discovery,
        cluster_id: "demo",
        namespace: "web",
        resource_kind: "HTTPRoute",
        resource_name: "bound-route"
      })
      |> Ash.create(actor: actor)

    {:ok, _b2} =
      WebPropertyBinding
      |> Ash.Changeset.for_create(:create, %{
        web_property_id: wp.id,
        binding_kind: :origin_device,
        source: :manual,
        device_uid: device_uid
      })
      |> Ash.create(actor: actor)

    {:ok, _b3} =
      WebPropertyBinding
      |> Ash.Changeset.for_create(:create, %{
        web_property_id: wp.id,
        binding_kind: :otel_service,
        source: :trace_correlation,
        otel_service_name: "bound-frontend"
      })
      |> Ash.create(actor: actor)

    {:ok, bindings} = WebPropertyBinding.list_by_web_property(wp.id, actor: actor)
    assert length(bindings) == 3

    {:ok, check} =
      ServiceCheck
      |> Ash.Changeset.for_create(:create, %{
        name: "Bound HTTP Check",
        check_type: :http,
        target: wp.canonical_origin,
        device_uid: nil,
        web_property_id: wp.id
      })
      |> Ash.create(actor: actor)

    assert is_nil(check.device_uid)
    assert check.web_property_id == wp.id

    {:ok, [^check]} =
      ServiceCheck
      |> Ash.Query.for_read(:by_web_property, %{web_property_id: wp.id})
      |> Ash.read(actor: actor)

    assert :ok = Ash.destroy(wp, actor: actor)

    {:ok, reloaded_check} = ServiceCheck.get_by_id(check.id, actor: actor)
    assert is_nil(reloaded_check.web_property_id)
  end

  test "WebPropertyDiscoveryWorker reconciles K8s endpoints, never touches ocsf_devices, and honors single-VIP direct matching",
       %{actor: actor} do
    unique = System.unique_integer([:positive])
    shared_vip = "203.0.113.100"
    direct_vip = "198.51.100.77"
    ambiguous_vip = "198.51.100.88"

    direct_uid = "sr:" <> Ecto.UUID.generate()
    ambig_uid_1 = "sr:" <> Ecto.UUID.generate()
    ambig_uid_2 = "sr:" <> Ecto.UUID.generate()

    for {uid, ip} <- [
          {direct_uid, direct_vip},
          {ambig_uid_1, ambiguous_vip},
          {ambig_uid_2, ambiguous_vip}
        ] do
      {:ok, _} =
        Device
        |> Ash.Changeset.for_create(:create, %{uid: uid, ip: ip, hostname: "host-#{uid}"})
        |> Ash.create(actor: actor)
    end

    devices_count_before =
      Repo.aggregate(from(d in {"ocsf_devices", :platform}, prefix: "platform"), :count)

    now = DateTime.utc_now()

    endpoints = [
      %{
        endpoint_key: "ep-shop-#{unique}",
        cluster_id: "demo",
        ip: shared_vip,
        hostname: "shop-#{unique}.example.com",
        port: 443,
        protocol: "TCP",
        exposure_class: "Gateway",
        namespace: "web",
        service_name: "shop-svc",
        gateway_name: "public-gw",
        listener_name: "https",
        route_kind: "HTTPRoute",
        route_name: "shop-route",
        observed_at: now,
        snapshot_at: now
      },
      %{
        endpoint_key: "ep-portal-#{unique}",
        cluster_id: "demo",
        ip: shared_vip,
        hostname: "portal-#{unique}.example.com",
        port: 443,
        protocol: "TCP",
        exposure_class: "Gateway",
        namespace: "web",
        service_name: "portal-svc",
        gateway_name: "public-gw",
        listener_name: "https",
        route_kind: "HTTPRoute",
        route_name: "portal-route",
        observed_at: now,
        snapshot_at: now
      },
      %{
        endpoint_key: "ep-direct-#{unique}",
        cluster_id: "demo",
        ip: direct_vip,
        hostname: "direct-#{unique}.example.com",
        port: 443,
        protocol: "TCP",
        exposure_class: "LoadBalancer",
        namespace: "web",
        service_name: "direct-svc",
        gateway_name: "",
        listener_name: "https",
        route_kind: "Ingress",
        route_name: "direct-ing",
        observed_at: now,
        snapshot_at: now
      },
      %{
        endpoint_key: "ep-ambig-#{unique}",
        cluster_id: "demo",
        ip: ambiguous_vip,
        hostname: "ambig-#{unique}.example.com",
        port: 443,
        protocol: "TCP",
        exposure_class: "LoadBalancer",
        namespace: "web",
        service_name: "ambig-svc",
        gateway_name: "",
        listener_name: "https",
        route_kind: "Ingress",
        route_name: "ambig-ing",
        observed_at: now,
        snapshot_at: now
      }
    ]

    Repo.insert_all({"public_endpoints_current", :platform}, endpoints, prefix: "platform")

    assert {:ok, stats} =
             WebPropertyDiscoveryWorker.run_reconcile(
               network_probes: false,
               dns_probe: fn host ->
                 cond do
                   String.starts_with?(host, "direct-") -> {:ok, [direct_vip]}
                   String.starts_with?(host, "ambig-") -> {:ok, [ambiguous_vip]}
                   true -> {:ok, [shared_vip]}
                 end
               end,
               tls_probe: fn _host, _port ->
                 {:ok,
                  %{
                    tls_not_after: DateTime.shift(now, day: 90),
                    tls_issuer: "Let's Encrypt"
                  }}
               end
             )

    assert stats.properties_created >= 4

    devices_count_after =
      Repo.aggregate(from(d in {"ocsf_devices", :platform}, prefix: "platform"), :count)

    assert devices_count_after == devices_count_before

    {:ok, shop_wp} =
      WebProperty.get_by_canonical_origin("https://shop-#{unique}.example.com", actor: actor)

    {:ok, portal_wp} =
      WebProperty.get_by_canonical_origin("https://portal-#{unique}.example.com", actor: actor)

    assert shop_wp.id != portal_wp.id
    assert shop_wp.tls_issuer == "Let's Encrypt"

    {:ok, direct_wp} =
      WebProperty.get_by_canonical_origin("https://direct-#{unique}.example.com", actor: actor)

    assert direct_wp.edge_provider == "direct"
    {:ok, direct_bindings} = WebPropertyBinding.list_by_web_property(direct_wp.id, actor: actor)

    assert Enum.any?(direct_bindings, fn b ->
             b.binding_kind == :origin_device and b.source == :auto_vip_match and
               b.device_uid == direct_uid
           end)

    {:ok, ambig_wp} =
      WebProperty.get_by_canonical_origin("https://ambig-#{unique}.example.com", actor: actor)

    {:ok, ambig_bindings} = WebPropertyBinding.list_by_web_property(ambig_wp.id, actor: actor)
    refute Enum.any?(ambig_bindings, &(&1.binding_kind == :origin_device))

    # Soft-delete ep-shop and confirm stale :k8s_discovery binding is pruned
    Repo.update_all(
      from(pe in {"public_endpoints_current", :platform},
        prefix: "platform",
        where: pe.endpoint_key == ^"ep-shop-#{unique}"
      ),
      set: [deleted_at: now]
    )

    assert {:ok, prune_stats} = WebPropertyDiscoveryWorker.run_reconcile(network_probes: false)
    assert prune_stats.k8s_bindings_pruned >= 1

    {:ok, shop_bindings_after} = WebPropertyBinding.list_by_web_property(shop_wp.id, actor: actor)
    refute Enum.any?(shop_bindings_after, &(&1.source == :k8s_discovery))
  end
end
