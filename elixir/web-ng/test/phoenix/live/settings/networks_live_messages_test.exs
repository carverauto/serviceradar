defmodule ServiceRadarWebNGWeb.Settings.NetworksLiveMessagesTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Changes.StaleRecord
  alias Ash.Error.Forbidden
  alias Ash.Error.Invalid
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Messages

  @moduletag :db_free

  describe "sweep_group_delete_confirm_message/1" do
    # #4076 ships a delete that discards execution history. The operator agrees
    # to that before it happens, with the size of it in front of them, or the
    # confirmation is not informed consent.
    test "names how many executions the delete discards" do
      message = Messages.sweep_group_delete_confirm_message(1234)

      assert message =~ "1234 executions"
      assert message =~ "per-host results"
      assert message =~ "coverage rollups are kept"
    end

    test "reads correctly for a single execution" do
      message = Messages.sweep_group_delete_confirm_message(1)

      assert message =~ "1 execution and"
      refute message =~ "1 executions"
    end

    test "a group that has never run says nothing is discarded" do
      message = Messages.sweep_group_delete_confirm_message(0)

      assert message =~ "no recorded executions"
      refute message =~ "discards"
    end
  end

  describe "sweep_group_delete_error_message/1" do
    # #4076: every delete failure used to render the same sentence, so an
    # operator could not tell "you lack the role" from "something in the
    # database refused" and had no next step either way.
    test "names the authorization failure it can distinguish" do
      message = Messages.sweep_group_delete_error_message(%Forbidden{})

      assert message =~ "not authorized"
      refute message == Messages.sweep_group_delete_error_message(:some_other_reason)
    end

    test "names a group another session already deleted" do
      error = %Invalid{errors: [StaleRecord.exception(resource: ServiceRadar.SweepJobs.SweepGroup)]}

      assert Messages.sweep_group_delete_error_message(error) =~ "no longer exists"
    end

    test "an unrecognized reason points at the log rather than inventing a cause" do
      message = Messages.sweep_group_delete_error_message({:some, :unmapped, :reason})

      assert message =~ "server log"
      # The raw reason is logged, never rendered: it can carry a constraint name
      # or a table name that means nothing to an operator.
      refute message =~ "unmapped"
    end
  end

  describe "sweep_execution_cancel_message/2" do
    # The run is closed before its agent is asked to stop, so an agent that was
    # not stopped may still be scanning, and the operator has to be told so.
    test "every outcome reports the cancellation and whether the agent stopped" do
      assert Messages.sweep_execution_cancel_message("agent-a", {:ok, "command-1"}) ==
               "Scan cancelled. Its agent was asked to stop."

      assert Messages.sweep_execution_cancel_message(
               "agent-a",
               {:error, {:agent_capability_missing, "agent-a", "sweep_cancel"}}
             ) == "Scan cancelled, but agent agent-a was not stopped. It does not support cancelling scans."

      assert Messages.sweep_execution_cancel_message("agent-a", {:error, {:agent_offline, "agent-a"}}) ==
               "Scan cancelled, but agent agent-a was not stopped. It is offline."

      assert Messages.sweep_execution_cancel_message("agent-a", {:error, {:agent_partition_ambiguous, "agent-a"}}) ==
               "Scan cancelled, but agent agent-a was not stopped. Multiple canonical control sessions."

      assert Messages.sweep_execution_cancel_message(nil, {:error, :invalid_agent_id}) =~
               "none was asked to stop"
    end
  end

  describe "sweep_execution_cancel_error_message/1" do
    test "a run that ended before the cancel landed reads as no longer running" do
      error = %Invalid{
        errors: [StaleRecord.exception(resource: ServiceRadar.SweepJobs.SweepGroupExecution)]
      }

      assert Messages.sweep_execution_cancel_error_message(error) == "That scan is no longer running"
    end

    test "both refusal paths name the missing authorization" do
      assert Messages.sweep_execution_cancel_error_message(:unauthorized) =~ "not authorized"
      assert Messages.sweep_execution_cancel_error_message(%Forbidden{}) =~ "not authorized"
    end

    test "an unrecognized reason points at the log rather than rendering it" do
      message = Messages.sweep_execution_cancel_error_message({:some, :unmapped, :reason})

      assert message =~ "server log"
      refute message =~ "unmapped"
    end
  end
end
