defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.ImportModal do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  # Import CSV Modal Component
  attr(:uploads, :any, required: true)
  attr(:csv_preview, :any, default: nil)
  attr(:csv_errors, :list, default: [])
  attr(:csv_warnings, :list, default: [])
  attr(:import_status, :any, default: nil)
  attr(:import_partition, :string, default: "default")
  attr(:import_partition_error, :string, default: nil)
  attr(:partition_options, :list, default: [{"Default", "default"}])

  def import_csv_modal(assigns) do
    ~H"""
    <.ui_modal id="import_csv_modal" size="lg" on_cancel="close_import_modal">
      <:title>Import Devices from CSV</:title>
      <p class="text-sm text-sr-muted">
        Upload a CSV file to bulk import devices. Rows that match an existing
        inventory device in the same partition (IP or hostname) merge tags and
        extra columns onto that device. The same IP can exist in more than one
        partition so isolation scans and monitoring scans can report independently.
      </p>

      <%!--
      Two distinct states, never conflated: a parse warning means the file was
      partly usable and the rest still previews, while an error means nothing
      was imported or the run failed part-way through.
      --%>
      <div
        :if={is_binary(@import_status)}
        class={ui_alert_class(variant: "warning", class: "my-4")}
      >
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <div>
          <div class="font-semibold">Partial Import</div>
          <p class="text-sm">{@import_status}</p>
        </div>
      </div>

      <!-- Error Display -->
      <div :if={@csv_errors != []} class={ui_alert_class(variant: "error", class: "my-4")}>
        <.icon name="hero-exclamation-circle" class="size-5" />
        <div>
          <div class="font-semibold">Import Error</div>
          <ul class="text-sm list-disc list-inside">
            <%= for error <- @csv_errors do %>
              <li>{error}</li>
            <% end %>
          </ul>
        </div>
      </div>

      <!-- Skipped-row Display -->
      <div :if={@csv_warnings != []} class={ui_alert_class(variant: "warning", class: "my-4")}>
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <div>
          <div class="font-semibold">Skipped Rows</div>
          <ul class="text-sm list-disc list-inside">
            <%= for warning <- @csv_warnings do %>
              <li>{warning}</li>
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
                <td>
                  Device hostname (resolved to an IP when the ip column is empty; max 100 per import)
                </td>
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
                <td class="font-mono">partition</td>
                <td>
                  <.ui_badge size="xs" variant="ghost">No</.ui_badge>
                </td>
                <td>
                  Network partition slug. Overrides the selector below when present (e.g. rids).
                </td>
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

      <.form
        for={%{}}
        id="import-partition-form"
        phx-change="set_import_partition"
        class="my-4 space-y-1.5"
      >
        <label class="flex items-center justify-between gap-2">
          <span class="text-sm font-medium text-sr-ink">Import into partition</span>
          <span class="text-xs text-sr-muted">Used when a row has no partition column</span>
        </label>
        <input
          type="text"
          name="partition"
          value={@import_partition}
          list="import-partition-slugs"
          class={ui_field_class()}
          placeholder="default"
          autocomplete="off"
        />
        <datalist id="import-partition-slugs">
          <%= for {name, slug} <- @partition_options do %>
            <option value={slug}>{name}</option>
          <% end %>
        </datalist>
        <p :if={@import_partition_error} class="text-xs text-error">{@import_partition_error}</p>
      </.form>

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
                <th>Partition</th>
                <th>Type</th>
                <th>Tags</th>
              </tr>
            </thead>
            <tbody>
              <%= for device <- Enum.take(@csv_preview, 20) do %>
                <tr class="hover:bg-sr-subtle/60">
                  <td class="font-mono text-xs">{device.hostname}</td>
                  <td class="font-mono text-xs">{device.ip}</td>
                  <td class="font-mono text-xs">
                    {preview_partition(device.partition, @import_partition)}
                  </td>
                  <td class="text-xs">{device.type}</td>
                  <td class="text-xs">{Enum.join(device.tags || [], ", ")}</td>
                </tr>
              <% end %>
              <%= if length(@csv_preview) > 20 do %>
                <tr>
                  <td colspan="5" class="text-center text-xs text-sr-muted py-2">
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
          href="data:text/csv;charset=utf-8,hostname,ip,type,partition,tags%0Aserver01.example.com,192.168.1.10,server,default,env=prod|team=infra%0Arouter01.example.com,192.168.1.1,router,rids,"
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

  defp preview_partition(value, _default) when is_binary(value) and value != "", do: value
  defp preview_partition(_value, default), do: default || "default"

  defp error_to_string(:too_large), do: "File is too large (max 5MB)"
  defp error_to_string(:not_accepted), do: "Invalid file type (only .csv allowed)"
  defp error_to_string(:too_many_files), do: "Only one file allowed"
  defp error_to_string(err), do: inspect(err)
end
