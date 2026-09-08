defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.VariableComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.DashboardVariables

  attr :dashboard, :any, required: true
  attr :values, :map, default: %{}

  def variable_bar(assigns) do
    assigns = assign(assigns, :variables, DashboardVariables.list(assigns.dashboard))

    ~H"""
    <section class="rounded-lg border border-sr-line bg-sr-surface px-4 py-3">
      <form phx-change="change_variable" class="flex flex-col gap-3 lg:flex-row lg:items-center">
        <div class="shrink-0">
          <h2 class="text-sm font-semibold">Dashboard Variables</h2>
          <p class="text-xs text-sr-muted">
            Values substitute into panel SRQL before execution.
          </p>
        </div>
        <div class="flex flex-1 flex-wrap gap-3">
          <label :for={variable <- @variables} class="flex flex-col gap-1.5 min-w-44">
            <span class="text-xs font-medium text-sr-ink">{variable.label}</span>
            <select
              :if={variable.options != []}
              name={"variables[#{variable.name}]"}
              class={ui_field_class(size: "sm")}
            >
              <option
                :for={option <- variable.options}
                value={option}
                selected={Map.get(@values, variable.name, variable.default) == option}
              >
                {option}
              </option>
            </select>
            <input
              :if={variable.options == []}
              name={"variables[#{variable.name}]"}
              class={ui_field_class(size: "sm")}
              value={Map.get(@values, variable.name, variable.default)}
            />
          </label>
        </div>
      </form>
    </section>
    """
  end
end
