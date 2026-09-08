defmodule ServiceRadar.Automation.Ansible.AwxInventoryObservationFenceDbTest do
  use ServiceRadar.DataCase, async: false

  alias Ash.Seed
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Automation.Ansible.AwxMembershipReconciler
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Inventory.DeviceDiscoveryIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @moduletag :integration
  @actor SystemActor.system(:awx_observation_fence_db_test)
  @fingerprint "sha256:1111111111111111111111111111111111111111111111111111111111111111"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "unchanged observations retain authority generation but reject intermediate older snapshots" do
    controller = fixture()
    assert :ok = reconcile(payload(controller, 10))
    first = membership(controller)
    assert :ok = reconcile(payload(controller, 20))
    refreshed = membership(controller)

    assert refreshed.source_generation == 10
    assert DateTime.after?(refreshed.last_seen_at, first.last_seen_at)
    assert ledger_generation(controller) == 20

    assert {:error, {:stale_awx_membership_generation, _, 15, 20}} =
             reconcile(payload(controller, 15))

    assert membership(controller).source_generation == 10
  end

  test "same-generation changed contents and completeness cannot rewrite authority" do
    controller = fixture()
    original = payload(controller, 10)
    assert :ok = reconcile(original)
    assert :ok = reconcile(original)

    for changed <- [
          payload(controller, 10, complete: false),
          payload(controller, 10, name: "host02.example.com")
        ] do
      assert {:error, {:conflicting_awx_inventory_observation, _, 10}} = reconcile(changed)
    end

    assert membership(controller).host_name == "host01.example.com"
  end

  test "complete empty and partial empty observations both advance the ordering fence" do
    controller = fixture()
    assert :ok = reconcile(payload(controller, 10, empty: true))
    assert ledger_generation(controller) == 10

    assert {:error, {:stale_awx_membership_generation, _, 9, 10}} =
             reconcile(payload(controller, 9))

    assert :ok = reconcile(payload(controller, 20))
    assert :ok = reconcile(payload(controller, 30, empty: true, complete: false))
    assert ledger_generation(controller) == 30
    assert membership(controller).current
    assert membership(controller).source_generation == 20

    assert {:error, {:stale_awx_membership_generation, _, 25, 30}} =
             reconcile(payload(controller, 25, empty: true))

    assert membership(controller).current
  end

  test "failed membership writes roll back earlier device writes and leave no watermark" do
    controller = fixture()
    parent = self()

    assert {:error, :synthetic_membership_failure} =
             DeviceDiscoveryIngestor.ingest(payload(controller, 10), %{},
               actor: @actor,
               device_sync: fn _updates, %{serialize_awx?: true} ->
                 assert Repo.in_transaction?()

                 Repo.query!(
                   "UPDATE platform.ansible_controllers SET name = $2 WHERE id = ($1::text)::uuid",
                   [controller.id, "Changed in failed transaction"]
                 )

                 {:ok, [%{synthetic_effect: true}]}
               end,
               membership_sync: fn _payload, %{return_notifications?: true} ->
                 {:error, :synthetic_membership_failure}
               end,
               emit_state_events: fn effects ->
                 send(parent, {:unexpected_effects, effects})
                 :ok
               end,
               notify: fn notifications ->
                 send(parent, {:unexpected_notifications, notifications})
                 []
               end
             )

    assert ledger_generation(controller) == nil

    assert %{rows: [[name]]} =
             Repo.query!(
               "SELECT name FROM platform.ansible_controllers WHERE id = ($1::text)::uuid",
               [controller.id]
             )

    assert name == controller.name
    assert membership(controller) == nil
    refute_received {:unexpected_effects, _}
    refute_received {:unexpected_notifications, _}
  end

  test "membership notifications are delivered after the outer ingestion transaction commits" do
    controller = fixture()
    parent = self()

    assert :ok =
             DeviceDiscoveryIngestor.ingest(payload(controller, 10), %{},
               actor: @actor,
               device_sync: fn _updates, %{serialize_awx?: true} ->
                 assert Repo.in_transaction?()
                 {:ok, [%{synthetic_effect: true}]}
               end,
               membership_sync: fn input, %{return_notifications?: true} ->
                 assert {:ok, notifications} =
                          AwxMembershipReconciler.reconcile(input,
                            actor: @actor,
                            return_notifications?: true
                          )

                 {:ok, [:synthetic_notification | notifications]}
               end,
               emit_state_events: fn effects ->
                 refute Repo.in_transaction?()
                 assert ledger_generation(controller) == 10
                 send(parent, {:effects_delivered, effects})
                 :ok
               end,
               notify: fn notifications ->
                 refute Repo.in_transaction?()
                 assert ledger_generation(controller) == 10
                 send(parent, {:delivered, notifications})
                 []
               end
             )

    assert_receive {:delivered, [:synthetic_notification | _]}
    assert_receive {:effects_delivered, [%{synthetic_effect: true}]}
    refute_receive {:delivered, _}
    refute_receive {:effects_delivered, _}
  end

  @tag sandbox: :unboxed
  test "concurrent older and same-generation conflicting snapshots never enter device writes" do
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    for second_generation <- [10, 20] do
      controller = fixture()

      first =
        Task.Supervisor.async_nolink(supervisor, fn ->
          DeviceDiscoveryIngestor.ingest(payload(controller, 20), %{},
            actor: @actor,
            device_sync: fn _, %{serialize_awx?: true} ->
              assert Repo.in_transaction?()
              send(parent, {:first_entered, self()})

              receive do
                :finish -> :ok
              after
                10_000 -> raise "test did not release the AWX ingestion transaction"
              end
            end
          )
        end)

      try do
        assert_receive {:first_entered, first_pid}, 5_000

        second =
          Task.Supervisor.async_nolink(supervisor, fn ->
            send(parent, :second_started)

            DeviceDiscoveryIngestor.ingest(
              payload(controller, second_generation, name: "host02.example.com"),
              %{},
              actor: @actor,
              device_sync: fn _, _ ->
                send(parent, :unexpected_stale_device_write)
                :ok
              end
            )
          end)

        try do
          assert_receive :second_started, 5_000
          refute_receive :unexpected_stale_device_write, 100
          send(first_pid, :finish)
          assert :ok = Task.await(first, 5_000)
          result = Task.await(second, 5_000)

          if second_generation == 10 do
            assert {:error, {:stale_awx_membership_generation, _, 10, 20}} = result
          else
            assert {:error, {:conflicting_awx_inventory_observation, _, 20}} = result
          end

          assert ledger_generation(controller) == 20
          assert membership(controller).host_name == "host01.example.com"
          refute_received :unexpected_stale_device_write
        after
          Task.shutdown(second, :brutal_kill)
        end
      after
        Task.shutdown(first, :brutal_kill)

        Repo.query!("DELETE FROM platform.ansible_controllers WHERE id = ($1::text)::uuid", [
          controller.id
        ])

        Repo.query!(
          "DELETE FROM platform.network_credential_secrets WHERE id = ($1::text)::uuid",
          [controller.credential_secret_id]
        )
      end
    end
  end

  defp fixture do
    id = Ash.UUID.generate()

    Seed.seed!(Controller, %{
      id: id,
      name: "Synthetic controller #{id}",
      base_url: "https://controller.example.com",
      agent_id: "synthetic-agent-#{id}",
      credential_secret_id: CredentialIntegrationFixtures.secret_id!()
    })
  end

  defp reconcile(input), do: AwxMembershipReconciler.reconcile(input, actor: @actor)

  defp membership(controller) do
    assert {:ok, result} =
             AwxHostMembership.get_by_source_identity(controller.id, 7, 10, actor: @actor)

    result
  end

  defp ledger_generation(controller) do
    case Repo.query!(
           "SELECT source_generation FROM platform.ansible_awx_inventory_observations WHERE controller_id = ($1::text)::uuid",
           [controller.id]
         ).rows do
      [] -> nil
      [[generation]] -> generation
    end
  end

  defp payload(controller, generation, opts \\ []) do
    hosts =
      if opts[:empty],
        do: [],
        else: [
          %{
            "hostname" => "host01.example.com",
            "ip" => "192.0.2.10",
            "is_available" => true,
            "metadata" => %{
              "awx" => %{
                "controller_id" => controller.id,
                "inventory_id" => 7,
                "host_id" => 10,
                "host_name" => Keyword.get(opts, :name, "host01.example.com"),
                "inventory_name" => "Example inventory",
                "variables" => "ansible_host: 192.0.2.10"
              }
            }
          }
        ]

    %{
      "device_discovery" => [
        %{
          "schema" => "serviceradar.device_discovery.v1",
          "source" => "awx",
          "observed_at" =>
            DateTime.to_iso8601(
              DateTime.add(~U[2031-01-02 03:04:05.000000Z], generation, :second)
            ),
          "collection_id" => "synthetic-observation-#{generation}",
          "metadata" => %{
            "controller_id" => controller.id,
            "source_generation" => generation,
            "source_fingerprint" => @fingerprint,
            "complete" => Keyword.get(opts, :complete, true)
          },
          "devices" => hosts
        }
      ]
    }
  end
end
