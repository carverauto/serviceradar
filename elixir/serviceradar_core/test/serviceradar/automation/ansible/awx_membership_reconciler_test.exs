defmodule ServiceRadar.Automation.Ansible.AwxMembershipReconcilerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AwxMembershipReconciler

  @controller_id "01980d8e-b6f8-7c16-a998-8ad49c96f36a"
  @fingerprint "sha256:1111111111111111111111111111111111111111111111111111111111111111"

  test "parses exact source tuples while preserving duplicate display names" do
    payload =
      payload([
        host(100, 7, "shared-node", "ansible_host: 192.0.2.10"),
        host(200, 8, "shared-node", ~s({"ansible_host":"node.tonka.invalid"}))
      ])

    assert {:ok, [aggregate]} = AwxMembershipReconciler.parse(payload)
    assert aggregate.controller_id == @controller_id
    assert aggregate.source_generation == 10
    assert aggregate.source_fingerprint == @fingerprint
    assert aggregate.complete

    assert [farm, tonka] = aggregate.hosts

    assert {farm.inventory_id, farm.awx_host_id, farm.host_name, farm.ansible_host} ==
             {7, 100, "shared-node", "192.0.2.10"}

    assert {tonka.inventory_id, tonka.awx_host_id, tonka.host_name, tonka.ansible_host} ==
             {8, 200, "shared-node", "node.tonka.invalid"}
  end

  test "legacy AWX discovery stays valid for devices but cannot mint memberships" do
    legacy =
      [host(100, 7, "node-1")]
      |> payload()
      |> update_in(["device_discovery", Access.at(0), "metadata"], fn metadata ->
        Map.drop(metadata, ["source_generation", "source_fingerprint", "complete"])
      end)

    assert {:ok, []} = AwxMembershipReconciler.parse(legacy)
  end

  test "rejects non-exact IDs, controller disagreement, and duplicate source tuples" do
    float_id =
      [host(100, 7, "node-1")]
      |> payload()
      |> put_in(
        ["device_discovery", Access.at(0), "devices", Access.at(0), "metadata", "awx", "host_id"],
        100.0
      )

    assert {:error, {:invalid_awx_membership_aggregate, :invalid_positive_integer}} =
             AwxMembershipReconciler.parse(float_id)

    controller_mismatch =
      [host(100, 7, "node-1")]
      |> payload()
      |> put_in(
        [
          "device_discovery",
          Access.at(0),
          "devices",
          Access.at(0),
          "metadata",
          "awx",
          "controller_id"
        ],
        "01980d8e-b6f8-7c16-a998-8ad49c96f36b"
      )

    assert {:error,
            {:invalid_awx_membership_aggregate,
             {:controller_mismatch, "01980d8e-b6f8-7c16-a998-8ad49c96f36b", @controller_id}}} =
             AwxMembershipReconciler.parse(controller_mismatch)

    duplicate = payload([host(100, 7, "one"), host(100, 7, "two")])

    assert {:error, {:invalid_awx_membership_aggregate, :duplicate_awx_host_source_tuple}} =
             AwxMembershipReconciler.parse(duplicate)
  end

  test "rejects malformed device entries instead of treating a complete aggregate as empty" do
    malformed =
      [host(100, 7, "node-1")]
      |> payload()
      |> update_in(["device_discovery", Access.at(0), "devices"], fn devices ->
        devices ++ ["malformed-host-row"]
      end)

    assert {:error, {:invalid_awx_membership_aggregate, :invalid_devices}} =
             AwxMembershipReconciler.parse(malformed)
  end

  test "device links require exact stored AWX tuple evidence, never matching name or IP" do
    devices = [
      %{
        uid: "name-and-ip-only",
        hostname: "shared-node",
        ip: "192.0.2.10",
        metadata: %{}
      },
      %{
        uid: "exact-device",
        hostname: "different-display-name",
        ip: "198.51.100.25",
        metadata: %{
          "awx" => %{
            "controller_id" => @controller_id,
            "inventory_id" => 7,
            "host_id" => 100
          }
        }
      }
    ]

    assert %{{@controller_id, 7, 100} => ["exact-device"]} =
             AwxMembershipReconciler.device_evidence_index(devices)
  end

  test "rejects a stale aggregate before writing any membership" do
    parent = self()

    existing = [membership(100, 7, 11, @fingerprint)]

    assert {:error, {:stale_awx_membership_generation, @controller_id, 10, 11}} =
             AwxMembershipReconciler.reconcile(payload([host(100, 7, "node-1")]),
               actor: :system,
               transaction: & &1.(),
               load_existing: fn @controller_id, :system -> {:ok, existing} end,
               resolve_links: fn _aggregate, _actor ->
                 send(parent, :unexpected_link_resolution)
                 {:ok, %{}}
               end,
               upsert: fn _attrs, _actor ->
                 send(parent, :unexpected_upsert)
                 :ok
               end,
               expire: fn _membership, _attrs, _actor ->
                 send(parent, :unexpected_expire)
                 :ok
               end
             )

    refute_received :unexpected_link_resolution
    refute_received :unexpected_upsert
    refute_received :unexpected_expire
  end

  test "complete aggregates upsert seen tuples and expire absent current memberships" do
    parent = self()

    existing = [
      membership(100, 7, 9, old_fingerprint()),
      membership(200, 8, 9, old_fingerprint())
    ]

    assert :ok =
             reconcile_with_spies(payload([host(100, 7, "node-1")]), existing, parent,
               evidence: %{{@controller_id, 7, 100} => ["device-100"]}
             )

    assert_receive {:upsert, attrs}
    assert attrs.inventory_id == 7
    assert attrs.awx_host_id == 100
    assert attrs.canonical_device_uid == "device-100"
    assert attrs.link_disposition == :proposed
    assert attrs.link_evidence["kind"] == "stored_awx_source_tuple"

    assert_receive {:expire, expired, attrs}
    assert expired.awx_host_id == 200
    assert attrs.source_generation == 10
    assert DateTime.compare(attrs.expired_at, ~U[2026-07-12 20:00:00.000000Z]) == :eq
  end

  test "partial aggregates never expire an absent membership" do
    parent = self()
    existing = [membership(200, 8, 9, old_fingerprint())]

    partial =
      [host(100, 7, "node-1")]
      |> payload()
      |> put_in(["device_discovery", Access.at(0), "metadata", "complete"], false)

    assert :ok = reconcile_with_spies(partial, existing, parent, evidence: %{})
    assert_receive {:upsert, _attrs}
    refute_received {:expire, _, _}
  end

  test "same-generation replay cannot reactivate an expired membership" do
    parent = self()

    expired =
      100
      |> membership(7, 10, @fingerprint)
      |> Map.merge(%{
        current: false,
        expired_at: ~U[2026-07-12 19:59:00Z],
        host_name: "node-1",
        ansible_host: nil,
        enabled: true
      })

    assert {:error, {:conflicting_same_generation_awx_membership_state, {@controller_id, 7, 100}}} =
             reconcile_with_spies(payload([host(100, 7, "node-1")]), [expired], parent,
               evidence: %{{@controller_id, 7, 100} => ["device-100"]}
             )

    refute_received {:upsert, _attrs}
    refute_received {:expire, _, _}
  end

  test "approved links survive only while current exact tuple evidence still agrees" do
    parent = self()

    approved =
      100
      |> membership(7, 9, old_fingerprint())
      |> Map.merge(%{
        canonical_device_uid: "device-100",
        link_disposition: :approved,
        current: true
      })

    assert :ok =
             reconcile_with_spies(payload([host(100, 7, "node-1")]), [approved], parent,
               evidence: %{{@controller_id, 7, 100} => ["device-100"]}
             )

    assert_receive {:upsert, %{link_disposition: :approved}}

    assert :ok =
             reconcile_with_spies(payload([host(100, 7, "node-1")]), [approved], parent,
               evidence: %{{@controller_id, 7, 100} => ["different-device"]}
             )

    assert_receive {:upsert,
                    %{
                      link_disposition: :quarantined,
                      canonical_device_uid: nil
                    }}
  end

  test "dispatches collected write notifications once after the transaction commits" do
    parent = self()
    existing = [membership(200, 8, 9, old_fingerprint())]

    assert :ok =
             AwxMembershipReconciler.reconcile(payload([host(100, 7, "node-1")]),
               actor: :system,
               transaction: fn fun ->
                 case fun.() do
                   {:ok, notifications} = result ->
                     send(
                       parent,
                       {:notification_lifecycle, :transaction_committed, notifications}
                     )

                     result

                   other ->
                     other
                 end
               end,
               load_existing: fn @controller_id, :system -> {:ok, existing} end,
               resolve_links: fn _aggregate, :system -> {:ok, %{}} end,
               upsert: fn attrs, :system ->
                 {:ok, attrs, [{:upserted, attrs.awx_host_id}]}
               end,
               expire: fn membership, _attrs, :system ->
                 {:ok, membership, [{:expired, membership.awx_host_id}]}
               end,
               notify: fn notifications ->
                 send(parent, {:notification_lifecycle, :notifications_dispatched, notifications})
                 []
               end
             )

    expected = [{:upserted, 100}, {:expired, 200}]
    assert_receive {:notification_lifecycle, first_event, ^expected}
    assert first_event == :transaction_committed
    assert_receive {:notification_lifecycle, second_event, ^expected}
    assert second_event == :notifications_dispatched
    refute_receive {:notification_lifecycle, :notifications_dispatched, _notifications}
  end

  test "discards collected notifications when a later write aborts the transaction" do
    parent = self()

    assert {:error, {:awx_membership_upsert_failed, {@controller_id, 7, 101}, :write_failed}} =
             AwxMembershipReconciler.reconcile(
               payload([host(100, 7, "node-1"), host(101, 7, "node-2")]),
               actor: :system,
               transaction: & &1.(),
               load_existing: fn @controller_id, :system -> {:ok, []} end,
               resolve_links: fn _aggregate, :system -> {:ok, %{}} end,
               upsert: fn
                 %{awx_host_id: 100} = attrs, :system ->
                   {:ok, attrs, [{:upserted, 100}]}

                 %{awx_host_id: 101}, :system ->
                   {:error, :write_failed}
               end,
               expire: fn _membership, _attrs, :system -> :ok end,
               notify: fn notifications ->
                 send(parent, {:notifications_dispatched, notifications})
                 []
               end
             )

    refute_receive {:notifications_dispatched, _notifications}
  end

  test "reports notifications that remain unsent after post-commit dispatch" do
    assert {:error, {:awx_membership_notifications_not_dispatched, 1}} =
             AwxMembershipReconciler.reconcile(payload([host(100, 7, "node-1")]),
               actor: :system,
               transaction: & &1.(),
               load_existing: fn @controller_id, :system -> {:ok, []} end,
               resolve_links: fn _aggregate, :system -> {:ok, %{}} end,
               upsert: fn attrs, :system ->
                 {:ok, attrs, [{:upserted, attrs.awx_host_id}]}
               end,
               expire: fn _membership, _attrs, :system -> :ok end,
               notify: & &1
             )
  end

  defp reconcile_with_spies(payload, existing, parent, opts) do
    evidence = Keyword.fetch!(opts, :evidence)

    AwxMembershipReconciler.reconcile(payload,
      actor: :system,
      transaction: & &1.(),
      load_existing: fn @controller_id, :system -> {:ok, existing} end,
      resolve_links: fn _aggregate, :system -> {:ok, evidence} end,
      upsert: fn attrs, :system ->
        send(parent, {:upsert, attrs})
        {:ok, attrs}
      end,
      expire: fn membership, attrs, :system ->
        send(parent, {:expire, membership, attrs})
        {:ok, membership}
      end
    )
  end

  defp payload(hosts) do
    %{
      "device_discovery" => [
        %{
          "schema" => "serviceradar.device_discovery.v1",
          "source" => "awx",
          "observed_at" => "2026-07-12T20:00:00Z",
          "collection_id" => "awx-collection-10",
          "metadata" => %{
            "controller_id" => @controller_id,
            "source_generation" => 10,
            "source_fingerprint" => @fingerprint,
            "complete" => true
          },
          "devices" => hosts
        }
      ]
    }
  end

  defp host(host_id, inventory_id, host_name, variables \\ "") do
    %{
      "hostname" => host_name,
      "ip" => "192.0.2.10",
      "is_available" => true,
      "metadata" => %{
        "awx" => %{
          "controller_id" => @controller_id,
          "inventory_id" => inventory_id,
          "inventory_name" => "Inventory #{inventory_id}",
          "host_id" => host_id,
          "host_name" => host_name,
          "variables" => variables
        }
      }
    }
  end

  defp membership(host_id, inventory_id, generation, fingerprint) do
    %{
      controller_id: @controller_id,
      inventory_id: inventory_id,
      awx_host_id: host_id,
      source_generation: generation,
      source_fingerprint: fingerprint,
      canonical_device_uid: nil,
      link_disposition: :unlinked,
      current: true,
      expired_at: nil,
      host_name: "node-#{host_id}",
      ansible_host: nil,
      enabled: true,
      metadata: %{}
    }
  end

  defp old_fingerprint,
    do: "sha256:0000000000000000000000000000000000000000000000000000000000000000"
end
