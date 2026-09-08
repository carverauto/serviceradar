defmodule ServiceRadar.Automation.CallbackGrants.AwxCleanupTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.CallbackGrants.AwxCleanup

  @grant_id "018f3f56-1111-7222-8333-123456789abc"
  @execution_id "018f3f56-1111-7222-8333-123456789abd"
  @controller_id "018f3f56-1111-7222-8333-123456789abe"
  @delete_command_id "018f3f56-1111-7222-8333-123456789abf"
  @cancel_command_id "018f3f56-1111-7222-8333-123456789ac0"

  test "revocation queues exact cancellation and a cleanup-only credential delete" do
    context = dispatch_context(self())

    assert {:ok,
            %{
              cleanup_status: :queued,
              job_cleanup: :cancel_requested,
              credential_cleanup: :delete_requested
            }} =
             AwxCleanup.cleanup(
               grant(%{
                 state: :revoked,
                 credential_cleanup_attempted_at: ~U[2026-07-13 12:00:00Z]
               }),
               :revoked,
               context
             )

    assert_receive {:cancel, controller, 9_001, cancel_opts}
    assert controller.id == @controller_id

    assert cancel_opts[:context] == %{
             "schema" => "serviceradar.automation_callback_cleanup_command/v1",
             "grant_id" => @grant_id,
             "execution_id" => @execution_id,
             "controller_id" => @controller_id,
             "dispatch_agent_id" => "agent-gateway-demo",
             "dispatch_partition_id" => "farm01",
             "awx_job_id" => 9_001,
             "credential_id" => 401,
             "cleanup_kind" => "job_cancel",
             "cleanup_mode" => "revoked"
           }

    assert_receive {:delete, ^controller, 401, binding, delete_opts}
    assert cancel_opts[:required_partition] == "farm01"
    assert delete_opts[:required_partition] == "farm01"

    assert binding == %{
             child_execution_id: @execution_id,
             inventory_id: 34,
             job_template_id: 42,
             credential_type_id: 91,
             organization_id: 2,
             credential_slot: "ssh_ca_callback",
             injector_sha256: String.duplicate("c", 64)
           }

    refute Map.has_key?(binding, :envelope_ref)
    refute Map.has_key?(binding, "envelope_ref")
    refute inspect({binding, delete_opts}) =~ "launch-envelope"
    refute inspect({binding, delete_opts}) =~ "callback-bearer"

    assert delete_opts[:context]["cleanup_kind"] == "credential_delete"
    assert delete_opts[:context]["cleanup_mode"] == "revoked"
  end

  test "post-activation deletion leaves the running job alone and returns before confirmation" do
    context = dispatch_context(self())

    assert {:ok,
            %{
              cleanup_status: :queued,
              job_cleanup: :not_required,
              credential_cleanup: :delete_requested
            }} = AwxCleanup.delete_activated(grant(), context)

    assert_receive {:delete, _controller, 401, binding, opts}
    assert opts[:context]["cleanup_mode"] == "post_activation"
    refute Map.has_key?(binding, :envelope_ref)
    refute_received {:cancel, _, _, _}
  end

  test "post-activation deletion retries only an explicitly stale deleting intent" do
    deleting =
      grant(%{
        credential_cleanup_state: :deleting,
        credential_cleanup_attempted_at: ~U[2026-07-13 12:00:00Z]
      })

    assert {:ok,
            %{
              cleanup_status: :queued,
              credential_cleanup: :delete_requested
            }} = AwxCleanup.delete_activated(deleting, dispatch_context(self()))

    refute_received {:delete, _, _, _, _}

    retry_context =
      self()
      |> dispatch_context()
      |> Keyword.put(:retry_deleting?, true)

    assert {:ok,
            %{
              cleanup_status: :queued,
              credential_cleanup: :delete_requested
            }} = AwxCleanup.delete_activated(deleting, retry_context)

    assert_receive {:delete, _controller, 401, _binding, opts}
    assert opts[:context]["cleanup_mode"] == "post_activation"
    refute_received {:cancel, _, _, _}
  end

  test "terminal cleanup dispatches a second idempotent delete after early deletion" do
    terminal =
      grant(%{
        state: :consumed,
        credential_cleanup_state: :deleted,
        credential_cleanup_attempted_at: ~U[2026-07-13 12:00:00Z]
      })

    assert {:ok,
            %{
              cleanup_status: :queued,
              job_cleanup: :not_required,
              credential_cleanup: :delete_requested
            }} = AwxCleanup.cleanup(terminal, :consumed, dispatch_context(self()))

    assert_receive {:delete, _controller, 401, _binding, opts}
    assert opts[:context]["cleanup_mode"] == "consumed"
    refute_received {:cancel, _, _, _}
  end

  test "a known terminal job confirms orphan removal without dispatching cancellation" do
    terminal = grant(%{state: :revoked, orphan_risk_state: :cancel_requested})

    assert {:ok,
            %{
              cleanup_status: :queued,
              job_cleanup: :cancel_confirmed,
              credential_cleanup: :delete_requested
            }} = AwxCleanup.cleanup(terminal, :job_terminal, dispatch_context(self()))

    assert_receive {:delete, _controller, 401, _binding, opts}
    assert opts[:context]["cleanup_mode"] == "job_terminal"
    refute_received {:cancel, _, _, _}
  end

  test "post-activation deletion requires exact active binding proof" do
    for invalid <- [
          grant(%{state: :pending}),
          grant(%{binding_verified: false}),
          grant(%{job_binding: nil}),
          grant(%{job_binding: %{controller_id: @controller_id}}),
          grant(%{ephemeral_credential_id: nil})
        ] do
      assert {:error,
              %{
                cleanup_status: :failed,
                job_cleanup: :not_required,
                credential_cleanup: status
              }} = AwxCleanup.delete_activated(invalid, dispatch_context(self()))

      assert status in [:not_required, :delete_failed]
      refute_received {:delete, _, _, _, _}
      refute_received {:cancel, _, _, _}
    end
  end

  test "controller ambiguity fails closed and retains both cleanup risks" do
    context =
      dispatch_context(self(),
        controller_loader: fn _id ->
          {:ok, %{id: Ecto.UUID.generate(), agent_id: "agent-gateway-demo"}}
        end
      )

    assert {:error,
            %{
              cleanup_status: :failed,
              job_cleanup: :cancel_failed,
              credential_cleanup: :delete_failed
            }} = AwxCleanup.cleanup(grant(%{state: :revoked}), :revoked, context)

    refute_received {:delete, _, _, _, _}
    refute_received {:cancel, _, _, _}
  end

  defp dispatch_context(test_pid, overrides \\ []) do
    defaults = [
      controller_loader: fn id ->
        {:ok, %{id: id, agent_id: "agent-gateway-demo"}}
      end,
      cancel_job: fn controller, job_id, opts ->
        send(test_pid, {:cancel, controller, job_id, opts})
        {:ok, %{id: @cancel_command_id}}
      end,
      delete_credential: fn controller, credential_id, binding, opts ->
        send(test_pid, {:delete, controller, credential_id, binding, opts})
        {:ok, %{id: @delete_command_id}}
      end
    ]

    Keyword.merge(defaults, overrides)
  end

  defp grant(overrides \\ %{}) do
    Map.merge(
      %{
        id: @grant_id,
        state: :active,
        execution_id: @execution_id,
        binding_verified: true,
        awx_scope_snapshot: %{
          controller_id: @controller_id,
          inventory_id: 34,
          job_template_id: 42,
          callback_credential_type_id: 91,
          callback_credential_organization_id: 2,
          callback_credential_injector_digest: String.duplicate("c", 64)
        },
        job_binding: %{controller_id: @controller_id, job_id: 9_001},
        ephemeral_credential_id: 401,
        dispatch_agent_id: "agent-gateway-demo",
        dispatch_partition_id: "farm01",
        credential_cleanup_state: :deleting,
        credential_cleanup_attempted_at: nil,
        orphan_risk_state: :cancel_requested,
        launch_envelope_ref: "launch-envelope:must-never-be-forwarded",
        callback_bearer: "callback-bearer:must-never-be-forwarded"
      },
      overrides
    )
  end
end
