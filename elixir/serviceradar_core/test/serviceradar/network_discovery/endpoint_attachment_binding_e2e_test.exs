defmodule ServiceRadar.NetworkDiscovery.EndpointAttachmentBindingE2ETest do
  @moduledoc """
  Integration coverage (database + Apache AGE required) for identifier-aware
  topology neighbor binding (fix-cross-subnet-topology-attachment [F2] and
  task 3.3):

    * [F2] a sighting whose chassis MAC is a registered SECONDARY identifier
      of an existing canonical device binds the evidence row to that device
      via `platform.device_identifiers` instead of staying unresolved or
      minting a provisional duplicate;
    * task 3.3: an endpoint sighting whose resolved IP is held by a live
      device only through a `DeviceAliasState` :ip alias (no MAC identity, no
      `ip` column match — a column match would already bind in resolution
      pass 1 and never reach promotion) binds to that device — and registers
      the MAC through DIRE — instead of minting a deterministic MAC-seeded
      provisional device;
    * task 3.3 guard: the same alias-held IP on a device that already
      carries a DIFFERENT registered MAC is never bound (distinct MAC =
      different hardware); the deterministic MAC-seeded provisional is
      minted instead.
  """

  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  @switch_a_uid "sr:e2e-bind-switch-a"
  @switch_b_uid "sr:e2e-bind-switch-b"
  @switch_c_uid "sr:e2e-bind-switch-c"
  @switch_d_uid "sr:e2e-bind-switch-d"
  @owner_uid "sr:e2e-bind-owner"
  @ip_only_uid "sr:e2e-bind-ip-only"
  @conflict_uid "sr:e2e-bind-mac-conflict"
  @chr_uid "sr:e2e-bind-chr"

  # Universal (IEEE global) MACs so DIRE registers them at strong confidence.
  @secondary_mac "a8:20:66:0d:e2:11"
  @ip_bind_mac "a8:20:66:0d:e2:22"
  @conflict_sighting_mac "a8:20:66:0d:e2:33"
  @vjuniper_mac "bc:24:11:26:40:e7"

  @owner_primary_mac "a8:20:66:0d:aa:01"
  @conflict_owner_mac "a8:20:66:0d:aa:02"
  @owner_ip "198.51.100.221"
  # The alias-bind device's own column IP; the candidate IP below is held
  # only via a DeviceAliasState :ip alias.
  @ip_only_primary_ip "198.51.100.223"
  @ip_only_ip "198.51.100.222"
  @conflict_primary_ip "198.51.100.224"
  @conflict_ip "198.51.100.225"
  @chr_primary_ip "198.51.100.226"
  @chr_alias_ip "198.51.100.227"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    if age_available?() do
      graph_name = graph_name()

      case ensure_graph(graph_name) do
        :ok ->
          :ok

        {:error, reason} ->
          {:ok, skip: "Apache AGE graph #{graph_name} not available: #{inspect(reason)}"}
      end
    else
      {:ok, skip: "Apache AGE is not available (ag_catalog.cypher missing)"}
    end
  end

  setup do
    original =
      Application.get_env(:serviceradar_core, :topology_endpoint_identity_promotion_enabled)

    Application.put_env(:serviceradar_core, :topology_endpoint_identity_promotion_enabled, true)

    on_exit(fn ->
      case original do
        nil ->
          Application.delete_env(
            :serviceradar_core,
            :topology_endpoint_identity_promotion_enabled
          )

        value ->
          Application.put_env(
            :serviceradar_core,
            :topology_endpoint_identity_promotion_enabled,
            value
          )
      end
    end)

    purge_rows()

    cleanup_graph([
      @switch_a_uid,
      @switch_b_uid,
      @switch_c_uid,
      @switch_d_uid,
      @owner_uid,
      @ip_only_uid,
      @conflict_uid,
      @chr_uid,
      deterministic_uid(@secondary_mac),
      deterministic_uid(@ip_bind_mac),
      deterministic_uid(@conflict_sighting_mac),
      deterministic_uid(@vjuniper_mac),
      "#{@switch_a_uid}/ifindex:4",
      "#{@switch_b_uid}/ifindex:4",
      "#{@switch_c_uid}/ifindex:4",
      "#{@owner_uid}/#{@secondary_mac}",
      "#{@owner_uid}/unknown-neighbor",
      "#{@ip_only_uid}/#{@ip_bind_mac}",
      "#{@ip_only_uid}/#{@ip_only_ip}",
      "#{@ip_only_uid}/unknown-neighbor",
      "#{@conflict_uid}/#{@conflict_ip}",
      "#{@conflict_uid}/unknown-neighbor",
      "#{@switch_d_uid}/ifindex:4",
      "#{@chr_uid}/#{@chr_alias_ip}",
      "#{@chr_uid}/#{@vjuniper_mac}",
      "#{@chr_uid}/unknown-neighbor"
    ])

    {:ok, actor: SystemActor.system(:mapper_topology_ingestor)}
  end

  test "sighting on a registered secondary MAC binds to the owning device", %{actor: actor} do
    create_device!(actor, %{uid: @owner_uid, ip: @owner_ip, mac: @owner_primary_mac})
    register_mac_identifier!(actor, @owner_uid, @secondary_mac)

    payload = fdb_payload(@switch_a_uid, @secondary_mac, nil)
    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!([payload]), %{})

    # Evidence row bound through platform.device_identifiers, not left
    # unresolved or pointed at a fresh provisional device.
    assert [row] = topology_rows(@switch_a_uid)
    assert row["neighbor_device_id"] == @owner_uid

    # No deterministic MAC-seeded provisional was minted for the sighting.
    assert device_count(deterministic_uid(@secondary_mac)) == 0
  end

  test "endpoint sighting binds to a live device holding the IP via alias instead of minting",
       %{actor: actor} do
    # The candidate IP must NOT be in the device's `ip` column: a column hit
    # binds in resolution pass 1 (ip_to_uid index) and the record never
    # becomes an endpoint-promotion candidate. Holding the IP through a
    # DeviceAliasState :ip alias exercises the promotion-time
    # `find_device_uid_by_alias` bind path.
    create_device!(actor, %{uid: @ip_only_uid, ip: @ip_only_primary_ip})
    create_ip_alias!(actor, @ip_only_uid, @ip_only_ip)

    payload = fdb_payload(@switch_b_uid, @ip_bind_mac, @ip_only_ip)
    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!([payload]), %{})

    # The aliased device was reused; no MAC-seeded provisional duplicate.
    assert device_count(deterministic_uid(@ip_bind_mac)) == 0

    # The MAC identifier now points at the existing device so future
    # sightings resolve via DIRE.
    normalized_mac = IdentityReconciler.normalize_mac(@ip_bind_mac)

    %Postgrex.Result{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT device_id FROM device_identifiers WHERE identifier_type = 'mac' AND identifier_value = $1",
        [normalized_mac]
      )

    assert [[@ip_only_uid]] = rows

    # Evidence row binds to the same uid the promotion chose.
    assert [row] = topology_rows(@switch_b_uid)
    assert row["neighbor_device_id"] == @ip_only_uid
  end

  test "alias bind is refused when the device carries a different registered MAC", %{
    actor: actor
  } do
    # Same alias-held-IP setup as above, but the device already has a
    # DIFFERENT registered MAC identity: distinct MAC = different hardware,
    # so shared-IP evidence (DHCP churn, NAT/VIP reuse) must never merge
    # them. The guard falls through to the deterministic MAC-seeded mint.
    create_device!(actor, %{uid: @conflict_uid, ip: @conflict_primary_ip})
    register_mac_identifier!(actor, @conflict_uid, @conflict_owner_mac)
    create_ip_alias!(actor, @conflict_uid, @conflict_ip)

    payload = fdb_payload(@switch_c_uid, @conflict_sighting_mac, @conflict_ip)
    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!([payload]), %{})

    provisional_uid = deterministic_uid(@conflict_sighting_mac)

    # The guard refused the bind: a deterministic MAC-seeded provisional
    # device was minted for the sighting.
    assert device_count(provisional_uid) == 1

    # The sighting MAC was registered on the provisional device only — never
    # on the distinct-MAC aliased device.
    normalized_mac = IdentityReconciler.normalize_mac(@conflict_sighting_mac)

    %Postgrex.Result{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT device_id FROM device_identifiers WHERE identifier_type = 'mac' AND identifier_value = $1",
        [normalized_mac]
      )

    assert [[^provisional_uid]] = rows

    # Evidence row binds to the provisional, not the aliased device.
    assert [row] = topology_rows(@switch_c_uid)
    assert row["neighbor_device_id"] == provisional_uid
  end

  test "cross-subnet FDB does not register a foreign chassis MAC onto an IP-only device", %{
    actor: actor
  } do
    # Reproduction: farm Catalyst ARP still had the dead CHR IP, while FDB
    # on the same port learned the vJunos chassis MAC. Binding that MAC onto
    # the CHR uid is how two pieces of hardware collapsed into one device.
    create_device!(actor, %{uid: @chr_uid, ip: @chr_primary_ip})
    create_ip_alias!(actor, @chr_uid, @chr_alias_ip)

    payload =
      fdb_payload(@switch_d_uid, @vjuniper_mac, @chr_alias_ip,
        confidence_reason: "cross_subnet_arp_fdb_port_mapping"
      )

    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!([payload]), %{})

    provisional_uid = deterministic_uid(@vjuniper_mac)
    assert device_count(provisional_uid) == 1

    normalized_mac = IdentityReconciler.normalize_mac(@vjuniper_mac)

    %Postgrex.Result{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT device_id FROM device_identifiers WHERE identifier_type = 'mac' AND identifier_value = $1",
        [normalized_mac]
      )

    assert [[^provisional_uid]] = rows
    refute Enum.any?(rows, fn [device_id] -> device_id == @chr_uid end)

    assert [row] = topology_rows(@switch_d_uid)
    assert row["neighbor_device_id"] == provisional_uid
  end

  defp fdb_payload(switch_uid, neighbor_mac, neighbor_ip, opts \\ []) do
    confidence_reason = Keyword.get(opts, :confidence_reason, "arp_fdb_port_mapping")

    base = %{
      "timestamp" => DateTime.truncate(DateTime.utc_now(), :microsecond),
      "protocol" => "SNMP-L2",
      "agent_id" => "agent-e2e-bind",
      "gateway_id" => "agent-e2e-bind",
      "partition" => "default",
      "local_device_id" => switch_uid,
      "local_device_ip" => "198.51.100.220",
      "local_if_index" => 4,
      "neighbor_chassis_id" => neighbor_mac,
      "metadata" => %{
        "protocol" => "SNMP-L2",
        "source" => "snmp-arp-fdb",
        "evidence" => "ipNetToMedia+dot1dTpFdb",
        "fdb_port_mapped" => "true",
        "evidence_class" => "inferred-segment",
        "relation_family" => "ATTACHED_TO",
        "confidence_tier" => "medium",
        "confidence_reason" => confidence_reason
      }
    }

    case neighbor_ip do
      nil -> base
      ip -> Map.put(base, "neighbor_mgmt_addr", ip)
    end
  end

  defp create_device!(actor, attrs) do
    {:ok, device} =
      Device
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create(actor: actor)

    device
  end

  defp create_ip_alias!(actor, device_uid, ip) do
    {:ok, _alias_state} =
      DeviceAliasState.create_detected(
        %{
          device_id: device_uid,
          partition: "default",
          alias_type: :ip,
          alias_value: ip,
          metadata: %{"source" => "test"}
        },
        actor: actor
      )

    :ok
  end

  defp register_mac_identifier!(actor, device_uid, mac) do
    normalized = IdentityReconciler.normalize_mac(mac)

    ids =
      IdentityReconciler.extract_strong_identifiers(%{
        device_id: nil,
        ip: nil,
        mac: normalized,
        mac_addresses: [normalized],
        partition: "default",
        metadata: %{}
      })

    :ok = IdentityReconciler.register_identifiers(device_uid, ids, actor: actor)
  end

  defp deterministic_uid(mac) do
    IdentityReconciler.generate_deterministic_device_id(%{
      mac: IdentityReconciler.normalize_mac(mac),
      partition: "default"
    })
  end

  defp device_count(uid) do
    %Postgrex.Result{rows: [[count]]} =
      SQL.query!(
        Repo,
        "SELECT COUNT(*) FROM ocsf_devices WHERE uid = $1 AND deleted_at IS NULL",
        [uid]
      )

    count
  end

  defp purge_rows do
    macs =
      Enum.map(
        [@secondary_mac, @ip_bind_mac, @conflict_sighting_mac, @conflict_owner_mac],
        &IdentityReconciler.normalize_mac/1
      )

    SQL.query!(
      Repo,
      "DELETE FROM device_identifiers WHERE identifier_type = 'mac' AND identifier_value = ANY($1)",
      [macs]
    )

    SQL.query!(
      Repo,
      "DELETE FROM device_alias_states WHERE alias_type = 'ip' AND alias_value = ANY($1)",
      [[@ip_only_ip, @conflict_ip]]
    )

    SQL.query!(
      Repo,
      "DELETE FROM platform.mapper_topology_links WHERE local_device_id = ANY($1)",
      [[@switch_a_uid, @switch_b_uid, @switch_c_uid]]
    )

    SQL.query!(
      Repo,
      "DELETE FROM ocsf_devices WHERE uid = ANY($1) OR ip = ANY($2)",
      [
        [
          @owner_uid,
          @ip_only_uid,
          @conflict_uid,
          deterministic_uid(@secondary_mac),
          deterministic_uid(@ip_bind_mac),
          deterministic_uid(@conflict_sighting_mac)
        ],
        [@owner_ip, @ip_only_primary_ip, @ip_only_ip, @conflict_primary_ip, @conflict_ip]
      ]
    )

    :ok
  end

  defp topology_rows(local_device_id) do
    %Postgrex.Result{rows: rows, columns: columns} =
      SQL.query!(
        Repo,
        """
        SELECT protocol, local_device_id, local_if_index, neighbor_device_id,
               neighbor_chassis_id, neighbor_port_id, neighbor_system_name
        FROM platform.mapper_topology_links
        WHERE local_device_id = $1
        """,
        [local_device_id]
      )

    Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
  end

  defp age_available? do
    with {:ok, %Postgrex.Result{rows: [[_]]}} <-
           SQL.query(Repo, "SELECT 1 FROM pg_namespace WHERE nspname = 'ag_catalog'", []),
         {:ok, %Postgrex.Result{rows: [[_]]}} <-
           SQL.query(
             Repo,
             """
             SELECT 1
             FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'ag_catalog' AND p.proname = 'cypher'
             LIMIT 1
             """,
             []
           ) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp ensure_graph(graph_name) do
    case SQL.query(Repo, "SELECT 1 FROM ag_catalog.ag_graph WHERE name = $1 LIMIT 1", [graph_name]) do
      {:ok, %Postgrex.Result{num_rows: 1}} ->
        :ok

      {:ok, _} ->
        case SQL.query(Repo, "SELECT ag_catalog.create_graph($1)", [graph_name]) do
          {:ok, _} -> :ok
          {:error, err} -> {:error, err}
        end

      {:error, err} ->
        {:error, err}
    end
  rescue
    err -> {:error, err}
  end

  defp cleanup_graph(ids) when is_list(ids) do
    quoted_ids = Enum.map_join(ids, ", ", &("'" <> &1 <> "'"))
    graph = String.replace(graph_name(), "'", "\\'")

    cypher = "MATCH (n) WHERE n.id IN [#{quoted_ids}] DETACH DELETE n"

    _ =
      SQL.query(
        Repo,
        "SELECT ag_catalog.agtype_to_text(v) FROM ag_catalog.cypher('#{graph}', $$#{cypher}$$) AS (v agtype)",
        []
      )

    :ok
  end

  defp graph_name do
    Application.get_env(:serviceradar_core, :age_graph_name, "platform_graph")
  end
end
