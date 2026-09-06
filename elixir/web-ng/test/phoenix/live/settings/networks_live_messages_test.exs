defmodule ServiceRadarWebNGWeb.Settings.NetworksLiveMessagesTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Changes.StaleRecord
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Messages

  @moduletag :db_free

  describe "sweep_group_delete_error_message/1" do
    # #4076: every delete failure used to render the same sentence, so an
    # operator could not tell "you lack the role" from "something in the
    # database refused" and had no next step either way.
    test "names the authorization failure it can distinguish" do
      message = Messages.sweep_group_delete_error_message(%Ash.Error.Forbidden{})

      assert message =~ "not authorized"
      refute message == Messages.sweep_group_delete_error_message(:some_other_reason)
    end

    test "names a group another session already deleted" do
      error = %Ash.Error.Invalid{errors: [StaleRecord.exception(resource: ServiceRadar.SweepJobs.SweepGroup)]}

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
end
