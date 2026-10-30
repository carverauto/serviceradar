defmodule ServiceRadar.Edge.ManagedCertificateLifecycleIntegrationTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Edge.ComponentCertificateAuthority, as: Authority
  alias ServiceRadar.Edge.ManagedCertificateLifecycle, as: Lifecycle
  alias ServiceRadar.Infrastructure.Agent

  @moduletag :integration

  setup do
    opts = [actor: SystemActor.system(:managed_certificate_test)]
    host = "example-agent-#{Ecto.UUID.generate()}"

    Agent
    |> Ash.Changeset.for_create(:register_connected, %{uid: host, name: host}, opts)
    |> Ash.create!(opts)

    {:ok, component} =
      Authority.enroll_component(
        %{
          component_id: "example-collector-#{Ecto.UUID.generate()}",
          component_type: "trapd",
          partition_id: "example-partition",
          host_agent_id: host
        },
        opts
      )

    %{opts: opts, component: component}
  end

  test "retries reuse the durable preparation request and revocation fences later work", ctx do
    viewer = %{id: "example-viewer", role: :viewer, permissions: MapSet.new()}
    assert {:error, _} = Lifecycle.rotate(ctx.component.component_id, actor: viewer)
    assert {:ok, operation} = Lifecycle.rotate(ctx.component.component_id, ctx.opts)
    assert {:ok, same} = Lifecycle.rotate(ctx.component.component_id, ctx.opts)
    assert same.id == operation.id

    assert {:ok, _} =
             Authority.revoke_component(ctx.component.component_id, "operator-request", ctx.opts)

    assert :ok = Lifecycle.reconcile(operation.id)
    assert {:ok, nil} = Lifecycle.current(ctx.component.component_id, ctx.opts)

    assert {:error, :component_unavailable} =
             Lifecycle.rotate(ctx.component.component_id, ctx.opts)

    assert {:ok, _} = Authority.reenroll_component(ctx.component.component_id, ctx.opts)
    assert {:ok, successor} = Lifecycle.rotate(ctx.component.component_id, ctx.opts)
    assert successor.generation == 2
    refute successor.id == operation.id
  end

  test "durable preparation receipt must match request, generation and the exact role set", ctx do
    for wrong <- [:request, :generation, :role] do
      assert {:ok, operation} = Lifecycle.rotate(ctx.component.component_id, ctx.opts)

      receipt = %{
        "request_id" => operation.id,
        "generation" => operation.generation,
        "csrs" => %{"client" => %{"csr_der" => Base.encode64("synthetic CSR bytes")}}
      }

      receipt =
        case wrong do
          :request -> Map.put(receipt, "request_id", Ecto.UUID.generate())
          :generation -> Map.put(receipt, "generation", operation.generation + 1)
          :role -> put_in(receipt, ["csrs", "local_server"], %{"csr_der" => "AA=="})
        end

      completed_command(operation, operation.id, "certificates.prepare", receipt, ctx.opts)
      assert {:ok, failed} = Lifecycle.reconcile(operation.id)
      assert failed.status == :failed
      assert failed.error == "invalid_prepare_receipt"
    end
  end

  test "installation binds issued fingerprints and does not claim receiver enforcement", ctx do
    assert {:ok, operation} = Lifecycle.rotate(ctx.component.component_id, ctx.opts)
    fingerprint = Base.encode16(:crypto.hash(:sha256, "invented certificate"), case: :lower)
    deadline = DateTime.shift(DateTime.utc_now(), hour: 1)

    operation =
      operation
      |> Ash.Changeset.for_update(
        :progress,
        %{status: :installing, fingerprints: %{"client" => fingerprint}, renew_after: deadline},
        ctx.opts
      )
      |> Ash.update!(ctx.opts)

    receipt = %{
      "request_id" => operation.id,
      "generation" => operation.generation,
      "installed" => true,
      "activated" => true,
      "rolled_back" => false,
      "fingerprints" => %{"client" => fingerprint},
      "renew_after" => DateTime.to_iso8601(DateTime.shift(deadline, hour: 1))
    }

    completed_command(
      operation,
      operation.install_command_id,
      "certificates.install",
      receipt,
      ctx.opts
    )

    assert {:ok, activated} = Lifecycle.reconcile(operation.id)
    assert activated.status == :activated
    assert activated.observed_roles == %{}
    assert DateTime.compare(activated.renew_after, deadline) == :eq
  end

  test "receiver proof retires predecessors only after activated successor is authorized", ctx do
    now = DateTime.utc_now()
    old = Base.encode16(:crypto.hash(:sha256, "invented predecessor"), case: :lower)
    new = Base.encode16(:crypto.hash(:sha256, "invented successor"), case: :lower)

    for fingerprint <- [old, new] do
      assert {:ok, _} =
               Authority.record_issuance(
                 ctx.component.component_id,
                 %{
                   fingerprint: fingerprint,
                   issuer_fingerprint: String.duplicate("c", 64),
                   serial_number: "29",
                   not_before: DateTime.shift(now, minute: -1),
                   not_after: DateTime.shift(now, hour: 2),
                   role: "client",
                   host_agent_id: ctx.component.host_agent_id,
                   expected_generation: 1
                 },
                 ctx.opts
               )
    end

    {:ok, operation} = Lifecycle.rotate(ctx.component.component_id, ctx.opts)

    operation =
      operation
      |> Ash.Changeset.for_update(
        :progress,
        %{
          status: :installing,
          fingerprints: %{"client" => new},
          renew_after: DateTime.shift(now, hour: 1)
        },
        ctx.opts
      )
      |> Ash.update!(ctx.opts)

    assert {:error, :activation_unconfirmed} =
             Lifecycle.confirm_use(new, "example-receiver", ctx.opts)

    operation
    |> Ash.Changeset.for_update(:progress, %{status: :activated}, ctx.opts)
    |> Ash.update!(ctx.opts)

    assert {:ok, observed} = Lifecycle.confirm_use(new, "example-receiver", ctx.opts)
    assert observed.observed_roles["client"]["receiver_id"] == "example-receiver"
    assert {:ok, policy} = Authority.snapshot()
    assert new in policy.allowed_fingerprints
    refute old in policy.allowed_fingerprints
    assert {:ok, _} = Lifecycle.confirm_use(new, "example-receiver", ctx.opts)
  end

  defp completed_command(operation, id, type, receipt, opts) do
    {:ok, command} =
      AgentCommand.create_command_with_id(
        %{
          command_id: id,
          command_type: type,
          agent_id: operation.host_agent_id,
          partition_id: operation.partition_id,
          payload: %{},
          requested_by: operation.requested_by
        },
        opts
      )

    {:ok, sent} = AgentCommand.mark_sent(command, %{}, opts)
    AgentCommand.complete(sent, %{result_payload: receipt}, opts)
  end
end
