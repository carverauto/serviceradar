defmodule ServiceRadar.Automation.Ansible.ControllerReviewProvenanceTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.ControllerProvenance
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Plugins.SecretRefs

  defmodule CommandBus do
    @moduledoc false
    def dispatch(agent_id, type, payload, opts) do
      id = Ash.UUID.generate()

      Process.put(:review_command, %{
        id: id,
        agent_id: agent_id,
        partition_id: opts[:required_partition],
        command_type: type,
        payload: payload,
        context: opts[:context],
        status: :completed
      })

      {:ok, id}
    end
  end

  setup do
    sync = Ash.UUID.generate()

    controller = %Controller{
      id: Ash.UUID.generate(),
      name: "controller.example.com",
      base_url: "https://controller.example.com",
      agent_id: "synthetic-review-edge",
      enabled: true,
      credential_secret_id: sync,
      sync_credential_secret_id: sync,
      execution_credential_secret_id: Ash.UUID.generate(),
      metadata: %{}
    }

    {:ok, snapshot} = ControllerSecuritySnapshot.capture(controller)

    opts = [
      expected_controller_snapshot: snapshot,
      expected_partition_id: "synthetic-review-partition",
      awx_client_opts: [
        command_bus: CommandBus,
        grant_issuer: fn attrs ->
          grant =
            attrs |> CredentialBrokerGrant.issue_attrs() |> Map.put(:id, Ash.UUID.generate())

          {:ok, CredentialBrokerGrant.to_payload(grant)}
        end
      ],
      command_reader: fn _ ->
        {:ok, Map.put(Process.get(:review_command), :result_payload, Process.get(:review_result))}
      end
    ]

    %{controller: controller, opts: opts}
  end

  test "review pins the execution principal instead of the inventory sync principal", c do
    Process.put(:review_result, %{
      "verb" => "awx.current_user",
      "ok" => true,
      "user_id" => 31,
      "username" => "synthetic-runner"
    })

    assert {:ok, 31} = ControllerProvenance.current_user(c.controller, c.opts)
    command = Process.get(:review_command)

    assert command.payload["credential_broker"]["credential_secret_ref"] ==
             SecretRefs.network_credential_ref(c.controller.execution_credential_secret_id)

    refute command.payload["credential_broker"]["credential_secret_ref"] ==
             SecretRefs.network_credential_ref(c.controller.sync_credential_secret_id)
  end

  test "the persisted execution principal read rejects a substituted sync credential", c do
    opts =
      Keyword.put(c.opts, :command_reader, fn _ ->
        command = Process.get(:review_command)

        command =
          put_in(
            command.payload["credential_broker"]["credential_secret_ref"],
            SecretRefs.network_credential_ref(c.controller.sync_credential_secret_id)
          )

        {:ok,
         Map.put(command, :result_payload, %{
           "verb" => "awx.current_user",
           "ok" => true,
           "user_id" => 31
         })}
      end)

    assert {:error, :controller_provenance_command_mismatch} =
             ControllerProvenance.current_user(c.controller, opts)
  end

  test "inventory groups require a complete unique projection", c do
    result = %{
      "verb" => "awx.list_inventory_groups",
      "ok" => true,
      "extra" => %{"inventory_id" => 32},
      "count" => 1,
      "results" => [%{"name" => "synthetic-group"}]
    }

    Process.put(:review_result, result)

    assert {:ok, ["synthetic-group"]} =
             ControllerProvenance.list_inventory_groups(c.controller, 32, c.opts)

    for invalid <- [Map.put(result, "count", 2), Map.put(result, "results", [nil])] do
      Process.put(:review_result, invalid)

      assert {:error, :controller_inventory_groups_unavailable} =
               ControllerProvenance.list_inventory_groups(c.controller, 32, c.opts)
    end
  end
end
