defmodule ServiceRadar.Repo.Migrations.AllowPagerdutyCallbackApps do
  @moduledoc """
  Widens the callback-app provider allowlist to admit PagerDuty (task 4.3.3).

  The constraint is a closed list on purpose - a row with an unrecognised
  provider_key is one nothing can ever resolve, sitting unnoticed in a credential
  table - so admitting a provider is a deliberate migration rather than a value
  an operator can invent.

  For PagerDuty, `external_app_id` holds the **webhook subscription id** that
  arrives in `X-Webhook-Subscription`, which is the analogue of Slack's
  `api_app_id`: one signing secret per subscription, named by the inbound
  request.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    drop_if_exists(
      constraint(:notification_callback_apps, :notification_callback_apps_provider_key,
        prefix: @prefix
      )
    )

    create(
      constraint(:notification_callback_apps, :notification_callback_apps_provider_key,
        check: "provider_key IN ('slack','pagerduty')",
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(
      constraint(:notification_callback_apps, :notification_callback_apps_provider_key,
        prefix: @prefix
      )
    )

    # serviceradar:allow-startup-maintenance - rollback-only, schema-critical
    # cleanup that never runs on first boot. The small operator-managed registry
    # must lose PagerDuty bindings before its Slack-only constraint is restored.
    execute("DELETE FROM platform.notification_callback_apps WHERE provider_key = 'pagerduty'")

    create(
      constraint(:notification_callback_apps, :notification_callback_apps_provider_key,
        check: "provider_key IN ('slack')",
        prefix: @prefix
      )
    )
  end
end
