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

    wrong_agent = %{agent_id: "agent-other", command_id: prepared.command_id}
    assert {:error, :launch_envelope_denied} = resolve(prepared, wrong_agent, store)

    wrong_command = %{agent_id: "agent-farm01", command_id: Ecto.UUID.generate()}
    assert {:error, :launch_envelope_denied} = resolve(prepared, wrong_command, store)

    exact = %{agent_id: "agent-farm01", command_id: prepared.command_id}
    assert {:ok, material} = resolve(prepared, exact, store)
    assert material.bearer == @bearer
    assert material.idempotency_key == @idempotency_key
    assert material.callback_grant_id == grant_id()

    assert {:error, :launch_envelope_denied} = resolve(prepared, exact, store)
  end

  test "concurrent exact resolution releases the bearer once" do
    store = start_supervised!({Agent, fn -> memory_state() end})
    assert {:ok, prepared} = prepare(store)
    exact = %{agent_id: "agent-farm01", command_id: prepared.command_id}

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

  test "ciphertext is consumed before a decryption failure" do
    store = start_supervised!({Agent, fn -> memory_state() end})
    assert {:ok, prepared} = prepare(store)

    Agent.update(store, fn state ->
      {verifier, record} = Enum.at(state.records, 0)
      tampered = Map.update!(record, :ciphertext, &tamper/1)
      put_in(state, [:records, verifier], tampered)
    end)

    exact = %{agent_id: "agent-farm01", command_id: prepared.command_id}

    assert {:error, :launch_envelope_decrypt_failed} = resolve(prepared, exact, store)
    assert {:error, :launch_envelope_denied} = resolve(prepared, exact, store)
  end

  test "seal failure leaves no resolvable envelope" do
    store = start_supervised!({Agent, fn -> memory_state(fail_create?: true) end})

    assert {:error, :forced_seal_failure} = prepare(store)
    assert AutomationLaunchEnvelopeMemoryStore.records(store) == []
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
      expires_at: DateTime.add(@issued_at, 300, :second)
    }
  end

  defp grant_id, do: "01980a6d-4a62-7b3f-a249-5f825874ca53"

  defp memory_state(opts \\ []) do
    %{records: %{}, fail_create?: Keyword.get(opts, :fail_create?, false)}
  end

  defp tamper(<<first, rest::binary>>), do: <<Bitwise.bxor(first, 1), rest::binary>>
end
