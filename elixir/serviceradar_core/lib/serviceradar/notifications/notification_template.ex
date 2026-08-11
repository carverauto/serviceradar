defmodule ServiceRadar.Notifications.NotificationTemplate do
  @moduledoc """
  The subject and body rendered for one (alert class x payload format), with an
  optional provider-specific override tier.

  Implements the "NotificationTemplate Resource and Managed Defaults" and
  "Restricted Templating Language" requirements, and design D9.

  ## Why the selection key is (alert class x payload format)

  That pair is what actually determines the output. One incident renders as Slack
  blocks, as a plain-text email body, and as a PagerDuty v2 payload; and a
  capacity alert and a device-down alert want different words in each. Keying on
  the provider alone would force every provider to re-author every alert class.
  Keying on the alert class alone would emit Markdown into a JSON field.

  `provider_key` is the third, optional tier. `NULL` is the generic row for that
  `(alert_class, payload_format)` pair; a non-null row applies only to that
  provider and wins over the generic one. The uniqueness of the generic row is
  enforced by `notification_templates_selection_uidx`, which is declared `NULLS
  NOT DISTINCT` in the migration - under PostgreSQL's default `NULLS DISTINCT`
  semantics two generic rows for the same pair would both insert, and dispatch
  would be left breaking a tie it has no basis to break. The Ash identity mirrors
  that with `nils_distinct? false`, so the second write is rejected with a field
  error instead of a raw constraint violation.

  ## Templates are restricted substitution, never code (D9)

  `subject_template` and `body_template` are validated on every write by
  `ServiceRadar.Notifications.Template.Syntax`: whitelisted variable paths only,
  and exactly the filters `upper`, `lower`, `truncate`, `json`, `url_encode`,
  `iso8601`, `default`. No EEx, no conditionals, no loops, no code. Validation is
  at save time because a notification template is first exercised during an
  incident, and a template that only fails when the alert fires converts a page
  into silence at the worst possible moment.

  Note that `:html` is a legitimate `payload_format` - a destination format for
  email - which is a different thing from the `html` *key* that design D9 rejects
  in provider-supplied UI descriptors. Rendering escapes for the destination
  format; nothing here goes through `raw/1`.

  ## Managed defaults and operator overrides

  First-party templates ship with `managed: true`, a `template_version`, and a
  `template_fingerprint` over the shipped content, reconciled by the same seeder
  contract `ServiceRadar.Observability.RuleSeeder` uses for preset rules. The
  actions keep the two paths apart on purpose:

    * `:update` is the operator edit. It sets `managed` to `false`, permanently
      detaching the row from the seeder, so an upgrade cannot silently restore
      default wording an on-call team has learned to read.
    * `:reconcile_managed` is the seeder's write. It carries `managed`,
      `template_version`, and `template_fingerprint`, and the seeder applies it
      only when the row is still `managed` and its stored fingerprint still
      matches what was previously shipped.

  Rendering never fails for want of a row: `:resolve` returns `nil` when no
  operator template matches, and the renderer falls back to the shipped default
  for that `payload_format`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Notifications,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Notifications.Template.Syntax
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  # Templates are part of the routing surface: whoever may read and edit routes
  # and escalation policies may read and edit the words those routes send.
  @view_check {ActorHasPermission, permission: "notifications.routes.view"}
  @manage_check {ActorHasPermission, permission: "notifications.routes.manage"}

  @payload_formats [
    :slack_blocks,
    :discord_embed,
    :markdown,
    :plain,
    :html,
    :pagerduty_v2,
    :json
  ]

  @fields [
    :name,
    :alert_class,
    :payload_format,
    :provider_key,
    :subject_template,
    :body_template,
    :managed,
    :template_version,
    :template_fingerprint
  ]

  @selection_fields [:alert_class, :payload_format, :provider_key]
  @content_fields [:name, :subject_template, :body_template]
  @managed_fields [:managed, :template_version, :template_fingerprint]

  postgres do
    table "notification_templates"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names selection: "notification_templates_selection_uidx"
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "notification_template_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]

    define :get_by_selection,
      action: :by_selection,
      args: [:alert_class, :payload_format, :provider_key],
      not_found_error?: false

    define :resolve_template,
      action: :resolve,
      args: [:alert_class, :payload_format, :provider_key],
      not_found_error?: false

    define :list_managed, action: :managed
    define :create_template, action: :create
    define :create_managed_template, action: :create_managed
    define :update_template, action: :update
    define :reconcile_managed_template, action: :reconcile_managed
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false

      get? true
      filter expr(id == ^arg(:id))
      prepare build(select: [:id, :inserted_at, :updated_at | @fields])
    end

    # Exact selection-key lookup, including the generic row. `provider_key` is
    # compared with an explicit nil branch because SQL `= NULL` is never true and
    # the generic row is exactly the row whose provider_key is NULL.
    read :by_selection do
      argument :alert_class, :string, allow_nil?: false

      argument :payload_format, :atom do
        allow_nil? false
        constraints one_of: @payload_formats
      end

      argument :provider_key, :string, allow_nil?: true

      get? true

      filter expr(
               alert_class == ^arg(:alert_class) and
                 payload_format == ^arg(:payload_format) and
                 ((is_nil(provider_key) and is_nil(^arg(:provider_key))) or
                    provider_key == ^arg(:provider_key))
             )

      prepare build(select: [:id, :inserted_at, :updated_at | @fields])
    end

    # Rendering resolution: the provider-specific row wins over the generic one.
    # Sorting provider_key ascending with nils last puts the specific row first,
    # and the filter admits at most those two rows.
    read :resolve do
      argument :alert_class, :string, allow_nil?: false

      argument :payload_format, :atom do
        allow_nil? false
        constraints one_of: @payload_formats
      end

      argument :provider_key, :string, allow_nil?: true

      get? true

      filter expr(
               alert_class == ^arg(:alert_class) and
                 payload_format == ^arg(:payload_format) and
                 (is_nil(provider_key) or provider_key == ^arg(:provider_key))
             )

      prepare build(
                select: [:id, :inserted_at, :updated_at | @fields],
                sort: [provider_key: :asc_nils_last],
                limit: 1
              )
    end

    read :managed do
      filter expr(managed == true)

      prepare build(
                select: [:id, :inserted_at, :updated_at | @fields],
                sort: [alert_class: :asc, payload_format: :asc]
              )
    end

    # Operator-authored template. It is unmanaged from birth: the seeder owns
    # only rows it created.
    create :create do
      accept @selection_fields ++ @content_fields
      change set_attribute(:managed, false)
    end

    # Seeder-authored first-party default.
    create :create_managed do
      accept @selection_fields ++ @content_fields ++ @managed_fields
    end

    # Operator edit. Clearing `managed` is the whole point: an edited template is
    # operator-owned from here on, and an upgrade must not overwrite it.
    update :update do
      accept @content_fields
      change set_attribute(:managed, false)
    end

    # Seeder reconciliation. The decision of *whether* to reconcile (still
    # managed, fingerprint still matching the previously shipped content) belongs
    # to the seeder; this action is the write it performs once it has decided.
    update :reconcile_managed do
      accept @content_fields ++ @managed_fields
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :by_selection, :resolve, :managed], @view_check)
    action_type_with_permission([:create, :update, :destroy], @manage_check)

    action_with_permission(
      [:create, :create_managed, :update, :reconcile_managed],
      @manage_check
    )
  end

  validations do
    validate {Syntax, attribute: :subject_template}
    validate {Syntax, attribute: :body_template}
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true

    attribute :alert_class, :string do
      allow_nil? false
      public? true
      default "default"
      description "Alert class this template renders; \"default\" is the catch-all"
    end

    attribute :payload_format, :atom do
      allow_nil? false
      public? true
      constraints one_of: @payload_formats

      description """
      Destination payload format. Constrained to the published set so operator
      and API input is cast against a fixed list rather than through
      String.to_atom/1.
      """
    end

    attribute :provider_key, :string do
      allow_nil? true
      public? true

      description """
      Provider this template is specific to. NULL is the generic row for the
      (alert_class, payload_format) pair and is what renders when no
      provider-specific row exists.
      """
    end

    attribute :subject_template, :string do
      allow_nil? true
      public? true
      description "Restricted-substitution subject; nil for formats with no subject"
    end

    attribute :body_template, :string do
      allow_nil? false
      public? true
      description "Restricted-substitution body"
    end

    attribute :managed, :boolean do
      allow_nil? false
      public? true
      default false
      description "True while the row is still owned by the first-party seeder"
    end

    attribute :template_version, :string, allow_nil?: true, public?: true
    attribute :template_fingerprint, :string, allow_nil?: true, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # Backed by notification_templates_selection_uidx, which is NULLS NOT
    # DISTINCT; nils_distinct? false is what keeps the Ash identity honest about
    # the generic (provider_key IS NULL) row being unique.
    identity :selection, @selection_fields, nils_distinct?: false
  end
end
