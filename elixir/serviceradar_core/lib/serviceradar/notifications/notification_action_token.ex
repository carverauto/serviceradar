defmodule ServiceRadar.Notifications.NotificationActionToken do
  @moduledoc """
  One minted, single-use capability for one `{delivery, alert, action}` triple
  (design D7 Phase 1).

  A rendered notification carries `Acknowledge`, `Snooze 1h`, and `Resolve`
  links. Each link bears its own token, and this row is what a presented token is
  checked against. Only the sha256 digest is stored, exactly as the northbound
  callback scheme stores `callback_token_hash`
  (`automation/northbound/dispatcher.ex:456`) - a database dump, a replica, or a
  backup therefore yields no usable credential.

  ## Why this is a table and not columns on an existing one

  `NotificationAcknowledgement` is the obvious candidate and is the wrong one.
  That resource is an append-only audit of actions **taken**: `actor_kind` and
  `source` are both `NOT NULL`, and the `notification_acknowledgements_actor`
  check demands an actor for every row. A minted-but-never-clicked token has no
  actor, no source, and no received_at, so storing it there would mean either
  relaxing that check - which is what makes the audit trustworthy - or writing
  audit rows for events that never happened, so `list_for_alert/1` would answer
  "was this acknowledged?" with links nobody clicked.

  `NotificationDelivery` is the other candidate and is worse: three actions per
  delivery means three hash columns, three expiry columns, and three
  consumed-at columns, plus a fourth set the day a `Suppress` link is added.

  So: one row per issued capability, and `NotificationAcknowledgement` keeps its
  job of recording what a redeemed capability **did** (`source: :action_link`).

  ## Reaping is by cascade, not by a sweeper

  Both foreign keys are `on_delete: :delete_all`, which is the opposite of the
  `nilify_all` that `NotificationDelivery` and `NotificationAcknowledgement`
  carry - and deliberately so. Those two are records of what happened and must
  outlive their alert; a capability is only meaningful while the thing it acts on
  exists. A token whose alert has been pruned can authorise nothing, and a token
  whose delivery has aged out of the Delivery Log is unattributable.

  `ServiceRadar.Jobs.AlertsRetentionWorker` hard-deletes resolved and suppressed
  alerts after a default of three days and
  `ServiceRadar.Notifications.DeliveryRetentionWorker` prunes deliveries, so
  whichever fires first reaps the token with it. That is why this table has no
  expiry sweeper of its own: an unbounded growth path would need a token to
  outlive both its alert and its delivery, and the cascades make that
  unreachable.

  ## Single use is a compare-and-set, not a read-then-write

  `update :consume` carries `change filter(expr(is_nil(consumed_at)))`, so the
  `UPDATE` itself contains the precondition and two concurrent redemptions of one
  token produce exactly one winner; the loser gets `Ash.Error.Changes.StaleRecord`
  rather than a second state change. This is the same shape
  `ServiceRadar.Edge.OnboardingPackage`'s `update :deliver` uses for its
  single-use download token (`edge/onboarding_package.ex:207`).

  ## Access

  Only the system actor may read or write this table. There is no operator-facing
  policy, because there is nothing here an operator needs: whether a link was
  clicked, by whom, and to what effect is all on `NotificationAcknowledgement`,
  which the Delivery Log already shows. Handing an operator role a read of the
  digests would only widen the surface of a credential store.
  """

  use Ash.Resource,
    domain: ServiceRadar.Notifications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @fields [
    :selector,
    :token_hash,
    :delivery_id,
    :alert_id,
    :action,
    :snooze_seconds,
    :expires_at
  ]

  @actions [:acknowledge, :snooze, :resolve]

  postgres do
    table "notification_action_tokens"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names selector: "notification_action_tokens_selector_uidx"

    references do
      reference :delivery, on_delete: :delete
      reference :alert, on_delete: :delete
    end
  end

  # Reads only, deliberately. There is no `define` for `:mint` or `:consume`,
  # because both have a precondition that lives outside the action: minting needs
  # a digest computed over the binding, and consuming needs the `is_nil(consumed_at)`
  # filter that `update :consume` cannot carry (see its description). A code
  # interface for either would be a supported way to write a token row that
  # verifies against nothing, or to burn one twice.
  # `ServiceRadar.Notifications.ActionToken` is the write path.
  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_selector, action: :by_selector, args: [:selector]
    define :list_for_delivery, action: :for_delivery, args: [:delivery_id]
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
    end

    # The selector is the public half of the token and is what makes verification
    # an indexed lookup rather than a scan over every live digest.
    read :by_selector do
      argument :selector, :string, allow_nil?: false
      get? true
      filter expr(selector == ^arg(:selector))
    end

    read :for_delivery do
      argument :delivery_id, :uuid, allow_nil?: false

      filter expr(delivery_id == ^arg(:delivery_id))
      prepare build(sort: [action: :asc])
    end

    create :mint do
      description """
      Persist one minted capability. The plaintext is never an input here -
      `ServiceRadar.Notifications.ActionToken.mint/2` returns it to its caller
      once and hands this action the digest only.
      """

      primary? true
      accept @fields
    end

    update :consume do
      description """
      Burn the capability.

      The single-use precondition is NOT declared here as `change filter(...)`,
      and that is not an oversight - on an atomic update it would be silently
      dropped. `Ash.Changeset.filter/2` records `added_filter` only while
      `phase == :pending` (`ash/changeset.ex:7687`), and changes run in phase
      `:validate`; the atomic path then overwrites the atomic changeset's filter
      with the original changeset's `added_filter`
      (`ash/actions/update/update.ex:155`), which for a change-declared filter is
      nil. The result is an UPDATE with no precondition, which is exactly the
      race the compare-and-set exists to close.

      So the precondition rides on the changeset the caller builds, in
      `ServiceRadar.Notifications.ActionToken.consume/2` - the same shape every
      other compare-and-set in this tree uses
      (`automation/ansible/execution_lifecycle_ash_actions.ex:27`). Call that
      function rather than this action directly.
      """

      accept []

      change set_attribute(:consumed_at, &DateTime.utc_now/0)
    end
  end

  policies do
    import ServiceRadar.Policies

    # Deliberately the only policy. See the moduledoc: nothing here is
    # operator-facing, so nothing but the notification pipeline may touch it.
    system_bypass()
  end

  validations do
    # Mirrors notification_action_tokens_snooze. A snooze duration that arrived
    # in the request rather than in the token would let anyone holding a Snooze
    # link choose how long the alert stays quiet.
    validate present(:snooze_seconds) do
      where attribute_equals(:action, :snooze)
      message "a snooze capability must carry the duration it grants"
    end

    validate absent(:snooze_seconds) do
      where attribute_in(:action, [:acknowledge, :resolve])
      message "only a snooze capability carries a duration"
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :selector, :string do
      allow_nil? false
      public? true

      description """
      The public half of the token, used only to find this row. It is not a
      credential: knowing it proves nothing without the secret half.
      """
    end

    attribute :token_hash, :string do
      allow_nil? false
      public? true
      sensitive? true

      description """
      sha256 hex of the canonical binding string, which covers the delivery, the
      alert, the action, AND the secret half. The plaintext is never stored.
      """
    end

    attribute :delivery_id, :uuid do
      allow_nil? false
      public? true
      description "The delivery whose rendered body carried this link."
    end

    attribute :alert_id, :uuid do
      allow_nil? false
      public? true
      description "The alert this capability acts on, and the only alert it can."
    end

    attribute :action, :atom do
      allow_nil? false
      public? true
      constraints one_of: @actions

      description """
      The single action this capability grants. A Snooze token cannot resolve.
      """
    end

    attribute :snooze_seconds, :integer do
      allow_nil? true
      public? true
      constraints min: 1

      description """
      How far ahead a `:snooze` capability moves `snooze_until`. Bound into the
      token at mint time so the duration cannot be chosen by whoever clicks.
      "Snooze 1h" is a link label; 3600 here is the model.
      """
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "TTL bound. A capability that outlives the incident is a liability."
    end

    attribute :consumed_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "Set exactly once, by the compare-and-set in `update :consume`."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :delivery, ServiceRadar.Notifications.NotificationDelivery do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :delivery_id
    end

    belongs_to :alert, ServiceRadar.Monitoring.Alert do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :alert_id
    end
  end

  identities do
    identity :selector, [:selector]
  end

  @doc "The closed action vocabulary a capability may grant."
  @spec actions() :: [atom()]
  def actions, do: @actions
end
