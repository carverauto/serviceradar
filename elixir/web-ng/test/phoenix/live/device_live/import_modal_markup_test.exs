defmodule ServiceRadarWebNGWeb.DeviceLive.ImportModalMarkupTest do
  @moduledoc """
  Rendered-output tests for the ImportModal component.

  These are pure function component tests: no database, no LiveView process,
  no endpoint. render_component/2 calls the HEEx function directly and returns
  HTML. Each test asserts what the operator would see in the browser.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ServiceRadarWebNGWeb.DeviceLive.IndexView.ImportModal

  @moduletag :db_free

  defp minimal_uploads do
    %{
      csv_file: %Phoenix.LiveView.UploadConfig{
        ref: "phx-csv_file",
        name: :csv_file,
        accept: ".csv",
        entries: [],
        errors: [],
        auto_upload?: false,
        max_entries: 1
      }
    }
  end

  defp base_assigns(overrides \\ []) do
    defaults = [
      uploads: minimal_uploads(),
      csv_preview: nil,
      csv_errors: [],
      csv_warnings: [],
      importing: false,
      import_result: nil,
      import_partition: "default",
      import_partition_error: nil,
      partition_options: [{"Default", "default"}]
    ]

    Keyword.merge(defaults, overrides)
  end

  defp a_preview_row do
    %{hostname: "server01.example.com", ip: nil, partition: nil, type: nil, tags: []}
  end

  defp finished_result(overrides \\ %{}) do
    Map.merge(
      %{created: 12, updated: 3, failed: 0, errors: [], skipped: [], summary: nil},
      overrides
    )
  end

  describe "import in progress" do
    test "Import button shows Importing label and is disabled while the task runs" do
      html =
        render_component(&ImportModal.import_csv_modal/1,
          base_assigns(
            csv_preview: [a_preview_row()],
            importing: true
          )
        )

      assert html =~ "Importing"
      assert html =~ "disabled"
    end
  end

  describe "result summary" do
    test "result tiles render the created, updated, failed, and skipped counts" do
      result = finished_result(%{created: 12, updated: 3, failed: 2, skipped: ["Row 5 skipped: missing ip"]})

      html =
        render_component(&ImportModal.import_csv_modal/1,
          base_assigns(import_result: result)
        )

      assert html =~ "Import finished"
      assert html =~ ">12<"
      assert html =~ ">3<"
      assert html =~ ">2<"
      assert html =~ ">1<"
    end

    test "pre-import affordances are absent when import_result is present" do
      result = finished_result()

      html =
        render_component(&ImportModal.import_csv_modal/1,
          base_assigns(
            import_result: result,
            csv_errors: ["Some earlier error that must not re-appear"],
            csv_warnings: ["Row 4 skipped: bad ip"]
          )
        )

      refute html =~ "Use Network Discovery"
      refute html =~ "Import Error"
      refute html =~ "Skipped Rows"
    end

    test "exactly one action is available in the result state: Done" do
      result = finished_result()

      html =
        render_component(&ImportModal.import_csv_modal/1,
          base_assigns(import_result: result)
        )

      assert html =~ "dismiss_import_result"
      refute html =~ ">Cancel<"
    end
  end

  describe "pre-import error alert" do
    test "csv_errors alert renders when import_result is nil and csv_errors is non-empty" do
      html =
        render_component(&ImportModal.import_csv_modal/1,
          base_assigns(csv_errors: ["No CSV data to import. Preview first."])
        )

      assert html =~ "Import Error"
      assert html =~ "No CSV data to import. Preview first."
    end
  end
end
