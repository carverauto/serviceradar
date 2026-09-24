defmodule ServiceRadarWebNGWeb.DeviceLive.IndexImportProgressTest do
  @moduledoc """
  What the operator is told while a device CSV import runs, and after it finishes.

  Before this, `import_devices/2` was called synchronously inside `handle_event`,
  so the LiveView could not render a pending state at all — the screen was
  indistinguishable from a hang — and a success closed the modal behind a
  transient flash carrying only two counts.
  """

  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNGWeb.DeviceLive.Index
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.DeviceManagement

  @moduletag :db_free

  defp importing_socket(overrides \\ %{}) do
    base = %{
      importing: true,
      import_result: nil,
      import_skipped: [],
      csv_preview: [%{"hostname" => "a"}],
      csv_errors: [],
      csv_warnings: [],
      import_status: nil,
      show_import_modal: true
    }

    Enum.reduce(Map.merge(base, overrides), %Socket{}, fn {key, value}, socket ->
      Phoenix.Component.assign(socket, key, value)
    end)
  end

  describe "a finished import reports what it did" do
    test "a wholly successful import reports created and updated, and keeps the modal open" do
      {:noreply, socket} =
        Index.handle_async(:import_devices, {:ok, {:ok, {12, 3}}}, importing_socket())

      refute socket.assigns.importing, "the pending state must clear"

      result = socket.assigns.import_result
      assert result.created == 12
      assert result.updated == 3
      assert result.failed == 0
      assert result.errors == []
      assert is_binary(result.summary)

      # The old success path closed the modal and patched to /devices, which is
      # what discarded the account of the import.
      assert socket.assigns.show_import_modal,
             "the summary must survive until the operator dismisses it"
    end

    test "a partial import reports the counts alongside the identified failures" do
      failure = {:error, %{created: 5, updated: 1, errors: ["Row 7: ip is invalid", "Row 9: duplicate"]}}

      {:noreply, socket} =
        Index.handle_async(:import_devices, {:ok, failure}, importing_socket())

      result = socket.assigns.import_result
      assert result.created == 5
      assert result.updated == 1
      assert result.failed == 2
      # Identified, not merely counted.
      assert result.errors == ["Row 7: ip is invalid", "Row 9: duplicate"]
      refute socket.assigns.importing
    end

    test "rows skipped while reading the file are reported with their reasons" do
      skipped = ["Row 4 skipped: missing hostname and ip", "... and 2 more row(s) skipped"]

      {:noreply, socket} =
        Index.handle_async(
          :import_devices,
          {:ok, {:ok, {1, 0}}},
          importing_socket(%{import_skipped: skipped})
        )

      result = socket.assigns.import_result
      assert result.skipped == skipped

      # A skipped row is not an imported one.
      assert result.created == 1
      assert result.updated == 0
    end

    test "an unrecognised result is reported as a failure rather than spinning forever" do
      {:noreply, socket} =
        Index.handle_async(:import_devices, {:ok, :something_else}, importing_socket())

      refute socket.assigns.importing
      assert socket.assigns.import_result.failed == 1
      assert [message] = socket.assigns.import_result.errors
      assert message =~ "unexpected result"
    end
  end

  describe "an import that fails outright" do
    test "a crashed import clears the pending state and reports the failure" do
      # There was no such path before: the work was synchronous, so a crash took
      # the whole LiveView down instead of being reportable.
      {:noreply, socket} =
        Index.handle_async(:import_devices, {:exit, {:shutdown, :killed}}, importing_socket())

      refute socket.assigns.importing, "a crash must not leave the UI claiming progress"
      assert socket.assigns.import_result.failed == 1
      assert [message] = socket.assigns.import_result.errors
      assert message =~ "Import failed"
    end
  end

  describe "re-entry" do
    test "a second import_csv while one is running starts no second import" do
      socket = importing_socket()

      # Returns the socket untouched: no new task, no state change. Without this,
      # a double click runs the whole import twice against the same file.
      assert {:noreply, ^socket} = DeviceManagement.handle_event("import_csv", %{}, socket)
    end
  end

  describe "dismissal" do
    test "dismissing clears the import state so the next import starts clean" do
      socket =
        importing_socket(%{
          importing: false,
          import_result: %{created: 1, updated: 0, failed: 0, errors: [], skipped: [], summary: "ok"}
        })

      {:noreply, socket} = DeviceManagement.handle_event("dismiss_import_result", %{}, socket)

      assert is_nil(socket.assigns.import_result)
      refute socket.assigns.show_import_modal
      assert socket.assigns.csv_errors == []
    end
  end
end
