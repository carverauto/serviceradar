defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.ImportModal do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  # Import CSV Modal Component
  attr(:uploads, :any, required: true)
  attr(:csv_preview, :any, default: nil)
  attr(:csv_errors, :list, default: [])

  def import_csv_modal(assigns) do
    ~H"""
    <dialog id="import_csv_modal" class="modal modal-open">
      <div class="modal-box max-w-3xl">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_import_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold">Import Devices from CSV</h3>
        <p class="py-2 text-sm text-base-content/70">
          Upload a CSV file to bulk import devices into your inventory.
        </p>
        
    <!-- Error Display -->
        <div :if={@csv_errors != []} class="alert alert-error my-4">
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
        
    <!-- CSV Format Guide (collapsed when preview is shown) -->
        <div :if={is_nil(@csv_preview)} class="my-4 p-4 bg-base-200/50 rounded-lg">
          <h4 class="font-medium text-sm mb-2">CSV Format</h4>
          <p class="text-xs text-base-content/70 mb-3">
            Your CSV file should include the following columns:
          </p>
          <div class="overflow-x-auto">
            <table class="table table-xs">
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
                  <td><span class="badge badge-xs badge-success">Yes</span></td>
                  <td>Device hostname</td>
                </tr>
                <tr>
                  <td class="font-mono">ip</td>
                  <td><span class="badge badge-xs badge-success">Yes</span></td>
                  <td>IP address</td>
                </tr>
                <tr>
                  <td class="font-mono">type</td>
                  <td><span class="badge badge-xs badge-ghost">No</span></td>
                  <td>Device type (server, workstation, router, etc.)</td>
                </tr>
                <tr>
                  <td class="font-mono">tags</td>
                  <td><span class="badge badge-xs badge-ghost">No</span></td>
                  <td>Pipe-separated tags (env=prod|team=ops)</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
        
    <!-- File Upload -->
        <.form for={%{}} phx-change="validate_csv" phx-submit="preview_csv" class="space-y-4">
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Upload CSV File</span>
              <span class="label-text-alt text-base-content/50">Max 5MB</span>
            </label>
            <.live_file_input
              upload={@uploads.csv_file}
              class="file-input file-input-bordered w-full"
            />
            <%= for entry <- @uploads.csv_file.entries do %>
              <div class="mt-2 flex items-center gap-2 text-sm">
                <.icon name="hero-document-text" class="size-4 text-primary" />
                <span>{entry.client_name}</span>
                <span class="text-base-content/50">
                  ({Float.round(entry.client_size / 1024, 1)} KB)
                </span>
                <%= for err <- upload_errors(@uploads.csv_file, entry) do %>
                  <span class="text-error text-xs">{error_to_string(err)}</span>
                <% end %>
              </div>
            <% end %>
          </div>

          <div :if={is_nil(@csv_preview)} class="flex justify-end">
            <button
              type="submit"
              class="btn btn-outline btn-sm"
              disabled={@uploads.csv_file.entries == []}
            >
              <.icon name="hero-eye" class="size-4" /> Preview
            </button>
          </div>
        </.form>
        
    <!-- Preview Table -->
        <div :if={is_list(@csv_preview) and @csv_preview != []} class="mt-4">
          <div class="flex items-center justify-between mb-2">
            <h4 class="font-medium text-sm">
              Preview ({length(@csv_preview)} device(s))
            </h4>
            <span class="badge badge-success badge-sm">Ready to import</span>
          </div>
          <div class="overflow-x-auto max-h-64 border border-base-200 rounded-lg">
            <table class="table table-xs table-pin-rows">
              <thead>
                <tr class="bg-base-200">
                  <th>Hostname</th>
                  <th>IP</th>
                  <th>Type</th>
                  <th>Tags</th>
                </tr>
              </thead>
              <tbody>
                <%= for device <- Enum.take(@csv_preview, 20) do %>
                  <tr class="hover:bg-base-200/50">
                    <td class="font-mono text-xs">{device.hostname}</td>
                    <td class="font-mono text-xs">{device.ip}</td>
                    <td class="text-xs">{device.type}</td>
                    <td class="text-xs">{Enum.join(device.tags || [], ", ")}</td>
                  </tr>
                <% end %>
                <%= if length(@csv_preview) > 20 do %>
                  <tr>
                    <td colspan="4" class="text-center text-xs text-base-content/50 py-2">
                      ... and {length(@csv_preview) - 20} more
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>

        <div class="mt-4 flex items-center gap-2 text-xs text-base-content/60">
          <.icon name="hero-arrow-down-tray" class="size-4" />
          <a
            href="data:text/csv;charset=utf-8,hostname,ip,type,tags%0Aserver01.example.com,192.168.1.10,server,env=prod|team=infra%0Arouter01.example.com,192.168.1.1,router,"
            class="link link-hover"
            download="devices-template.csv"
          >
            Download CSV template
          </a>
        </div>

        <div class="modal-action">
          <button type="button" class="btn btn-ghost" phx-click="close_import_modal">
            Cancel
          </button>
          <button
            :if={is_list(@csv_preview) and @csv_preview != []}
            type="button"
            class="btn btn-primary"
            phx-click="import_csv"
          >
            <.icon name="hero-arrow-up-tray" class="size-4" /> Import {length(@csv_preview)} Device(s)
          </button>
          <.link :if={is_nil(@csv_preview)} navigate={~p"/settings/networks"}>
            <button type="button" class="btn btn-outline">
              <.icon name="hero-signal" class="size-4" /> Use Network Discovery
            </button>
          </.link>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_import_modal">close</button>
      </form>
    </dialog>
    """
  end

  defp error_to_string(:too_large), do: "File is too large (max 5MB)"
  defp error_to_string(:not_accepted), do: "Invalid file type (only .csv allowed)"
  defp error_to_string(:too_many_files), do: "Only one file allowed"
  defp error_to_string(err), do: inspect(err)
end
