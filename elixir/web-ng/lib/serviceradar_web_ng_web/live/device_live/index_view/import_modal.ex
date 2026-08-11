defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.ImportModal do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  # Import CSV Modal Component
  attr(:uploads, :any, required: true)
  attr(:csv_preview, :any, default: nil)
  attr(:csv_errors, :list, default: [])

  def import_csv_modal(assigns) do
    ~H"""
    <.ui_modal id="import_csv_modal" size="lg" on_cancel="close_import_modal">
      <:title>Import Devices from CSV</:title>
      <p class="text-sm text-sr-muted">
        Upload a CSV file to bulk import devices into your inventory.
      </p>

      <!-- Error Display -->
      <div
        :if={@csv_errors != []}
        class={ui_alert_class(variant: if(@csv_preview, do: "warning", else: "error"), class: "my-4")}
      >
        <.icon name="hero-exclamation-circle" class="size-5" />
        <div>
          <%!-- A preview alongside messages means rows were skipped, not that the import failed. --%>
          <div class="font-semibold">
            {if @csv_preview, do: "Skipped Rows", else: "Import Error"}
          </div>
          <ul class="text-sm list-disc list-inside">
            <%= for error <- @csv_errors do %>
              <li>{error}</li>
            <% end %>
          </ul>
        </div>
      </div>

      <!-- CSV Format Guide (collapsed when preview is shown) -->
      <div :if={is_nil(@csv_preview)} class="my-4 p-4 bg-sr-subtle/60 rounded-lg">
        <h4 class="font-medium text-sm mb-2">CSV Format</h4>
        <p class="text-xs text-sr-muted mb-3">
          Your CSV file should include the following columns:
        </p>
        <div class="sr-ui-table-shell">
          <table class={ui_table_class(size: "xs")}>
            <thead>
              <tr>
                <th>Column</th>
                <th>Required</th>
                <th>Description</th>
              </tr>
            </thead>
            <tbody class="text-xs">
              <tr>
                <td class="font-mono">hostname</td>
                <td>
                  <.ui_badge size="xs" variant="warning">Either</.ui_badge>
                </td>
                <td>Device hostname (resolved to an IP when the ip column is empty)</td>
              </tr>
              <tr>
                <td class="font-mono">ip</td>
                <td>
                  <.ui_badge size="xs" variant="warning">Either</.ui_badge>
                </td>
                <td>IP address</td>
              </tr>
              <tr>
                <td class="font-mono">type</td>
                <td>
                  <.ui_badge size="xs" variant="ghost">No</.ui_badge>
                </td>
                <td>Device type (server, workstation, router, etc.)</td>
              </tr>
              <tr>
                <td class="font-mono">tags</td>
                <td>
                  <.ui_badge size="xs" variant="ghost">No</.ui_badge>
                </td>
                <td>Pipe-separated tags (env=prod|team=ops)</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <!-- File Upload -->
      <.form for={%{}} phx-change="validate_csv" phx-submit="preview_csv" class="space-y-4">
        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Upload CSV File</span>
            <span class="text-xs text-sr-muted">Max 5MB</span>
          </label>
          <.live_file_input
            upload={@uploads.csv_file}
            class={
              ui_field_class(
                class:
                  "w-full file:mr-3 file:rounded-sr-control file:border-0 file:bg-sr-subtle file:px-3 file:py-1.5 file:text-sm file:font-semibold file:text-sr-ink"
              )
            }
          />
          <%= for entry <- @uploads.csv_file.entries do %>
            <div class="mt-2 flex items-center gap-2 text-sm">
              <.icon name="hero-document-text" class="size-4 text-sr-brand" />
              <span>{entry.client_name}</span>
              <span class="text-sr-muted">
                ({Float.round(entry.client_size / 1024, 1)} KB)
              </span>
              <%= for err <- upload_errors(@uploads.csv_file, entry) do %>
                <span class="text-error text-xs">{error_to_string(err)}</span>
              <% end %>
            </div>
          <% end %>
        </div>

        <div :if={is_nil(@csv_preview)} class="flex justify-end">
          <.ui_button
            type="submit"
            variant="outline"
            size="sm"
            disabled={@uploads.csv_file.entries == []}
          >
            <.icon name="hero-eye" class="size-4" /> Preview
          </.ui_button>
        </div>
      </.form>

      <!-- Preview Table -->
      <div :if={is_list(@csv_preview) and @csv_preview != []} class="mt-4">
        <div class="flex items-center justify-between mb-2">
          <h4 class="font-medium text-sm">
            Preview ({length(@csv_preview)} device(s))
          </h4>
          <.ui_badge size="sm" variant="success">Ready to import</.ui_badge>
        </div>
        <div class="sr-ui-table-shell">
          <table class={ui_table_class(size: "xs")}>
            <thead>
              <tr class="bg-sr-subtle">
                <th>Hostname</th>
                <th>IP</th>
                <th>Type</th>
                <th>Tags</th>
              </tr>
            </thead>
            <tbody>
              <%= for device <- Enum.take(@csv_preview, 20) do %>
                <tr class="hover:bg-sr-subtle/60">
                  <td class="font-mono text-xs">{device.hostname}</td>
                  <td class="font-mono text-xs">{device.ip}</td>
                  <td class="text-xs">{device.type}</td>
                  <td class="text-xs">{Enum.join(device.tags || [], ", ")}</td>
                </tr>
              <% end %>
              <%= if length(@csv_preview) > 20 do %>
                <tr>
                  <td colspan="4" class="text-center text-xs text-sr-muted py-2">
                    ... and {length(@csv_preview) - 20} more
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>

      <div class="mt-4 flex items-center gap-2 text-xs text-sr-muted">
        <.icon name="hero-arrow-down-tray" class="size-4" />
        <a
          href="data:text/csv;charset=utf-8,hostname,ip,type,tags%0Aserver01.example.com,192.168.1.10,server,env=prod|team=infra%0Arouter01.example.com,192.168.1.1,router,"
          class="text-sr-brand hover:underline"
          download="devices-template.csv"
        >
          Download CSV template
        </a>
      </div>

      <div class="flex flex-wrap items-center justify-end gap-2 pt-1">
        <.ui_button type="button" variant="ghost" phx-click="close_import_modal">
          Cancel
        </.ui_button>
        <.ui_button
          :if={is_list(@csv_preview) and @csv_preview != []}
          type="button"
          variant="primary"
          phx-click="import_csv"
        >
          <.icon name="hero-arrow-up-tray" class="size-4" /> Import {length(@csv_preview)} Device(s)
        </.ui_button>
        <.ui_button :if={is_nil(@csv_preview)} navigate={~p"/settings/networks"} variant="outline">
          <.icon name="hero-signal" class="size-4" /> Use Network Discovery
        </.ui_button>
      </div>
    </.ui_modal>
    """
  end

  defp error_to_string(:too_large), do: "File is too large (max 5MB)"
  defp error_to_string(:not_accepted), do: "Invalid file type (only .csv allowed)"
  defp error_to_string(:too_many_files), do: "Only one file allowed"
  defp error_to_string(err), do: inspect(err)
end
