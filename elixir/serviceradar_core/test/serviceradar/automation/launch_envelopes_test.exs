defmodule ServiceRadar.Automation.LaunchEnvelopesTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.LaunchEnvelopes
  alias ServiceRadar.TestSupport.AutomationLaunchEnvelopeMemoryStore

  @key :binary.copy(<<91>>, 32)
  @bearer Base.url_encode64(:binary.copy(<<27>>, 32), padding: false)
  @idempotency_key "srci_v1_" <>
                     Base.url_encode64(:binary.copy(<<37>>, 32), padding: false)
  @issued_at ~U[2026-07-13 02:00:00.000000Z]

  test "creates grant and sealed envelope atomically without returning the bearer" do
    store = start_supervised!({Agent, fn -> memory_state() end})

    assert {:ok, prepared} = prepare(store)
    refute Map.has_key?(prepared, :bearer)
    assert prepared.grant == %{id: grant_id()}
    assert prepared.command_payload == %{"launch_envelope_ref" => prepared.envelope_ref}

    [record] = AutomationLaunchEnvelopeMemoryStore.records(store)
    refute Map.has_key?(record, :bearer)
    assert :binary.match(record.ciphertext, @bearer) == :nomatch
    assert :binary.match(record.ciphertext, @idempotency_key) == :nomatch
  end

  test "resolves once only for the exact agent and command" do
    store = start_supervised!({Agent, fn -> memory_state() end})
    assert {:ok, prepared} = prepare(store)

    wrong_agent = %{
      agent_id: "agent-other",
      partition_id: "farm01",
      command_id: prepared.command_id
    }

    assert {:error, :launch_envelope_denied} = resolve(prepared, wrong_agent, store)

    wrong_command = %{
      agent_id: "agent-farm01",
      partition_id: "farm01",
      command_id: Ecto.UUID.generate()
    }

    assert {:error, :launch_envelope_denied} = resolve(prepared, wrong_command, store)

    wrong_partition = %{
      agent_id: "agent-farm01",
      partition_id: "tonka01",
      command_id: prepared.command_id
    }

    assert {:error, :launch_envelope_denied} = resolve(prepared, wrong_partition, store)

    exact = %{
      agent_id: "agent-farm01",
      partition_id: "farm01",
      command_id: prepared.command_id
    }

    assert {:ok, material} = resolve(prepared, exact, store)
    assert material.bearer == @bearer
    assert material.idempotency_key == @idempotency_key
    assert material.callback_grant_id == grant_id()

    assert material.callback_url ==
             "https://demo.example.com/api/v1/automation/callback-grants/#{grant_id()}/actions/remote_access.ssh_ca.bundle.read"

    assert material.callback_allowed_origin == "https://demo.example.com"
    assert material.manifest_sha256 == String.duplicate("a", 64)
    assert material.scm_revision == String.duplicate("b", 40)
    assert material.content_sha256 == String.duplicate("c", 64)
    assert material.callback_phase == "stage"
    assert material.callback_operation == "enroll"
    assert material.callback_state == "present"
    assert material.callback_credential_type_id == 91
    assert material.callback_credential_organization_id == 2
    assert material.callback_credential_injector_sha256 == String.duplicate("d", 64)

    assert {:error, :launch_envelope_denied} = resolve(prepared, exact, store)
  end

  test "concurrent exact resolution releases the bearer once" do
    store = start_supervised!({Agent, fn -> memory_state() end})
    assert {:ok, prepared} = prepare(store)

    exact = %{
      agent_id: "agent-farm01",
      partition_id: "farm01",
      command_id: prepared.command_id
    }

    results =
      1..8
      |> Task.async_stream(fn _ -> resolve(prepared, exact, store) end,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %{bearer: @bearer}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :launch_envelope_denied}, &1)) == 7
  end

  test "corrupt ciphertext remains sealed until decryption succeeds" do
    store = start_supervised!({Agent, fn -> memory_state() end})
    assert {:ok, prepared} = prepare(store)

    [original] = AutomationLaunchEnvelopeMemoryStore.records(store)

    Agent.update(store, fn state ->
      {verifier, record} = Enum.at(state.records, 0)
      tampered = Map.update!(record, :ciphertext, &tamper/1)
      put_in(state, [:records, verifier], tampered)
    end)

    exact = %{
      agent_id: "agent-farm01",
      partition_id: "farm01",
      command_id: prepared.command_id
    }

    assert {:error, :launch_envelope_decrypt_failed} = resolve(prepared, exact, store)
    assert [%{state: :sealed}] = AutomationLaunchEnvelopeMemoryStore.records(store)

    Agent.update(store, fn state ->
      {verifier, record} = Enum.at(state.records, 0)
      put_in(state, [:records, verifier], %{record | ciphertext: original.ciphertext})
    end)

    assert {:ok, %{bearer: @bearer}} = resolve(prepared, exact, store)
    assert [%{state: :resolved}] = AutomationLaunchEnvelopeMemoryStore.records(store)
  end

  test "a wrong active key cannot consume an envelope before rotation settles" do
    store = start_supervised!({Agent, fn -> memory_state() end})
    assert {:ok, prepared} = prepare(store)

    exact = %{
      agent_id: "agent-farm01",
      partition_id: "farm01",
      command_id: prepared.command_id
    }

    assert {:error, :launch_envelope_denied} =
             LaunchEnvelopes.resolve(prepared.envelope_ref, exact,
               store: AutomationLaunchEnvelopeMemoryStore,
               store_context: store,
               encryption_key: :binary.copy(<<92>>, 32),
               now: DateTime.add(@issued_at, 30, :second)
             )

    assert [%{state: :sealed}] = AutomationLaunchEnvelopeMemoryStore.records(store)
    assert {:ok, %{bearer: @bearer}} = resolve(prepared, exact, store)
  end

  test "seal failure leaves no resolvable envelope" do
    store = start_supervised!({Agent, fn -> memory_state(fail_create?: true) end})

    assert {:error, :forced_seal_failure} = prepare(store)
    assert AutomationLaunchEnvelopeMemoryStore.records(store) == []
  end

  test "accepts only a verified preallocated command/reference pair" do
    store = start_supervised!({Agent, fn -> memory_state() end})

    assert {:ok, allocation} =
             LaunchEnvelopes.allocate(encryption_key: @key, now: @issued_at)

    issuer = fn envelope_ref, command_id ->
      send(self(), {:issued_for, envelope_ref, command_id})

      {:ok,
       %{
         grant: %{id: grant_id()},
         bearer: @bearer,
         idempotency_key: @idempotency_key
       }}
    end

    opts = [
      store: AutomationLaunchEnvelopeMemoryStore,
      store_context: store,
      encryption_key: @key,
      allocation: allocation
    ]

    assert {:ok, prepared} =
             LaunchEnvelopes.prepare_and_seal(context_attrs(), issuer, opts)

    assert prepared.command_id == allocation.command_id
    assert_receive {:issued_for, reference, command_id}
    assert reference == allocation.reference
    assert command_id == allocation.command_id

    tampered = Map.put(allocation, :reference_verifier, :binary.copy(<<0>>, 32))

    assert {:error, :invalid_launch_envelope_allocation} =
             LaunchEnvelopes.prepare_and_seal(
               context_attrs(),
               issuer,
               Keyword.put(opts, :allocation, tampered)
             )

    refute_receive {:issued_for, _, _}
  end

  defp prepare(store) do
    LaunchEnvelopes.prepare_and_seal(
      context_attrs(),
      fn envelope_ref, command_id ->
        send(self(), {:grant_issuer_received, envelope_ref, command_id})

        {:ok,
         %{
           grant: %{id: grant_id()},
           bearer: @bearer,
           idempotency_key: @idempotency_key
         }}
      end,
      store: AutomationLaunchEnvelopeMemoryStore,
      store_context: store,
      encryption_key: @key,
      now: @issued_at
    )
  end

  defp resolve(prepared, request, store) do
    LaunchEnvelopes.resolve(prepared.envelope_ref, request,
      store: AutomationLaunchEnvelopeMemoryStore,
      store_context: store,
      encryption_key: @key,
      now: DateTime.add(@issued_at, 30, :second)
    )
  end

  defp context_attrs do
    %{
      tenant_id: "tenant-a",
      child_execution_id: "01980a6d-4a62-7b3f-a249-5f825874ca52",
      controller_id: "01980a6d-4a62-7b3f-a249-5f825874ca54",
      inventory_id: 17,
      job_template_id: 23,
      dispatch_agent_id: "agent-farm01",
      dispatch_partition_id: "farm01",
      callback_allowed_origin: "https://demo.example.com",
      manifest_sha256: String.duplicate("a", 64),
      scm_revision: String.duplicate("b", 40),
      content_sha256: String.duplicate("c", 64),
      callback_phase: "stage",
      callback_operation: "enroll",
      callback_state: "present",
      callback_credential_type_id: 91,
      callback_credential_organization_id: 2,
      callback_credential_injector_sha256: String.duplicate("d", 64),
      expires_at: DateTime.add(@issued_at, 300, :second)
    }
  end

  defp grant_id, do: "01980a6d-4a62-7b3f-a249-5f825874ca53"

  defp memory_state(opts \\ []) do
    %{records: %{}, fail_create?: Keyword.get(opts, :fail_create?, false)}
  end

  defp tamper(<<first, rest::binary>>), do: <<Bitwise.bxor(first, 1), rest::binary>>
end
