defmodule ServiceRadar.Notifications.NotificationCallbackApp do
  @moduledoc """
  The provider-side application whose signature authorises an inbound callback
  (task 4.3.1a, design D7).

  One row per registered provider application - a Slack app, later a Discord
  application - holding the key material its inbound interactions are verified
  against.

  ## Why this is not channel configuration

  The obvious place for a Slack signing secret is the channel's `config`, and it
  is the wrong place for two independent reasons:

    1. **The secret belongs to the app, not the channel.** Ten channels backed by
       one Slack app would hold ten copies of one secret, and rotating it would
       mean editing ten rows with no way to tell whether one was missed.
    2. **The callback could not find it there.** An inbound interaction names
       `api_app_id` and the workspace; it carries nothing identifying which
       ServiceRadar channel produced the message. Resolution has to start from
       the app id, which is what `by_external_app_id/1` does.

  The provider-seeder invariant "credential fields are named for the keys the
  transport resolves" refuses it for a third reason: the transport never resolves
  this secret at send time. Only the inbound path consumes it.

  ## Only ciphertext is stored

  `signing_secret_ciphertext` holds an `ServiceRadar.Edge.Crypto`-encrypted
  value, the same treatment northbound gives
  `callback_hmac_secret_ciphertext`. Unlike a capability token this cannot be
  stored as a digest: verifying an HMAC requires the secret itself, so the
  protection available is encryption at rest rather than one-way hashing. The
  attribute is `sensitive?`, so it is redacted from inspection and logs.

  ## Access

  Reading is deliberately NOT granted to the roles that can read the channel
  registry. A signing secret is a credential, and the only thing an operator
  needs from this table is to register and rotate one. Reading the registry and
  editing its labels require `notifications.providers.manage`. Registering,
  rotating, or deleting key material additionally requires
  `observability.alerts.manage`, because possession of a provider callback secret
  authorises an alert transition. Verification runs as the system actor.
  """

  use Ash.Resource,
    domain: ServiceRadar.Notifications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @manage_check {ActorHasPermission, permission: "notifications.providers.manage"}
  @alerts_manage_check {ActorHasPermission, permission: "observability.alerts.manage"}

  # The providers whose inbound callbacks are verified against a registered app.
  # A closed list rather than free text: an unknown provider_key here would be a
  # row nothing can ever resolve, written by a typo.
  @provider_keys [:slack, :pagerduty]

  postgres do
    table "notification_callback_apps"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names external_app: "notification_callback_apps_external_app_uidx"
  end

  code_interface do
    define :get_by_external_app_id,
      action: :by_external_app_id,
      args: [:provider_key, :external_app_id]

    define :list, action: :read
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
    end

    read :by_external_app_id do
      description """
      The resolution the callback performs: provider plus the app id the inbound
      request names. Indexed by the same identity that makes the pair unique, so
      this is a lookup rather than a scan of a credential table.
      """

      argument :provider_key, :atom, allow_nil?: false
      argument :external_app_id, :string, allow_nil?: false

      get? true

      filter expr(
               provider_key == ^arg(:provider_key) and
                 external_app_id == ^arg(:external_app_id)
             )
    end

    create :register do
      primary? true
      accept [:provider_key, :external_app_id, :label, :signing_secret_ciphertext]
    end

    update :rotate_secret do
      description """
      Replace the key material without touching identity.

      Separate from a general update so a rotation is legible in the audit trail
      as a rotation, rather than as an edit that happened to change one column.
      """

      accept [:signing_secret_ciphertext]
    end

    update :update do
      primary? true
      accept [:label]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    action_with_permission([:read, :by_external_app_id, :update], @manage_check)

    policy action([:register, :rotate_secret, :destroy]) do
      forbid_unless @manage_check
      forbid_unless @alerts_manage_check
      authorize_if @manage_check
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :provider_key, :atom do
      allow_nil? false
      constraints one_of: @provider_keys
      public? true
    end

    attribute :external_app_id, :string do
      description "The provider's own id for the app, e.g. a Slack `api_app_id`."
      allow_nil? false
      constraints max_length: 64, trim?: true, allow_empty?: false
      public? true
    end

    attribute :label, :string do
      description "Operator-facing name, so a rotation targets the right app."
      constraints max_length: 200, trim?: true, allow_empty?: true
      public? true
    end

    attribute :signing_secret_ciphertext, :string do
      description """
      `ServiceRadar.Edge.Crypto`-encrypted signing secret. Never the plaintext,
      and never a digest - an HMAC cannot be verified from a hash.
      """

      allow_nil? false
      sensitive? true
      public? false
    end

    timestamps()
  end

  identities do
    identity :external_app, [:provider_key, :external_app_id]
  end
end
