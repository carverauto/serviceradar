defmodule ServiceRadar.Automation.Ansible.AwxMembershipReconcilerDbTest do
  use ServiceRadar.DataCase, async: false

  alias Ash.Seed
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Automation.Ansible.AwxMembershipReconciler
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @fingerprint_one "sha256:1111111111111111111111111111111111111111111111111111111111111111"
  @fingerprint_two "sha256:2222222222222222222222222222222222222222222222222222222222222222"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    previous_setting = Application.fetch_env(:ash, :missed_notifications)
    Application.put_env(:ash, :missed_notifications, :raise)

    on_exit(fn ->
      case previous_setting do
        {:ok, value} -> Application.put_env(:ash, :missed_notifications, value)
        :error -> Application.delete_env(:ash, :missed_notifications)
      end
    end)

    :ok
  end

  test "commits membership upserts and expirations without missing Ash notifications" do
    suffix = System.unique_integer([:positive])

    controller =
      Seed.seed!(Controller, %{
        name: "membership-notification-test-#{suffix}",
        base_url: "https://awx.test.invalid",
        agent_id: "membership-notification-agent-#{suffix}",
        credential_secret_id: CredentialIntegrationFixtures.secret_id!()
      })

    actor = SystemActor.system(:awx_membership_reconciler_test)

    assert :ok =
             AwxMembershipReconciler.reconcile(
               payload(controller.id, 1, @fingerprint_one, [
                 host(controller.id, 100, 7, "node-1")
               ]),
               actor: actor
             )

    assert {:ok, first} =
             AwxHostMembership.get_by_source_identity(controller.id, 7, 100, actor: actor)

    assert first.current
    assert first.source_generation == 1

    assert :ok =
             AwxMembershipReconciler.reconcile(
               payload(controller.id, 2, @fingerprint_two, [
                 host(controller.id, 200, 8, "node-2")
               ]),
               actor: actor
             )

    assert {:ok, expired} =
             AwxHostMembership.get_by_source_identity(controller.id, 7, 100, actor: actor)

    assert {:ok, current} =
             AwxHostMembership.get_by_source_identity(controller.id, 8, 200, actor: actor)

    refute expired.current
    assert expired.source_generation == 2
    assert current.current
    assert current.source_generation == 2
  end

  defp payload(controller_id, generation, fingerprint, hosts) do
    %{
      "device_discovery" => [
        %{
          "schema" => "serviceradar.device_discovery.v1",
          "source" => "awx",
          "observed_at" => "2026-08-10T00:00:00Z",
          "collection_id" => "membership-notification-#{generation}",
          "metadata" => %{
            "controller_id" => controller_id,
            "source_generation" => generation,
            "source_fingerprint" => fingerprint,
            "complete" => true
          },
          "devices" => hosts
        }
      ]
    }
  end

  defp host(controller_id, host_id, inventory_id, host_name) do
    %{
      "hostname" => host_name,
      "ip" => "192.0.2.#{rem(host_id, 200) + 1}",
      "is_available" => true,
      "metadata" => %{
        "awx" => %{
          "controller_id" => controller_id,
          "inventory_id" => inventory_id,
          "inventory_name" => "Inventory #{inventory_id}",
          "host_id" => host_id,
          "host_name" => host_name,
          "variables" => ""
        }
      }
    }
  end
end
