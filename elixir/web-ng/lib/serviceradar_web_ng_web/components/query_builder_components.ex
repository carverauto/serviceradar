defmodule ServiceRadarWebNGWeb.QueryBuilderComponents do
  @moduledoc false

  use Phoenix.Component

  import ServiceRadarWebNGWeb.CoreComponents, only: [icon: 1]

  slot :inner_block, required: true
  attr :label, :string, required: true
  attr :root, :boolean, default: false

  def query_builder_pill(assigns) do
    ~H"""
    <div class="relative">
      <div :if={not @root} class="absolute -left-10 top-1/2 h-0.5 w-10 bg-sr-brand/30" />
      <div class="inline-flex items-center gap-2 rounded-md border border-sr-line bg-sr-surface px-3 py-2">
        <.icon name="hero-check-mini" class="size-4 text-success opacity-80" />
        <span class="text-xs text-sr-muted">{@label}</span>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
