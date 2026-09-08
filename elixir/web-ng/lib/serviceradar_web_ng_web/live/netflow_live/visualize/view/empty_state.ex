defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.View.EmptyState do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.NetflowLive.ChartState

  def effective(srql, state) do
    ChartState.disabled_from_srql(srql) || state
  end

  attr :state, :map, required: true

  def render(assigns) do
    ~H"""
    <div
      data-testid={"netflow-chart-empty-#{@state.kind}"}
      class={[
        "min-h-72 w-full rounded-lg border px-5 py-6 flex items-center justify-center text-center",
        state_class(@state.kind)
      ]}
    >
      <div class="max-w-md space-y-3">
        <.icon name={state_icon(@state.kind)} class="mx-auto size-7" />
        <div class="space-y-1">
          <div class="text-sm font-semibold">{@state.title}</div>
          <p class="text-xs leading-5 text-sr-ink/65">{@state.detail}</p>
        </div>
        <.ui_button
          :if={is_binary(@state.link_href) and is_binary(@state.link_label)}
          navigate={@state.link_href}
          size="xs"
          variant="outline"
        >
          {@state.link_label}
        </.ui_button>
      </div>
    </div>
    """
  end

  def state_class(:query_error), do: "border-error/30 bg-error/5 text-error"
  def state_class(:disabled), do: "border-warning/30 bg-warning/5 text-warning"
  def state_class(_kind), do: "border-sr-line bg-sr-subtle/20 text-sr-ink"

  def state_icon(:query_error), do: "hero-exclamation-triangle"
  def state_icon(:disabled), do: "hero-pause-circle"
  def state_icon(_kind), do: "hero-circle-stack"
end
