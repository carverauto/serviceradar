defmodule ServiceRadarWebNGWeb.NorthboundActionComponents do
  @moduledoc false
  use Phoenix.Component

  import ServiceRadarWebNGWeb.CoreComponents

  alias ServiceRadarWebNG.Northbound.ActionForm

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:subtitle, :string, required: true)
  attr(:form, :any, required: true)
  attr(:actions, :list, required: true)
  attr(:action, :map, default: nil)
  attr(:error, :string, default: nil)
  attr(:close_event, :string, required: true)
  attr(:change_event, :string, required: true)
  attr(:submit_event, :string, required: true)

  def northbound_action_modal(assigns) do
    action = assigns.action || List.first(assigns.actions)
    properties = if action, do: ActionForm.schema_properties(action), else: []
    required = if action, do: ActionForm.schema_required(action), else: MapSet.new()

    assigns =
      assigns
      |> assign(:action, action)
      |> assign(:properties, properties)
      |> assign(:required, required)

    ~H"""
    <dialog id={@id} class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click={@close_event}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </form>

        <div class="flex items-start gap-3">
          <div class="rounded-lg bg-primary/10 p-2">
            <.icon name="hero-play" class="size-5 text-primary" />
          </div>
          <div class="min-w-0 flex-1">
            <h3 class="text-lg font-semibold text-base-content">{@title}</h3>
            <p class="text-sm text-base-content/60">{@subtitle}</p>
          </div>
        </div>

        <div :if={@error} role="alert" class="alert alert-error mt-4">
          <.icon name="hero-exclamation-circle" class="size-5" />
          <span class="text-sm">{@error}</span>
        </div>

        <.form
          for={@form}
          id={"#{@id}-form"}
          phx-change={@change_event}
          phx-submit={@submit_event}
          class="mt-5 space-y-4"
        >
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Task</span>
            </label>
            <select name="action[action_id]" class="select select-bordered w-full">
              <%= for option <- @actions do %>
                <option value={option.id} selected={@action && option.id == @action.id}>
                  {option.label}
                </option>
              <% end %>
            </select>
          </div>

          <div :if={@action} class="rounded-lg border border-base-200 bg-base-200/30 p-3">
            <div class="flex flex-wrap items-center gap-2 text-xs">
              <span class="badge badge-ghost badge-sm">{@action.provider_name}</span>
              <span class={ActionForm.safety_badge_class(@action.safety_classification)}>
                {ActionForm.humanize(@action.safety_classification)}
              </span>
              <span :if={@action.requires_confirmation} class="badge badge-warning badge-sm">
                Confirmation required
              </span>
              <span class="badge badge-ghost badge-sm">{@action.timeout_seconds}s timeout</span>
            </div>
            <p
              :if={ActionForm.present_text?(@action.description)}
              class="mt-2 text-sm text-base-content/70"
            >
              {@action.description}
            </p>
          </div>

          <div :if={@properties != []} class="grid gap-4">
            <%= for {name, schema} <- @properties do %>
              <.northbound_action_field
                form={@form}
                name={name}
                schema={schema}
                required={MapSet.member?(@required, name)}
              />
            <% end %>
          </div>

          <div
            :if={@properties == []}
            class="rounded-lg border border-base-200 p-4 text-sm text-base-content/60"
          >
            This task does not require additional input.
          </div>

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click={@close_event}>Cancel</button>
            <button type="submit" class="btn btn-primary" disabled={is_nil(@action)}>
              <.icon name="hero-play" class="size-4" /> Create Invocation
            </button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click={@close_event}>close</button>
      </form>
    </dialog>
    """
  end

  attr(:form, :any, required: true)
  attr(:name, :string, required: true)
  attr(:schema, :map, required: true)
  attr(:required, :boolean, default: false)

  defp northbound_action_field(assigns) do
    type = ActionForm.schema_type(assigns.schema)
    enum_values = ActionForm.schema_enum(assigns.schema)

    assigns =
      assigns
      |> assign(:type, type)
      |> assign(:enum_values, enum_values)
      |> assign(:value, ActionForm.form_value(assigns.form, assigns.name))
      |> assign(:label, ActionForm.schema_title(assigns.name, assigns.schema))
      |> assign(:description, ActionForm.schema_description(assigns.schema))
      |> assign(:input_name, "action[input][#{assigns.name}]")

    ~H"""
    <div class="form-control">
      <label class="label">
        <span class="label-text font-medium">
          {@label}
          <span :if={@required} class="text-error">*</span>
        </span>
        <span :if={ActionForm.present_text?(@description)} class="label-text-alt text-base-content/50">
          {@description}
        </span>
      </label>

      <select
        :if={@enum_values != []}
        name={@input_name}
        class="select select-bordered w-full"
        required={@required}
      >
        <option value="">Select...</option>
        <%= for option <- @enum_values do %>
          <option value={option} selected={to_string(@value || "") == option}>{option}</option>
        <% end %>
      </select>

      <div :if={@enum_values == [] and @type == "boolean"} class="flex items-center gap-2">
        <input type="hidden" name={@input_name} value="false" />
        <input
          type="checkbox"
          name={@input_name}
          value="true"
          checked={@value in [true, "true", "on", "1", 1]}
          class="toggle toggle-primary"
        />
      </div>

      <textarea
        :if={@enum_values == [] and @type in ["object", "array"]}
        name={@input_name}
        class="textarea textarea-bordered min-h-28 w-full font-mono text-xs"
        required={@required}
        placeholder={if @type == "array", do: "[]", else: "{}"}
      >{ActionForm.json_textarea_value(@value, @type)}</textarea>

      <input
        :if={@enum_values == [] and @type not in ["boolean", "object", "array"]}
        type={ActionForm.html_input_type(@type)}
        name={@input_name}
        value={@value}
        class="input input-bordered w-full"
        required={@required}
      />
    </div>
    """
  end
end
