defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.PanelComposerComponents do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.AuthoredDashboardLive.PanelFormComponents

  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.CanvasState

  attr :dashboard, :any, required: true
  attr :editing_panel_id, :string, default: nil
  attr :panel_form, :any, required: true
  attr :panel_preview, :any, default: nil
  attr :panel_results, :map, default: %{}
  attr :clone_targets, :list, default: []
  attr :clone_target_id, :string, default: ""

  def panel_composer_modal(assigns) do
    ~H"""
    <dialog
      :if={@editing_panel_id}
      id="dashboard-panel-composer-modal"
      class="modal modal-open"
    >
      <div class="modal-box flex max-h-[90vh] w-11/12 max-w-6xl flex-col overflow-hidden p-0">
        <div class="flex flex-col gap-3 border-b border-base-300 bg-base-100 px-5 py-4 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-normal text-primary">
              SRQL panel composer
            </p>
            <h2 class="mt-1 text-lg font-semibold tracking-normal">
              {if @editing_panel_id == "new", do: "Create New Panel", else: "Edit Panel"}
            </h2>
            <p class="text-xs text-base-content/70">
              Write the panel query, preview its output, then choose one of the compatible visualizations and bind fields.
            </p>
          </div>
          <button type="button" class="btn btn-sm btn-ghost" phx-click="cancel_panel_edit">
            <.icon name="hero-x-mark" class="size-4" /> Close
          </button>
        </div>

        <div class="overflow-y-auto bg-base-200/40 p-4">
          <.form
            for={@panel_form}
            as={:panel}
            phx-change="validate_panel"
            phx-submit="submit_panel_form"
            class="grid grid-cols-1 gap-4 lg:grid-cols-2"
          >
            <.panel_form_fields
              form={@panel_form}
              panel={CanvasState.editing_panel(@dashboard, @editing_panel_id)}
              preview={@panel_preview}
              panel_results={@panel_results}
            />
          </.form>

          <div
            :if={@editing_panel_id != "new"}
            class="mt-4 flex flex-wrap items-center gap-2 rounded-lg border border-base-300 bg-base-100 p-3"
          >
            <button
              type="button"
              class="btn btn-sm"
              phx-click="duplicate_panel"
              phx-value-id={@editing_panel_id}
            >
              <.icon name="hero-document-duplicate" class="size-4" /> Duplicate
            </button>
            <button
              type="button"
              class="btn btn-sm btn-error btn-outline"
              phx-click="delete_panel"
              phx-value-id={@editing_panel_id}
            >
              <.icon name="hero-trash" class="size-4" /> Delete
            </button>
            <form
              phx-change="clone_target"
              phx-submit="clone_panel"
              class="ml-auto flex flex-wrap items-center gap-2"
            >
              <input type="hidden" name="panel_id" value={@editing_panel_id} />
              <select
                name="target_dashboard_id"
                class="select select-sm"
                disabled={@clone_targets == []}
              >
                <option
                  :for={target <- @clone_targets}
                  value={target.id}
                  selected={target.id == @clone_target_id}
                >
                  {target.title}
                </option>
              </select>
              <button type="submit" class="btn btn-sm" disabled={@clone_targets == []}>
                <.icon name="hero-arrow-up-on-square-stack" class="size-4" /> Clone
              </button>
            </form>
          </div>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_panel_edit">close</button>
      </form>
    </dialog>
    """
  end
end
