defmodule ServiceRadarWebNGWeb.ServiceLive.Index.Summary do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  attr :summary, :map, required: true
  attr :has_filter, :boolean, default: false
  attr :timezone, :string, required: true

  def render(assigns) do
    total = assigns.summary.total
    available = assigns.summary.available
    unavailable = assigns.summary.unavailable
    check_count = Map.get(assigns.summary, :check_count, 0)
    last_updated = Map.get(assigns.summary, :last_updated)
    availability_percent = if total > 0, do: round(available / total * 100), else: 0

    assigns =
      assigns
      |> assign(:active_label, "active plugin services")
      |> assign(:total, total)
      |> assign(:available, available)
      |> assign(:unavailable, unavailable)
      |> assign(:availability_percent, availability_percent)
      |> assign(:check_count, check_count)
      |> assign(:last_updated, last_updated)

    ~H"""
    <div class="flex items-center justify-between text-xs text-sr-muted">
      <div>Latest plugin check per service</div>
      <div :if={@last_updated}>
        Last updated
        <.user_time
          id="service-summary-last-updated"
          value={@last_updated}
          timezone={@timezone}
          style={:full}
        />
      </div>
    </div>

    <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
      <div class="rounded-xl border border-sr-line bg-sr-surface p-4">
        <div class="flex items-center justify-between">
          <div>
            <div class="text-xs text-sr-muted uppercase tracking-wider mb-1">
              Services
            </div>
            <div class="text-2xl font-bold">{@total}</div>
            <div class="text-xs text-sr-muted">{@active_label}</div>
          </div>
          <div class="size-12 rounded-lg bg-sr-subtle/50 flex items-center justify-center">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="size-6 text-sr-muted"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
              />
            </svg>
          </div>
        </div>
      </div>

      <div class="rounded-xl border border-sr-line bg-sr-surface p-4">
        <div class="flex items-center justify-between">
          <div>
            <div class="text-xs text-sr-muted uppercase tracking-wider mb-1">Available</div>
            <div class="text-2xl font-bold text-success">{@available}</div>
            <div class="text-xs text-sr-muted">{@availability_percent}% healthy</div>
          </div>
          <div class="size-12 rounded-lg bg-success/10 flex items-center justify-center">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="size-6 text-success"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M5 13l4 4L19 7"
              />
            </svg>
          </div>
        </div>
      </div>

      <div class="rounded-xl border border-sr-line bg-sr-surface p-4">
        <div class="flex items-center justify-between">
          <div>
            <div class="text-xs text-sr-muted uppercase tracking-wider mb-1">Unavailable</div>
            <div class={["text-2xl font-bold", @unavailable > 0 && "text-error"]}>
              {@unavailable}
            </div>
            <div class="text-xs text-sr-muted">{100 - @availability_percent}% failing</div>
          </div>
          <div class={[
            "size-12 rounded-lg flex items-center justify-center",
            @unavailable > 0 && "bg-error/10",
            @unavailable == 0 && "bg-sr-subtle/50"
          ]}>
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class={[
                "size-6",
                @unavailable > 0 && "text-error",
                @unavailable == 0 && "text-sr-muted"
              ]}
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M6 18L18 6M6 6l12 12"
              />
            </svg>
          </div>
        </div>
      </div>
    </div>

    <div class="mt-2 text-xs text-sr-muted">
      Showing {max(@check_count, @total)} plugin checks sampled.
    </div>
    """
  end
end
