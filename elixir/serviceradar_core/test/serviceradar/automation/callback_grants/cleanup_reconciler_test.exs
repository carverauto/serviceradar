defmodule ServiceRadar.Automation.CallbackGrants.CleanupReconcilerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.CallbackGrants.CleanupReconciler

  @command_id "018f3f56-1111-7222-8333-123456789abf"
  @grant_id "018f3f56-1111-7222-8333-123456789abc"
  @execution_id "018f3f56-1111-7222-8333-123456789abd"
  @controller_id "018f3f56-1111-7222-8333-123456789abe"

  test "a persisted delete command reconciles an exact success as deleted" do
    opts = opts(self(), delete_command())

    assert :ok =
             CleanupReconciler.handle_command_result(
               delete_result(%{
                 "verb" => "awx.delete_callback_credential",
                 "ok" => true,
                 "credential_id" => 401,
                 "credential_type_id" => 91,
                 "cleanup_status" => "already_absent"
               }),
               opts
             )

    assert_receive {:reconcile, @grant_id, attrs}
    assert attrs.result_status == :deleted
    assert attrs.cleanup_kind == "credential_delete"
    assert attrs.cleanup_mode == "post_activation"
    assert attrs.command_id == @command_id
    assert attrs.credential_id == 401
    refute Map.has_key?(attrs, :payload)
    refute inspect(attrs) =~ "response_body"
    refute inspect(attrs) =~ "bearer"
  end

  test "a malformed successful delete result fails closed without persisting its body" do
    payload = %{
      "verb" => "awx.delete_callback_credential",
      "ok" => true,
      "credential_id" => 999,
      "credential_type_id" => 91,
      "cleanup_status" => "deleted",
      "response_body" => "sensitive upstream body"
    }

    assert :ok =
             CleanupReconciler.handle_command_result(
               delete_result(payload),
               opts(self(), delete_command())
             )

    assert_receive {:reconcile, @grant_id, attrs}
    assert attrs.result_status == :delete_failed
    refute inspect(attrs) =~ "sensitive upstream body"
  end

  test "an exact AWX cancellation result records only that cancellation was requested" do
    command = cancel_command()

    result = %{
      command_id: @command_id,
      command_type: "awx.cancel_job",
      agent_id: "agent-gateway-demo",
      partition_id: "farm01",
      success: true,
      payload: %{
        "verb" => "awx.cancel_job",
        "ok" => true,
        "job_id" => 9_001,
        "status" => 202
      }
    }

    assert :ok = CleanupReconciler.handle_command_result(result, opts(self(), command))
    assert_receive {:reconcile, @grant_id, %{result_status: :cancel_requested} = attrs}
    assert attrs.cleanup_kind == "job_cancel"
    assert attrs.awx_job_id == 9_001
  end

  test "failed agent results preserve credential and orphan risk" do
    failed_delete =
      %{"response_body" => "must-not-persist"}
      |> delete_result()
      |> Map.put(:success, false)

    assert :ok =
             CleanupReconciler.handle_command_result(
               failed_delete,
               opts(self(), delete_command())
             )

    assert_receive {:reconcile, @grant_id, %{result_status: :delete_failed} = delete_attrs}
    refute inspect(delete_attrs) =~ "must-not-persist"

    failed_cancel = %{
      command_id: @command_id,
      command_type: "awx.cancel_job",
      agent_id: "agent-gateway-demo",
      partition_id: "farm01",
      success: false,
      payload: %{"response_body" => "must-not-persist"}
    }

    assert :ok =
             CleanupReconciler.handle_command_result(
               failed_cancel,
               opts(self(), cancel_command())
             )

    assert_receive {:reconcile, @grant_id, %{result_status: :cancel_failed} = cancel_attrs}
    refute inspect(cancel_attrs) =~ "must-not-persist"
  end

  test "missing or ambiguous local correlation is rejected before store reconciliation" do
    extra_context = Map.put(delete_context(), "bearer", "must-not-be-accepted")
    ambiguous = %{delete_command() | context: extra_context}

    assert {:error, :cleanup_map_field_invalid} =
             CleanupReconciler.handle_command_result(
               delete_result(valid_delete_payload()),
               opts(self(), ambiguous)
             )

    refute_received {:reconcile, _, _}

    mismatched = %{
      delete_command()
      | context: Map.put(delete_context(), "dispatch_agent_id", "another-agent")
    }

    assert {:error, :cleanup_command_agent_mismatch} =
             CleanupReconciler.handle_command_result(
               delete_result(valid_delete_payload()),
               opts(self(), mismatched)
             )

    refute_received {:reconcile, _, _}

    assert {:error, :cleanup_result_agent_mismatch} =
             valid_delete_payload()
             |> delete_result()
             |> Map.put(:agent_id, "another-agent")
             |> CleanupReconciler.handle_command_result(opts(self(), delete_command()))

    refute_received {:reconcile, _, _}

    assert {:error, :cleanup_result_partition_mismatch} =
             valid_delete_payload()
             |> delete_result()
             |> Map.put(:partition_id, "tonka01")
             |> CleanupReconciler.handle_command_result(opts(self(), delete_command()))

    refute_received {:reconcile, _, _}
  end

  test "unrelated command results are ignored without fetching a command" do
    assert :ok =
             CleanupReconciler.handle_command_result(
               %{command_type: "awx.fetch_job", command_id: @command_id},
               fetch_command: fn _id -> flunk("must not fetch unrelated commands") end
             )
  end

  defp opts(test_pid, command) do
    [
      fetch_command: fn @command_id -> {:ok, command} end,
      reconcile: fn grant_id, attrs ->
        send(test_pid, {:reconcile, grant_id, attrs})
        :ok
      end
    ]
  end

  defp delete_result(payload) do
    %{
      command_id: @command_id,
      command_type: "awx.delete_callback_credential",
      agent_id: "agent-gateway-demo",
      partition_id: "farm01",
      success: true,
      payload: payload
    }
  end

  defp valid_delete_payload do
    %{
      "verb" => "awx.delete_callback_credential",
      "ok" => true,
      "credential_id" => 401,
      "credential_type_id" => 91,
      "cleanup_status" => "deleted"
    }
  end

  defp delete_command do
    %{
      id: @command_id,
      command_type: "awx.delete_callback_credential",
      agent_id: "agent-gateway-demo",
      partition_id: "farm01",
      context: delete_context()
    }
  end

  defp cancel_command do
    %{
      id: @command_id,
      command_type: "awx.cancel_job",
      agent_id: "agent-gateway-demo",
      partition_id: "farm01",
      context:
        delete_context()
        |> Map.put("cleanup_kind", "job_cancel")
        |> Map.put("cleanup_mode", "revoked")
    }
  end

  defp delete_context do
    %{
      "schema" => "serviceradar.automation_callback_cleanup_command/v1",
      "grant_id" => @grant_id,
      "execution_id" => @execution_id,
      "controller_id" => @controller_id,
      "dispatch_agent_id" => "agent-gateway-demo",
      "dispatch_partition_id" => "farm01",
      "awx_job_id" => 9_001,
      "credential_id" => 401,
      "cleanup_kind" => "credential_delete",
      "cleanup_mode" => "post_activation"
    }
  end
end
