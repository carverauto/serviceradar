defmodule ServiceRadarWebNGWeb.Api.NotificationActionHTML do
  @moduledoc """
  The three pages `ServiceRadarWebNGWeb.Api.NotificationActionController`
  renders: the confirmation interstitial, the outcome of a redemption, and the
  one opaque failure.

  Every value that reaches these templates is escaped by HEEx. Alert titles are
  operator- and integration-authored text arriving on an unauthenticated page,
  so nothing here goes through `raw/1` and nothing is interpolated into an
  attribute that is not a route.

  The failure page takes a reason of `:expired` or `:invalid` and renders one
  paragraph for each. That two-answer vocabulary is
  `ServiceRadar.Notifications.ActionToken.public_reason/1`'s, and widening it
  here - "no such token", "wrong action" - would turn the endpoint into a way to
  enumerate deliveries.
  """

  use ServiceRadarWebNGWeb, :html

  @doc """
  The confirmation page. A GET renders this and changes nothing; the form is
  what redeems.
  """
  attr :submit_path, :string, required: true
  attr :action, :atom, required: true
  attr :snooze_seconds, :integer, default: nil
  attr :alert, :map, default: nil

  def interstitial(assigns) do
    ~H"""
    <.page_frame eyebrow="Confirm action" title={action_title(@action, @snooze_seconds)}>
      <.alert_summary alert={@alert} />

      <p class="text-sm leading-6 text-sr-muted">
        {action_prompt(@action, @snooze_seconds)}
      </p>

      <form method="post" action={@submit_path} class="mt-6">
        <.ui_button type="submit" variant="primary" size="md" class="w-full">
          {action_verb(@action, @snooze_seconds)}
        </.ui_button>
      </form>

      <p class="mt-4 text-xs leading-5 text-sr-muted">
        This link works once. Opening this page did not change anything.
      </p>
    </.page_frame>
    """
  end

  @doc "What a redemption did."
  attr :outcome, :atom, required: true
  attr :action, :atom, default: nil
  attr :snooze_until, :any, default: nil
  attr :alert, :map, default: nil

  def result(assigns) do
    ~H"""
    <.page_frame
      eyebrow={outcome_eyebrow(@outcome)}
      title={outcome_title(@outcome, @action, @snooze_until)}
    >
      <.alert_summary alert={@alert} />

      <p class="text-sm leading-6 text-sr-muted">
        {outcome_detail(@outcome)}
      </p>

      <.open_link alert={@alert} />
    </.page_frame>
    """
  end

  @doc """
  The one failure page. `:expired` and `:invalid` are the only reasons that
  reach it.
  """
  attr :reason, :atom, required: true

  def failure(assigns) do
    ~H"""
    <.page_frame eyebrow="Link unavailable" title={failure_title(@reason)}>
      <p class="text-sm leading-6 text-sr-muted">
        {failure_detail(@reason)}
      </p>

      <p class="mt-4 text-xs leading-5 text-sr-muted">
        Nothing was changed. Sign in to ServiceRadar to act on the alert.
      </p>
    </.page_frame>
    """
  end

  # --- shared frame ---------------------------------------------------------

  attr :eyebrow, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp page_frame(assigns) do
    ~H"""
    <main class="mx-auto flex min-h-[70vh] w-full max-w-lg items-center px-6 py-16">
      <.ui_panel class="w-full" body_class="px-6 py-7">
        <p class="text-xs font-semibold uppercase tracking-[0.24em] text-sr-brand">
          {@eyebrow}
        </p>
        <h1 class="mt-2 text-2xl font-semibold tracking-tight text-sr-ink">{@title}</h1>

        <div class="mt-6">
          {render_slot(@inner_block)}
        </div>
      </.ui_panel>
    </main>
    """
  end

  attr :alert, :map, default: nil

  defp alert_summary(assigns) do
    ~H"""
    <div :if={@alert} class="mb-6 rounded-sr-control border border-sr-line bg-sr-subtle/60 px-4 py-3">
      <div class="flex items-start justify-between gap-3">
        <p class="min-w-0 text-sm font-semibold text-sr-ink">{@alert.title}</p>
        <.ui_badge variant={badge_variant_for(@alert.severity)} size="xs">
          {severity_label(@alert.severity)}
        </.ui_badge>
      </div>
      <p :if={@alert.triggered_at} class="mt-1 text-xs text-sr-muted">
        Triggered {format_timestamp(@alert.triggered_at)}
      </p>
    </div>
    """
  end

  attr :alert, :map, default: nil

  defp open_link(assigns) do
    ~H"""
    <div :if={@alert && @alert.id} class="mt-6">
      <.ui_button href={~p"/alerts/#{@alert.id}"} variant="outline" size="sm">
        Open in ServiceRadar
      </.ui_button>
    </div>
    """
  end

  # --- copy -----------------------------------------------------------------

  defp action_title(:acknowledge, _seconds), do: "Acknowledge this alert?"
  defp action_title(:resolve, _seconds), do: "Resolve this alert?"
  defp action_title(:snooze, seconds), do: "Snooze this alert for #{duration_label(seconds)}?"
  defp action_title(_action, _seconds), do: "Confirm this action?"

  defp action_verb(:acknowledge, _seconds), do: "Acknowledge"
  defp action_verb(:resolve, _seconds), do: "Resolve"
  defp action_verb(:snooze, seconds), do: "Snooze for #{duration_label(seconds)}"
  defp action_verb(_action, _seconds), do: "Confirm"

  defp action_prompt(:acknowledge, _seconds) do
    "Acknowledging tells everyone on call that you have taken this alert, and stops it escalating."
  end

  defp action_prompt(:resolve, _seconds) do
    "Resolving closes this alert. Reopen it from ServiceRadar if the condition returns."
  end

  defp action_prompt(:snooze, seconds) do
    "Snoozing holds further notifications for #{duration_label(seconds)}. Escalation resumes after that unless someone acknowledges."
  end

  defp action_prompt(_action, _seconds), do: "Confirm to apply this action."

  defp outcome_eyebrow(:applied), do: "Done"
  defp outcome_eyebrow(:already_applied), do: "Already done"
  defp outcome_eyebrow(:replayed), do: "Link already used"
  defp outcome_eyebrow(_outcome), do: "No change"

  defp outcome_title(:applied, :acknowledge, _until), do: "Alert acknowledged"
  defp outcome_title(:applied, :resolve, _until), do: "Alert resolved"

  defp outcome_title(:applied, :snooze, %DateTime{} = until), do: "Alert snoozed until #{format_timestamp(until)}"

  defp outcome_title(:applied, :snooze, _until), do: "Alert snoozed"
  defp outcome_title(:applied, _action, _until), do: "Action applied"

  defp outcome_title(:already_applied, :acknowledge, _until), do: "Already acknowledged"
  defp outcome_title(:already_applied, :resolve, _until), do: "Already resolved"
  defp outcome_title(:already_applied, _action, _until), do: "Already applied"

  defp outcome_title(:replayed, _action, _until), do: "This link has already been used"
  defp outcome_title(_outcome, _action, _until), do: "Nothing was changed"

  defp outcome_detail(:applied) do
    "Recorded against this notification. You can close this page."
  end

  defp outcome_detail(:already_applied) do
    "Someone got here first. Your action was recorded, and the alert was left as it was."
  end

  defp outcome_detail(:replayed) do
    "The action it carried was applied the first time it was opened. Nothing happened just now."
  end

  defp outcome_detail(_outcome) do
    "This alert can no longer be changed from a notification link. Open it in ServiceRadar to see where it stands."
  end

  defp failure_title(:expired), do: "This link has expired"
  defp failure_title(_reason), do: "This link is not valid"

  defp failure_detail(:expired) do
    "Action links stay usable for a few days so they cannot outlive the alert they act on."
  end

  defp failure_detail(_reason) do
    "It may have been altered in transit, or the notification it came from is no longer available."
  end

  # --- formatting -----------------------------------------------------------

  defp severity_label(severity) when is_atom(severity) do
    severity |> Atom.to_string() |> String.capitalize()
  end

  defp severity_label(_severity), do: "Unknown"

  defp duration_label(seconds) when is_integer(seconds) and seconds >= 86_400 do
    pluralize(div(seconds, 86_400), "day")
  end

  defp duration_label(seconds) when is_integer(seconds) and seconds >= 3_600 do
    pluralize(div(seconds, 3_600), "hour")
  end

  defp duration_label(seconds) when is_integer(seconds) and seconds >= 60 do
    pluralize(div(seconds, 60), "minute")
  end

  defp duration_label(seconds) when is_integer(seconds) and seconds > 0 do
    pluralize(seconds, "second")
  end

  defp duration_label(_seconds), do: "a while"

  defp pluralize(1, unit), do: "1 #{unit}"
  defp pluralize(count, unit), do: "#{count} #{unit}s"

  defp format_timestamp(%DateTime{} = at) do
    at |> DateTime.truncate(:second) |> DateTime.to_string()
  end

  defp format_timestamp(_at), do: ""
end
