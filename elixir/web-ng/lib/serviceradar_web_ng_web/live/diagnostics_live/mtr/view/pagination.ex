defmodule ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View.Pagination do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Params

  attr(:page, :integer, required: true)
  attr(:limit, :integer, required: true)
  attr(:total_count, :integer, required: true)
  attr(:query, :string, default: "")
  attr(:filter_target, :string, default: "")
  attr(:filter_agent, :string, default: "")

  def render(assigns) do
    total_pages = max(1, ceil(assigns.total_count / max(assigns.limit, 1)))
    has_prev = assigns.page > 1
    has_next = assigns.page < total_pages

    assigns =
      assigns
      |> assign(:total_pages, total_pages)
      |> assign(:has_prev, has_prev)
      |> assign(:has_next, has_next)
      |> assign(:prev_path, page_path(assigns, max(assigns.page - 1, 1)))
      |> assign(:next_path, page_path(assigns, min(assigns.page + 1, total_pages)))

    ~H"""
    <div class="flex items-center justify-between gap-3 border-t border-base-200 pt-4">
      <div class="sr-mtr-muted text-sm">
        {if @total_count > 0,
          do: "Showing page #{@page} of #{@total_pages} (#{@total_count} total)",
          else: "No results"}
      </div>
      <div class="join">
        <.link :if={@has_prev} patch={@prev_path} class="join-item btn btn-sm btn-outline">
          <.icon name="hero-chevron-left" class="size-4" /> Prev
        </.link>
        <button :if={!@has_prev} class="join-item btn btn-sm btn-outline" disabled>
          <.icon name="hero-chevron-left" class="size-4" /> Prev
        </button>
        <span class="join-item btn btn-sm btn-ghost pointer-events-none">
          {@page} / {@total_pages}
        </span>
        <.link :if={@has_next} patch={@next_path} class="join-item btn btn-sm btn-outline">
          Next <.icon name="hero-chevron-right" class="size-4" />
        </.link>
        <button :if={!@has_next} class="join-item btn btn-sm btn-outline" disabled>
          Next <.icon name="hero-chevron-right" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  defp page_path(assigns, page) do
    assigns.query
    |> Params.pagination_params(page, assigns.limit, assigns.filter_target, assigns.filter_agent)
    |> Params.patch_path()
  end
end
