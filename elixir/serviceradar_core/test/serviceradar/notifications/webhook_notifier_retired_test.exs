defmodule ServiceRadar.Notifications.WebhookNotifierRetiredTest do
  @moduledoc """
  `ServiceRadar.Monitoring.WebhookNotifier` is gone, and stays gone.

  Design D8's "dead code disposition" removes it because leaving it in place is
  what lets a future implementer wire an alert back into a path that returns
  `{:error, :not_running}`. No supervision tree ever started that GenServer, so
  every `send_alert/1` call in its entire history took the `:noproc` branch and
  delivered nothing - which also means a reintroduced call would look correct in
  review, compile, run, log a warning, and page no one.

  Review cannot be the gate for that, so this is. Three assertions, because each
  catches a different way it could come back:

    * the source file - a restored `webhook_notifier.ex`;
    * the loadable module - one resurrected under the same name from anywhere
      else;
    * a source scan of `lib/` for a CALL rather than a mention - prose
      references survive deliberately (the `generic_webhook` transport documents
      the config migration off the old `webhooks:` block, and `RateLimiter`
      documents why its budget is durable instead of in-process), so the pattern
      matches `WebhookNotifier.fun(` and `%WebhookNotifier.Struct{` and nothing
      that merely names the module.

  Pure: it reads files and asks the code server. No repo, no Ash, no application
  start.
  """
  use ExUnit.Case, async: true

  @module ServiceRadar.Monitoring.WebhookNotifier
  @source Path.expand("../../../lib/serviceradar/monitoring/webhook_notifier.ex", __DIR__)
  @lib_root Path.expand("../../../lib", __DIR__)

  # A call site, not a mention. `WebhookNotifier.send_alert(` and
  # `%WebhookNotifier.Alert{` match; a backticked name in a moduledoc does not.
  @call_pattern ~r/WebhookNotifier\.[A-Za-z_][A-Za-z0-9_]*\s*[({]/

  test "the module and its source file no longer exist" do
    refute File.exists?(@source),
           "#{@source} is back; the alert path must not gain a second, unsupervised notifier"

    # Anti-vacuity control, and the reason it is a sibling: an empty or
    # misrooted code path would make the refutation below pass for entirely the
    # wrong reason. `AlertGenerator` is the module the retired notifier used to
    # be called from, so if it is loadable the code path is real.
    assert Code.ensure_loaded?(ServiceRadar.Monitoring.AlertGenerator),
           "the code path is not loaded, so the next assertion proves nothing"

    refute Code.ensure_loaded?(@module),
           "#{inspect(@module)} is loadable again"
  end

  test "nothing under lib/ calls it" do
    callers =
      @lib_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(fn path -> File.read!(path) =~ @call_pattern end)
      |> Enum.map(&Path.relative_to(&1, @lib_root))

    assert callers == [],
           "these modules call the retired WebhookNotifier: #{Enum.join(callers, ", ")}"
  end
end
