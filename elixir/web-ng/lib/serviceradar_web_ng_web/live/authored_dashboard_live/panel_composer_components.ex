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
      class="sr-ui-modal sr-ui-modal-open"
      phx-window-keydown="cancel_panel_edit"
      phx-key="Escape"
      phx-hook="DialogTopLayer"
    >
      <div class="sr-ui-modal-box sr-ui-modal-box-2xl flex max-h-[90vh] flex-col overflow-hidden p-0">
        <div class="flex flex-col gap-3 border-b border-sr-line bg-sr-surface px-5 py-4 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-normal text-sr-brand">
              SRQL panel composer
            </p>
            <h2 class="mt-1 text-lg font-semibold tracking-normal">
              {if @editing_panel_id == "new", do: "Create New Panel", else: "Edit Panel"}
            </h2>
            <p class="text-xs text-sr-muted">
              Write the panel query, preview its output, then choose one of the compatible visualizations and bind fields.
            </p>
          </div>
          <.ui_button type="button" phx-click="cancel_panel_edit" size="sm" variant="ghost">
            <.icon name="hero-x-mark" class="size-4" /> Close
          </.ui_button>
        </div>

        <div class="overflow-y-auto bg-sr-subtle/40 p-4">
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
            class="mt-4 flex flex-wrap items-center gap-2 rounded-lg border border-sr-line bg-sr-surface p-3"
          >
            <.ui_button
              type="button"
              phx-click="duplicate_panel"
              phx-value-id={@editing_panel_id}
              size="sm"
              variant="neutral"
            >
              <.icon name="hero-document-duplicate" class="size-4" /> Duplicate
            </.ui_button>
            <.ui_button
              type="button"
              phx-click="delete_panel"
              phx-value-id={@editing_panel_id}
              size="sm"
              variant="outline"
            >
              <.icon name="hero-trash" class="size-4" /> Delete
            </.ui_button>
            <form
              phx-change="clone_target"
              phx-submit="clone_panel"
              class="ml-auto flex flex-wrap items-center gap-2"
            >
              <input type="hidden" name="panel_id" value={@editing_panel_id} />
              <select
                name="target_dashboard_id"
                class={ui_field_class(size: "sm")}
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
              <.ui_button type="submit" disabled={@clone_targets == []} size="sm" variant="neutral">
                <.icon name="hero-arrow-up-on-square-stack" class="size-4" /> Clone
              </.ui_button>
            </form>
          </div>
        </div>
      </div>
      <form phx-submit="cancel_panel_edit" class="sr-ui-modal-backdrop">
        <button type="submit">close</button>
      </form>
    </dialog>
    """
  end
end
