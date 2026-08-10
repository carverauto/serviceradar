defmodule ServiceRadar.Notifications.TemplateSeeder do
  @moduledoc """
  Seeds the managed `ServiceRadar.Notifications.NotificationTemplate` defaults
  (tasks 1.1.13a, 1.1.13b).

  `Notifications.Renderer` requires a body template: with no row for the
  negotiated payload format it answers `{:missing_body_template, format}` and the
  dispatch fails. So every payload format the platform renders needs a resolvable
  managed default for the catch-all `"default"` alert class, or an alert class
  nobody wrote a template for renders nothing at the moment it matters most.

  All seven formats are seeded, not only the ones the launch providers declare.
  `:pagerduty_v2` has no first-party `:native` provider in Phase 1, but the
  `:declarative` catalog reaches PagerDuty Events API v2 in Phase 2 and a
  declarative provider brings no templates of its own - it would land on a format
  with no default and render nothing.

  Rows are generic: `provider_key` is `nil`, which is the row
  `NotificationTemplate`'s `:resolve` read falls back to when no
  provider-specific row exists. A provider-specific row would only shadow these,
  and shipping one would be shipping a decision an operator has not made.

  ## Operator edits survive an upgrade

  Templates carry `managed` / `template_version` / `template_fingerprint` and are
  reconciled through `ServiceRadar.Notifications.SeedFingerprint`, the same
  contract `ServiceRadar.Observability.RuleSeeder` uses for preset rules: a
  managed row whose stored fingerprint still matches what the seeder last wrote
  is advanced to the current template, and one whose content was changed is left
  alone and logged.

  There is one deliberate difference from the provider seeder, which DOES adopt
  an unmanaged row whose content already matches the shipped template.
  `NotificationTemplate`'s `:update` action sets `managed` to `false`, so on a
  template `managed: false` is a positive record that an operator edited this
  row - the resource documents that as permanently detaching it from the seeder.
  Adopting it back would re-attach a row the operator's own edit detached, so
  this seeder never adopts; it skips and logs. On a provider, `:update` leaves
  `managed` alone, so an unmanaged provider row carries no such record and the
  pristine-adoption path is safe there.

  ## Restricted substitution only

  Every template here is written in the restricted language
  `ServiceRadar.Notifications.Template.Syntax` validates: whitelisted variable
  paths and the seven filters `upper`, `lower`, `truncate`, `json`, `url_encode`,
  `iso8601`, `default`. A path outside the published catalog renders as an empty
  string - the save-time validator exists precisely to stop that - so the seeded
  templates use exact catalog entries only, never an open namespace, and a test
  asserts it rather than trusting review.

  Every substitution carries a `default:` fallback. That is not decoration:
  `Renderer.Rendered.unresolved?/1` reports a variable that rendered empty with
  no default, and a shipped default that fires that on every alert with no device
  would train operators to ignore the signal that catches a real typo.

  ## Why the bodies differ per format

  The selection key is (alert class x payload format) because that pair is what
  decides the output. `*bold*` is Slack mrkdwn and `**bold**` is Markdown; HTML
  wants markup, and the `:json` body must deliberately NOT parse as a JSON object
  or `Renderers.Json` would treat it as the payload document instead of wrapping
  it in the stable ServiceRadar envelope.

  Severity, alert class, source, dedupe key, and the action links are added by
  the per-format renderer from the alert snapshot, so no body repeats them.

  See `openspec/changes/add-notification-platform/design.md` (D9).
  """

  use ServiceRadar.DelayedSeeder, delay_ms: 6_000, callback: :seed_all

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Notifications.NotificationTemplate
  alias ServiceRadar.Notifications.SeedFingerprint

  require Ash.Query
  require Logger

  # The seeder-owned fields, matching `NotificationTemplate`'s content fields.
  # The selection key is identity, not content, and is never reconciled.
  @managed_fields [:name, :subject_template, :body_template]

  @template_version "1"

  @doc """
  The version stamped on every seeder-managed template.

  Deliberately independent of `ProviderSeeder.template_version/0`: a change to a
  provider's config schema has nothing to do with the default templates, and
  sharing one constant would reseed every template on an unrelated bump.
  """
  @spec template_version() :: String.t()
  def template_version, do: @template_version

  @default_alert_class "default"

  @doc "The seeder-owned attribute set covered by the divergence fingerprint."
  @spec managed_fields() :: [atom()]
  def managed_fields, do: @managed_fields

  @doc false
  @spec seed_all() :: :ok | nil
  def seed_all do
    if repo_enabled?() do
      seed_templates()
    end
  end

  @doc """
  Reconciles the managed template defaults. Idempotent.
  """
  @spec seed_templates() :: :ok
  def seed_templates do
    opts = [actor: SystemActor.system(:notification_template_seeder)]

    case Ash.read(Ash.Query.for_read(NotificationTemplate, :read, %{}), opts) do
      {:ok, templates} ->
        existing = Map.new(templates, &{selection_key(&1), &1})
        Enum.each(default_templates(), &reconcile_or_create(existing, &1, opts))
        :ok

      {:error, reason} ->
        Logger.warning("Failed to read notification templates for seeding: #{inspect(reason)}")
        :ok
    end
  end

  defp selection_key(template) do
    {template.alert_class, template.payload_format, template.provider_key}
  end

  # --- reconciliation --------------------------------------------------------

  defp reconcile_or_create(existing, attrs, opts) do
    case Map.get(existing, selection_key(attrs)) do
      nil -> create_template(attrs, opts)
      template -> reconcile_template(template, attrs, opts)
    end
  end

  defp create_template(attrs, opts) do
    create_attrs = Map.put(attrs, :template_fingerprint, fingerprint(attrs))

    changeset =
      Ash.Changeset.for_create(NotificationTemplate, :create_managed, create_attrs, opts)

    case Ash.create(changeset) do
      {:ok, _template} ->
        Logger.info("Seeded notification template #{attrs.name}")

      {:error, reason} ->
        Logger.warning("Failed to seed notification template #{attrs.name}: #{inspect(reason)}")
    end
  end

  defp reconcile_template(template, attrs, opts) do
    cond do
      not template.managed ->
        Logger.info(
          "Skipping notification template #{template.name}: the row is operator-owned, " <>
            "either authored or detached by an edit"
        )

      template.template_version == attrs.template_version ->
        :ok

      SeedFingerprint.diverged?(template, @managed_fields) ->
        Logger.info(
          "Skipping managed notification template #{template.name}: content diverges from " <>
            "template v#{template.template_version}"
        )

      true ->
        update_managed(template, attrs, opts)
    end
  end

  defp update_managed(template, attrs, opts) do
    update_attrs =
      attrs
      |> Map.take([:template_version | @managed_fields])
      |> Map.put(:managed, true)
      |> Map.put(:template_fingerprint, fingerprint(attrs))

    changeset = Ash.Changeset.for_update(template, :reconcile_managed, update_attrs, opts)

    case Ash.update(changeset) do
      {:ok, updated} ->
        Logger.info(
          "Reconciled notification template #{template.name} to v#{updated.template_version}"
        )

      {:error, reason} ->
        Logger.warning(
          "Failed to reconcile notification template #{template.name}: #{inspect(reason)}"
        )
    end
  end

  defp fingerprint(attrs), do: SeedFingerprint.fingerprint(attrs, @managed_fields)

  # --- the catalog -----------------------------------------------------------

  @doc """
  The managed template defaults, as attribute maps, one per payload format.

  Public because the seeder tests validate every body against
  `ServiceRadar.Notifications.Template.Syntax` and check every variable path
  against the published catalog. A template that only fails when an alert fires
  is the exact failure the save-time validator exists to prevent, and asserting
  it here is what keeps that promise for the rows a release ships.
  """
  @spec default_templates() :: [map()]
  def default_templates do
    [
      template(:slack_blocks, "Default alert (Slack Block Kit)", slack_blocks_body()),
      template(:discord_embed, "Default alert (Discord embed)", markdown_body()),
      template(:markdown, "Default alert (Markdown)", markdown_body()),
      template(:plain, "Default alert (plain text)", plain_body()),
      template(:html, "Default alert (HTML)", html_body()),
      template(:pagerduty_v2, "Default alert (PagerDuty Events v2)", plain_body()),
      template(:json, "Default alert (JSON)", plain_body())
    ]
  end

  defp template(payload_format, name, body) do
    %{
      name: name,
      alert_class: @default_alert_class,
      payload_format: payload_format,
      provider_key: nil,
      subject_template: subject_template(),
      body_template: body,
      managed: true,
      template_version: @template_version
    }
  end

  # One subject for every format. It is the Slack header, the Discord embed
  # title, the mail Subject: header, and the PagerDuty summary, so it stays on
  # one line and leads with the severity an on-call engineer triages on.
  defp subject_template do
    ~s([{{ alert.severity | upper | default: "UNKNOWN" }}] ) <>
      ~s({{ alert.title | default: "ServiceRadar alert" }})
  end

  # Slack renders `*single asterisks*` as bold; `**double**` shows the asterisks.
  defp slack_blocks_body do
    """
    {{ alert.message | default: "No further detail was reported." }}

    *Device:* {{ device.name | default: "unknown" }} ({{ device.ip | default: "no address" }})
    *Rule:* {{ alert.rule_name | default: "unknown" }}
    *Status:* {{ alert.status | default: "unknown" }}
    *Occurrences:* {{ alert.occurrence_count | default: 1 }}
    *First seen:* {{ alert.first_seen_at | iso8601 | default: "unknown" }}
    *Last seen:* {{ alert.last_seen_at | iso8601 | default: "unknown" }}\
    """
  end

  # Shared by `:markdown` and `:discord_embed`; a Discord embed description is
  # Markdown, and the embed's own fields already carry severity, class, and
  # source.
  defp markdown_body do
    """
    {{ alert.message | default: "No further detail was reported." }}

    **Device:** {{ device.name | default: "unknown" }} ({{ device.ip | default: "no address" }})
    **Rule:** {{ alert.rule_name | default: "unknown" }}
    **Status:** {{ alert.status | default: "unknown" }}
    **Occurrences:** {{ alert.occurrence_count | default: 1 }}
    **First seen:** {{ alert.first_seen_at | iso8601 | default: "unknown" }}
    **Last seen:** {{ alert.last_seen_at | iso8601 | default: "unknown" }}\
    """
  end

  # Also the `:pagerduty_v2` custom_details body and the `:json` envelope body.
  # For `:json` that is deliberate: `Renderers.Json` treats a body that parses as
  # a JSON object as the payload document itself, and a shipped default must not
  # silently replace the stable ServiceRadar envelope with an opinion about some
  # receiver's schema.
  defp plain_body do
    """
    {{ alert.message | default: "No further detail was reported." }}

    Device: {{ device.name | default: "unknown" }} ({{ device.ip | default: "no address" }})
    Rule: {{ alert.rule_name | default: "unknown" }}
    Status: {{ alert.status | default: "unknown" }}
    Occurrences: {{ alert.occurrence_count | default: 1 }}
    First seen: {{ alert.first_seen_at | iso8601 | default: "unknown" }}
    Last seen: {{ alert.last_seen_at | iso8601 | default: "unknown" }}\
    """
  end

  # The literal markup is the template's own; every substituted value is
  # HTML-escaped by `Renderers.Html`, so an alert title containing a tag renders
  # as text in an inbox.
  defp html_body do
    """
    <p>{{ alert.message | default: "No further detail was reported." }}</p>
    <table class="serviceradar-notification-facts">
    <tr><th align="left">Device</th><td>{{ device.name | default: "unknown" }}\
     ({{ device.ip | default: "no address" }})</td></tr>
    <tr><th align="left">Rule</th><td>{{ alert.rule_name | default: "unknown" }}</td></tr>
    <tr><th align="left">Status</th><td>{{ alert.status | default: "unknown" }}</td></tr>
    <tr><th align="left">Occurrences</th><td>{{ alert.occurrence_count | default: 1 }}</td></tr>
    <tr><th align="left">First seen</th>\
    <td>{{ alert.first_seen_at | iso8601 | default: "unknown" }}</td></tr>
    <tr><th align="left">Last seen</th>\
    <td>{{ alert.last_seen_at | iso8601 | default: "unknown" }}</td></tr>
    </table>\
    """
  end
end
