defmodule ServiceRadar.Automation.Ansible.ProvisioningIdempotencyDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.ProvisioningIdempotency
  alias ServiceRadar.Automation.Ansible.ProvisioningRequest
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Repo
  alias ServiceRadar.Vault

  @moduletag :integration
  @actor SystemActor.system(:provisioning_idempotency_db_test)

  test "a replay reads the original resource and never calls create again" do
    identity = identity()
    target = target()
    params = %{"name" => target.name}

    assert {:ok, first} = run(identity, params, target)

    assert {:ok, replayed} =
             ProvisioningIdempotency.run(identity, params, &unexpected_create/0, &read_target/1)

    assert first == replayed
    assert receipt_count(identity) == 1
    assert target_count(target.id) == 1
  end

  test "the same scoped key with a different body conflicts without mutation" do
    identity = identity()
    target = target()
    assert {:ok, _} = run(identity, %{"name" => target.name}, target)

    assert {:error, :idempotency_conflict} =
             ProvisioningIdempotency.run(
               identity,
               %{"name" => "Different synthetic request"},
               &unexpected_create/0,
               fn _ -> flunk("conflicting body reached the resource reader") end
             )

    assert receipt_count(identity) == 1
    assert target_count(target.id) == 1
  end

  test "request keys are scoped by initiating principal, OAuth client, and operation" do
    original = identity()

    identities = [
      original,
      %{original | initiator_id: Ash.UUID.generate()},
      %{original | oauth_client_id: Ash.UUID.generate()},
      %{original | operation: "/api/admin/example-configurations"}
    ]

    resources =
      Enum.map(identities, fn identity ->
        target = target()
        assert {:ok, resource} = run(identity, %{"mode" => "example"}, target)
        assert receipt_count(identity) == 1
        resource.id
      end)

    assert length(Enum.uniq(resources)) == length(identities)
  end

  test "a failed callback rolls back its writes and leaves no receipt" do
    identity = identity()
    target = target()

    assert {:error, :synthetic_rejection} =
             ProvisioningIdempotency.run(
               identity,
               %{"name" => target.name},
               fn ->
                 assert {:ok, _} = insert_target(target)
                 {:error, :synthetic_rejection}
               end,
               &read_target/1
             )

    assert target_count(target.id) == 0
    assert receipt_count(identity) == 0
    assert {:ok, _} = run(identity, %{"name" => target.name}, target)
  end

  test "receipt persistence failure also rolls back the resource creation" do
    identity = %{identity() | initiator_id: "not-a-uuid"}
    target = target()

    assert {:error, _} = run(identity, %{"name" => target.name}, target)
    assert target_count(target.id) == 0
    assert receipt_count(identity) == 0
  end

  test "deleting a resource preserves its receipt and cannot resurrect it by replay" do
    identity = identity()
    target = target()
    params = %{"name" => target.name}
    assert {:ok, _} = run(identity, params, target)

    Repo.query!(
      "DELETE FROM platform.ansible_playbook_repositories WHERE id = ($1::text)::uuid",
      [
        target.id
      ]
    )

    assert {:error, :idempotency_resource_deleted} =
             ProvisioningIdempotency.run(identity, params, &unexpected_create/0, &read_target/1)

    assert target_count(target.id) == 0
    assert receipt_count(identity) == 1
  end

  test "durable receipts contain an encrypted random MAC key and no request body" do
    identity = identity()
    target = target()
    marker = "invented-secret-material-for-receipt-test"
    params = %{"name" => target.name, "values" => %{"token" => marker}}
    assert {:ok, _} = run(identity, params, target)

    receipt = Ash.get!(ProvisioningRequest, request_id(identity), actor: @actor)
    assert {:ok, key} = Vault.decrypt(receipt.key_ciphertext)
    assert byte_size(key) == 32
    refute key == receipt.key_ciphertext
    assert receipt.request_mac == :crypto.mac(:hmac, :sha256, key, CanonicalJSON.encode!(params))

    %{rows: [[encoded]]} =
      Repo.query!(
        "SELECT row_to_json(receipt)::text FROM platform.ansible_provisioning_requests receipt WHERE id = $1",
        [request_id(identity)]
      )

    refute encoded =~ marker
    refute encoded =~ target.name
    refute Map.has_key?(Map.from_struct(receipt), :request_body)

    other = %{identity | key: Ash.UUID.generate()}
    assert {:ok, _} = run(other, params, target())
    second = Ash.get!(ProvisioningRequest, request_id(other), actor: @actor)
    assert {:ok, other_key} = Vault.decrypt(second.key_ciphertext)
    refute key == other_key
    refute receipt.request_mac == second.request_mac
  end

  @tag sandbox: :unboxed
  test "concurrent identical requests create exactly one resource and one receipt" do
    identity = identity()
    target = target()
    params = %{"name" => target.name}
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    first =
      Task.Supervisor.async_nolink(supervisor, fn ->
        ProvisioningIdempotency.run(
          identity,
          params,
          fn ->
            send(parent, {:create_entered, self()})

            receive do
              :complete_create -> insert_target(target)
            after
              10_000 -> raise "test did not release the transaction"
            end
          end,
          &read_target/1
        )
      end)

    try do
      assert_receive {:create_entered, first_pid}, 5_000

      assert {:error, :idempotency_in_progress} =
               ProvisioningIdempotency.run(identity, params, &unexpected_create/0, &read_target/1)

      send(first_pid, :complete_create)
      assert {:ok, resource} = Task.await(first, 5_000)

      assert {:ok, ^resource} =
               ProvisioningIdempotency.run(identity, params, &unexpected_create/0, &read_target/1)

      assert target_count(target.id) == 1
      assert receipt_count(identity) == 1
    after
      Task.shutdown(first, :brutal_kill)

      Repo.query!("DELETE FROM platform.ansible_provisioning_requests WHERE id = $1", [
        request_id(identity)
      ])

      Repo.query!(
        "DELETE FROM platform.ansible_playbook_repositories WHERE id = ($1::text)::uuid",
        [
          target.id
        ]
      )
    end
  end

  defp identity do
    %{
      initiator_id: Ash.UUID.generate(),
      oauth_client_id: nil,
      operation: "/api/admin/ansible-repositories",
      key: Ash.UUID.generate()
    }
  end

  defp target do
    id = Ash.UUID.generate()
    %{id: id, name: "Example repository #{id}"}
  end

  defp run(identity, params, target) do
    ProvisioningIdempotency.run(identity, params, fn -> insert_target(target) end, &read_target/1)
  end

  defp insert_target(target) do
    Repo.query!(
      """
      INSERT INTO platform.ansible_playbook_repositories (id, name, git_url)
      VALUES (($1::text)::uuid, $2, $3)
      """,
      [target.id, target.name, "https://git.example.com/project/#{target.id}.git"]
    )

    read_target(target.id)
  end

  defp read_target(id) do
    case Repo.query!(
           "SELECT id::text, name FROM platform.ansible_playbook_repositories WHERE id = ($1::text)::uuid",
           [id]
         ) do
      %{rows: [[id, name]]} -> {:ok, %{id: id, name: name}}
      %{rows: []} -> {:error, :not_found}
    end
  end

  defp request_id(identity), do: identity |> CanonicalJSON.encode!() |> CanonicalJSON.sha256()

  defp receipt_count(identity) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM platform.ansible_provisioning_requests WHERE id = $1", [
        request_id(identity)
      ])

    count
  end

  defp target_count(id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.ansible_playbook_repositories WHERE id = ($1::text)::uuid",
        [id]
      )

    count
  end

  defp unexpected_create, do: flunk("replay attempted another mutation")
end
