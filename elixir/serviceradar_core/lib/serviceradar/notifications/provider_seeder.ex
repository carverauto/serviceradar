defmodule ServiceRadar.Notifications.ProviderSeeder do
  @moduledoc """
  Seeds the first-party `ServiceRadar.Notifications.NotificationProvider` catalog
  (tasks 1.4.9, 4.2.4).

  Without this the platform installs with an empty provider catalog: an operator
  can write routes and escalation policies and cannot page anyone, because there
  is nothing to bind a `NotificationChannel` to. The four `:native` providers -
  `slack`, `discord`, `webhook`, `email` - plus the built-in `:stream` provider
  are therefore data this seeder owns, reconciled across releases with the
  `managed` / `template_version` / `template_fingerprint` pattern that
  `ServiceRadar.Observability.RuleSeeder` uses for preset rules.

  ## The declarative catalog rides the same loop

  `ServiceRadar.Notifications.Declarative.Catalog` supplies the first-party
  `:declarative` rows (tasks 2.4.1, 2.4.2), and they are reconciled HERE, by this
  code, rather than by a second seeder with a second opinion about what
  "operator-modified" means. `seeded_providers/0` is simply the native catalog
  followed by the declarative one, so a catalog entry gets the same create, the
  same divergence check, the same one-way activation, and the same "never
  re-enable a disabled provider" guarantee that `slack` gets.

  The single difference is the fingerprint's field list, which
  `managed_fields/1` answers per tier: a `:declarative` row adds `:definition`,
  because the definition IS the provider in that tier. Without it an operator's
  edit to a catalog entry's request template would not read as divergence and
  would be silently overwritten, and a release shipping a corrected document
  could never apply it. It is added for that tier ONLY: adding a field to a
  fingerprint's field list changes every digest computed with it, and the
  `:native` rows in the field carry digests an earlier release stamped with the
  shorter list. `definition` is NULL on every non-declarative row anyway - the
  `notification_providers_declarative_definition` CHECK constraint requires it -
  so nothing is lost by leaving it out there.

  `:stream` is seeded here rather than by a second mechanism, exactly as task
  1.4.9 asks: it is one more entry in `default_providers/0`. Note that its row
  carries `implementation_module: nil` - the
  `notification_providers_native_module` CHECK constraint requires NULL on every
  non-`:native` tier, so the stream transport is reached through the provider
  type, never through that column (design D2, G12).

  ## What the seeder owns, and what it never touches

  `@managed_fields` is the seeder-owned set and is what the fingerprint covers.
  Everything else on a provider row is operator territory:

    * `status` is never written by a reconcile. `:seed_managed` also excludes it
      from `upsert_fields`, so neither path can re-enable a provider an operator
      disabled. A brand-new row is born `:draft` and is activated once, on the
      boot that created it (see below).
    * `default_max_attempts` seeds `NotificationChannel.max_attempts` and is a
      tuning knob: an operator who raises it for a paging provider keeps it
      across upgrades, the same way `RuleSeeder` never reconciles a threshold.

  ## Activation is deliberate, and one-way

  A `NotificationProvider` is born `:draft`, and `Notifications.Suppression`
  withholds any dispatch to a channel whose provider is not `:active`, with
  `:channel_disabled`. A first-party native provider left in `:draft` is
  therefore a silent notification platform, so the seeder activates it - but
  only from `:draft`, never from `:disabled`.

  That distinction is the whole of the "must not re-enable a disabled provider"
  rule, and it holds because the state machine has no transition back into
  `:draft`: `:draft` can only mean "this row was seeded and never activated",
  while `:disabled` can only mean "an operator turned this off". Activating from
  `:draft` on every boot rather than only on the boot that created the row also
  makes the seeder self-healing, since a create that succeeds and an activate
  that fails would otherwise leave the provider permanently mute.

  ## Where the config schemas come from

  Each `config_schema` is derived from what that transport's `validate_config/1`
  actually accepts, in the constrained JSON Schema subset
  `ServiceRadar.Plugins.ConfigSchema` validates, so the web-ng `PluginConfigForm`
  can render it. Credential fields carry `secretRef: true` and are named for the
  key the transport reads out of `Transport.Request.secrets`, because
  `ServiceRadar.Plugins.SecretRefs.resolve_runtime_params/3` writes each resolved
  secret back under its schema field name.

  Where the subset cannot express a rule the transport enforces - "required only
  in the `bot_token` mode", "every header value is a single-line string" - the
  schema is the LOOSER of the two and the transport remains the authority. That
  direction is deliberate: a schema stricter than its transport rejects a
  configuration that would have worked, at save time, with a field error the
  operator cannot act on; a schema looser than its transport defers to a check
  that still runs before the channel is saved.

  ## Never `String.to_atom/1`

  `implementation_module` is taken from
  `ServiceRadar.Notifications.Transports.Registry`, which owns the compile-time
  allowlist that `NotificationProvider`'s `one_of` validation is also built from.
  A hand-typed module string here could be one the validator refuses, or - worse -
  one dispatch resolves that the validator would have refused.

  See `openspec/changes/add-notification-platform/design.md` (D2, D10, G12).
  """

  use ServiceRadar.DelayedSeeder, delay_ms: 6_000, callback: :seed_all

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Notifications.Declarative.Catalog
  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Notifications.SeedFingerprint
  alias ServiceRadar.Notifications.Transports.Discord
  alias ServiceRadar.Notifications.Transports.Email
  alias ServiceRadar.Notifications.Transports.GenericWebhook
  alias ServiceRadar.Notifications.Transports.Registry, as: TransportRegistry
  alias ServiceRadar.Notifications.Transports.Slack
  alias ServiceRadar.Notifications.Transports.Stream

  require Logger

  # The seeder-owned fields: reconciled on a template version bump and covered by
  # the divergence fingerprint. `status` and `default_max_attempts` are
  # deliberately absent; see the moduledoc.
  @managed_fields [
    :display_name,
    :description,
    :icon,
    :config_schema,
    :capabilities,
    :supported_routes,
    :payload_formats,
    :definition_version,
    :implementation_module,
    :source
  ]

  # A `:declarative` row's document is seeder-owned content, so it is fingerprinted
  # and reconciled. See the moduledoc for why this is a separate list rather than
  # an extra entry in `@managed_fields`.
  @declarative_managed_fields @managed_fields ++ [:definition]

  # Bumped to "2" when the Slack schema gained interactive-mode properties.
  # `config_schema` is a managed field, so without a bump a deployed row keeps
  # the old schema and rejects `interactive` on save - the feature would appear
  # to ship and be unusable.
  @template_version "2"

  # The stored `implementation_module` names, resolved from the registry's
  # allowlist at COMPILE time. A transport that is not allowlisted fails the
  # build rather than the boot: raising from a supervised seeder would restart
  # it, re-arm the timer, raise again, and take `Cluster.CoordinatorChildren`
  # down with it after the restart budget - losing the schedulers and the event
  # writer over a name the compiler could have caught.
  @transport_module_names Map.new([Slack, Discord, GenericWebhook, Email], fn module ->
                            case TransportRegistry.name_for(module) do
                              {:ok, name} ->
                                {module, name}

                              {:error, reason} ->
                                raise ArgumentError,
                                      "#{inspect(module)} is not an allowlisted notification " <>
                                        "transport: " <>
                                        TransportRegistry.describe_error(reason)
                            end
                          end)

  @doc """
  The seeder-owned attribute set covered by the divergence fingerprint.

  This is the `:native` and `:stream` list. Use `managed_fields/1` when a row or
  an attribute map is in hand: the `:declarative` tier fingerprints one more
  field.
  """
  @spec managed_fields() :: [atom()]
  def managed_fields, do: @managed_fields

  @doc """
  The version stamped on every seeder-managed row.

  Public so a test asserts "advanced to the shipped version" rather than a
  literal that must be edited on every bump - which is how a reconciliation test
  ends up asserting the version it was written against instead of the one that
  ships.
  """
  @spec template_version() :: String.t()
  def template_version, do: @template_version

  @doc """
  The seeder-owned attribute set for one provider row or attribute map.

  `:declarative` adds `:definition`, because in that tier the document is the
  provider. See the moduledoc for why the two lists are not one.
  """
  @spec managed_fields(map() | struct()) :: [atom()]
  def managed_fields(%{provider_type: :declarative}), do: @declarative_managed_fields
  def managed_fields(_row_or_attrs), do: @managed_fields

  @doc false
  @spec seed_all() :: :ok | nil
  def seed_all do
    if repo_enabled?() do
      seed_providers()
    end
  end

  @doc """
  Reconciles the first-party provider catalog. Idempotent.
  """
  @spec seed_providers() :: :ok
  def seed_providers do
    opts = [actor: SystemActor.system(:notification_provider_seeder)]

    case Ash.read(Ash.Query.for_read(NotificationProvider, :read, %{}), opts) do
      {:ok, providers} ->
        existing = Map.new(providers, &{&1.provider_key, &1})
        Enum.each(seeded_providers(), &reconcile_or_create(existing, &1, opts))
        :ok

      {:error, reason} ->
        Logger.warning("Failed to read notification providers for seeding: #{inspect(reason)}")
        :ok
    end
  end

  # --- reconciliation --------------------------------------------------------

  defp reconcile_or_create(existing, attrs, opts) do
    case Map.get(existing, attrs.provider_key) do
      nil -> create_provider(attrs, opts)
      provider -> reconcile_provider(provider, attrs, opts)
    end
  end

  defp create_provider(attrs, opts) do
    create_attrs = Map.put(attrs, :template_fingerprint, fingerprint(attrs))
    changeset = Ash.Changeset.for_create(NotificationProvider, :seed_managed, create_attrs, opts)

    case Ash.create(changeset) do
      {:ok, provider} ->
        Logger.info("Seeded notification provider #{attrs.provider_key}")
        maybe_activate(provider, opts)

      {:error, reason} ->
        Logger.warning(
          "Failed to seed notification provider #{attrs.provider_key}: #{inspect(reason)}"
        )
    end
  end

  defp reconcile_provider(provider, attrs, opts) do
    cond do
      not provider.managed ->
        maybe_adopt_unmanaged(provider, attrs, opts)

      current?(provider, attrs) ->
        maybe_activate(provider, opts)

      SeedFingerprint.diverged?(provider, managed_fields(attrs)) ->
        Logger.info(
          "Skipping managed notification provider #{provider.provider_key}: operator-modified " <>
            "fields diverge from template v#{provider.template_version}"
        )

      true ->
        update_managed(provider, attrs, opts)
    end
  end

  # String versions compare as strings on purpose: `template_version` is a
  # `:string` column on this resource, and "10" < "9" lexically. Equality is the
  # only comparison that is safe without inventing a version ordering the column
  # does not have, so a template is applied exactly when its version differs from
  # the stored one.
  defp current?(provider, attrs), do: provider.template_version == attrs.template_version

  # A seeded-key row without the managed marker is adopted only when its
  # seeder-owned fields already match the shipped template exactly, so the stamp
  # adds the marker without any content change. Anything else was authored or
  # edited by an operator and is left alone.
  defp maybe_adopt_unmanaged(provider, attrs, opts) do
    if SeedFingerprint.matches_template?(provider, attrs, managed_fields(attrs)) do
      stamp = %{
        managed: true,
        template_version: attrs.template_version,
        template_fingerprint: fingerprint(attrs)
      }

      apply_update(provider, stamp, opts, "Adopted pristine notification provider")
    else
      Logger.info(
        "Skipping unmanaged notification provider #{provider.provider_key}: not owned by the seeder"
      )
    end
  end

  defp update_managed(provider, attrs, opts) do
    update_attrs =
      attrs
      |> Map.take([:template_version | managed_fields(attrs)])
      |> Map.put(:managed, true)
      |> Map.put(:template_fingerprint, fingerprint(attrs))

    apply_update(provider, update_attrs, opts, "Reconciled notification provider")
  end

  defp apply_update(provider, update_attrs, opts, message) do
    changeset = Ash.Changeset.for_update(provider, :update, update_attrs, opts)

    case Ash.update(changeset) do
      {:ok, updated} ->
        Logger.info(
          "#{message} #{provider.provider_key} at template v#{updated.template_version}"
        )

        maybe_activate(updated, opts)

      {:error, reason} ->
        Logger.warning(
          "Failed to update notification provider #{provider.provider_key}: #{inspect(reason)}"
        )
    end
  end

  # Only ever from `:draft`. `:disabled` is an operator decision and the state
  # machine offers no way back into `:draft`, so this can never re-enable a
  # provider somebody turned off.
  defp maybe_activate(%{status: :draft} = provider, opts) do
    changeset = Ash.Changeset.for_update(provider, :activate, %{}, opts)

    case Ash.update(changeset) do
      {:ok, _activated} ->
        Logger.info("Activated seeded notification provider #{provider.provider_key}")

      {:error, reason} ->
        Logger.warning(
          "Failed to activate notification provider #{provider.provider_key}: #{inspect(reason)}"
        )
    end
  end

  defp maybe_activate(_provider, _opts), do: :ok

  defp fingerprint(attrs), do: SeedFingerprint.fingerprint(attrs, managed_fields(attrs))

  # --- the catalog -----------------------------------------------------------

  @doc """
  Every first-party provider row this seeder reconciles.

  The `:native` and `:stream` catalog, followed by
  `ServiceRadar.Notifications.Declarative.Catalog`'s `:declarative` entries. One
  list, one loop, one reconciliation rule; see the moduledoc.
  """
  @spec seeded_providers() :: [map()]
  def seeded_providers, do: default_providers() ++ Catalog.provider_attrs()

  @doc """
  The first-party `:native` and `:stream` provider catalog, as attribute maps.

  Public because the seeder tests assert against it directly - a catalog whose
  `config_schema` does not validate, or whose `implementation_module` is not
  allowlisted, is a boot-time warning nobody reads otherwise. The `:declarative`
  catalog is `Declarative.Catalog.provider_attrs/0`; `seeded_providers/0` is
  both.
  """
  @spec default_providers() :: [map()]
  def default_providers do
    [
      slack_provider(),
      discord_provider(),
      webhook_provider(),
      email_provider(),
      stream_provider()
    ]
  end

  defp slack_provider do
    %{
      provider_key: "slack",
      provider_type: :native,
      display_name: "Slack",
      description:
        "Post to a Slack channel through an incoming webhook or a bot token. Block Kit " <>
          "payloads carry the acknowledge, snooze, and resolve links.",
      icon: "slack",
      implementation_module: module_name(Slack),
      capabilities: capabilities(Slack),
      supported_routes: [:control_plane],
      payload_formats: [:slack_blocks, :markdown, :plain],
      config_schema: slack_config_schema(),
      source: :first_party,
      default_max_attempts: 3,
      definition_version: 1,
      managed: true,
      template_version: @template_version
    }
  end

  defp discord_provider do
    %{
      provider_key: "discord",
      provider_type: :native,
      display_name: "Discord",
      description:
        "Post to a Discord channel through a webhook. The embed carries the acknowledge, " <>
          "snooze, and resolve links as Markdown actions.",
      icon: "discord",
      implementation_module: module_name(Discord),
      capabilities: capabilities(Discord),
      supported_routes: [:control_plane],
      payload_formats: [:discord_embed, :markdown, :plain],
      config_schema: discord_config_schema(),
      source: :first_party,
      default_max_attempts: 3,
      definition_version: 1,
      managed: true,
      template_version: @template_version
    }
  end

  defp webhook_provider do
    %{
      provider_key: "webhook",
      provider_type: :native,
      display_name: "Webhook",
      description:
        "POST the rendered JSON notification to an HTTPS endpoint. Replaces the legacy " <>
          "WebhookNotifier: the URL passes the outbound policy and credentials are stored " <>
          "references rather than plain headers.",
      icon: "webhook",
      implementation_module: module_name(GenericWebhook),
      capabilities: capabilities(GenericWebhook),
      supported_routes: [:control_plane],
      payload_formats: [:json],
      config_schema: webhook_config_schema(),
      source: :first_party,
      default_max_attempts: 3,
      definition_version: 1,
      managed: true,
      template_version: @template_version
    }
  end

  defp email_provider do
    %{
      provider_key: "email",
      provider_type: :native,
      display_name: "Email",
      description:
        "Send the notification as mail through the deployment mailer. Relay host, port, " <>
          "and credentials are deployment configuration, not channel configuration.",
      icon: "mail",
      implementation_module: module_name(Email),
      capabilities: capabilities(Email),
      supported_routes: [:control_plane],
      payload_formats: [:html, :markdown, :plain],
      config_schema: email_config_schema(),
      source: :first_party,
      default_max_attempts: 3,
      definition_version: 1,
      managed: true,
      template_version: @template_version
    }
  end

  # The built-in firehose (design D10, G12). `implementation_module` MUST be nil:
  # the `notification_providers_native_module` CHECK constraint admits it only on
  # a `:native` row, and `NotificationProvider` mirrors that as an Ash validation.
  defp stream_provider do
    %{
      provider_key: "stream",
      provider_type: :stream,
      display_name: "Event stream",
      description:
        "Publish the canonical notification envelope to an RBAC-scoped topic. Envelopes " <>
          "carry identifiers and never an action link or capability token.",
      icon: "radio",
      implementation_module: nil,
      capabilities: capabilities(Stream),
      supported_routes: [:control_plane],
      payload_formats: [:json],
      config_schema: stream_config_schema(),
      source: :first_party,
      default_max_attempts: 3,
      definition_version: 1,
      managed: true,
      template_version: @template_version
    }
  end

  # Taken from the transport rather than retyped, so the catalog cannot claim a
  # capability the module does not implement. Sorted for a stable fingerprint:
  # reordering `capabilities/0` must not read as an operator edit.
  defp capabilities(module), do: Enum.sort(module.capabilities())

  defp module_name(module), do: Map.fetch!(@transport_module_names, module)

  # --- config schemas --------------------------------------------------------

  # `mode` is the only unconditionally required key. `webhook_url` is required in
  # the incoming_webhook mode and `bot_token` plus `channel` in the bot_token
  # mode, which the root-level subset (no `if` / `allOf` / `dependentRequired`)
  # cannot express - `Transports.Slack.validate_config/1` is the authority there.
  defp slack_config_schema do
    %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "title" => "Slack channel configuration",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["mode"],
      "properties" => %{
        "mode" => %{
          "type" => "string",
          "title" => "Mode",
          "description" =>
            "incoming_webhook posts to a Slack webhook URL; bot_token posts to " <>
              "chat.postMessage as an app.",
          "enum" => ["incoming_webhook", "bot_token"],
          "default" => "incoming_webhook"
        },
        "webhook_url" => %{
          "type" => "string",
          "title" => "Incoming webhook URL",
          "description" =>
            "Required in the incoming_webhook mode. Stored as a credential reference: the " <>
              "secret is in the URL path, so it must never be saved as plain configuration.",
          "secretRef" => true,
          "credentialKind" => "api_token"
        },
        "bot_token" => %{
          "type" => "string",
          "title" => "Bot token",
          "description" => "Required in the bot_token mode. Stored as a credential reference.",
          "secretRef" => true,
          "credentialKind" => "api_token"
        },
        "channel" => %{
          "type" => "string",
          "title" => "Channel",
          "description" => "Required in the bot_token mode: the channel id or name to post to.",
          "minLength" => 1,
          "maxLength" => 200
        },
        "interactive" => %{
          "type" => "boolean",
          "title" => "Interactive acknowledgement",
          "description" =>
            "Render Acknowledge / Snooze / Resolve as Slack buttons that post an " <>
              "interaction, instead of signed links. Requires a Slack app with an " <>
              "Interactivity Request URL pointing at this deployment. Defaults off: " <>
              "buttons on an app without that URL configured are silently inert, and " <>
              "no API reports it.",
          "default" => false
        },
        "api_app_id" => %{
          "type" => "string",
          "title" => "Slack app id",
          "description" =>
            "Required when interactive is on. The inbound interaction names the app " <>
              "that sent it and carries nothing identifying this channel, so this is " <>
              "how the callback selects the right signing secret.",
          "minLength" => 1,
          "maxLength" => 64
        },
        # NOTE: the app's signing secret is deliberately NOT here. It is scoped
        # to the Slack app, not to a channel, so channel config would hold one
        # copy per channel backed by the same app - and the inbound interaction
        # names `api_app_id`, never our channel, so the callback could not find
        # it by channel anyway. It needs app-scoped storage the callback resolves
        # by `api_app_id`.
        "thread_ts" => %{
          "type" => "string",
          "title" => "Thread timestamp",
          "description" => "Optional. Post into an existing thread instead of the channel.",
          "maxLength" => 64
        },
        "username" => %{
          "type" => "string",
          "title" => "Override username",
          "description" => "Optional display name for the posting identity.",
          "maxLength" => 200
        },
        "icon_emoji" => %{
          "type" => "string",
          "title" => "Override icon emoji",
          "description" => "Optional emoji shortcode, for example :rotating_light:.",
          "maxLength" => 100
        },
        "api_base_url" => %{
          "type" => "string",
          "title" => "API base URL",
          "description" =>
            "Optional. Defaults to https://slack.com/api. Must pass the outbound URL policy.",
          "format" => "uri",
          "maxLength" => 2000
        }
      }
    }
  end

  defp discord_config_schema do
    %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "title" => "Discord channel configuration",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["webhook_url"],
      "properties" => %{
        "webhook_url" => %{
          "type" => "string",
          "title" => "Webhook URL",
          "description" =>
            "Stored as a credential reference: a Discord webhook carries its token in the " <>
              "URL path and must never be saved as plain configuration.",
          "secretRef" => true,
          "credentialKind" => "api_token"
        },
        "thread_id" => %{
          "type" => "string",
          "title" => "Thread id",
          "description" => "Optional. Post into an existing thread instead of the channel.",
          "maxLength" => 64
        },
        "wait" => %{
          "type" => "boolean",
          "title" => "Wait for the message",
          "description" =>
            "Ask Discord to return the created message so its id can be correlated with a " <>
              "later interaction. Without it Discord answers 204 with no body.",
          "default" => true
        },
        "username" => %{
          "type" => "string",
          "title" => "Override username",
          "description" => "Optional display name for the posting identity.",
          "maxLength" => 80
        },
        "avatar_url" => %{
          "type" => "string",
          "title" => "Override avatar URL",
          "description" => "Optional avatar image for the posting identity.",
          "format" => "uri",
          "maxLength" => 2000
        }
      }
    }
  end

  # `token` and `password` are named for the keys `Transports.GenericWebhook`
  # reads out of `Request.secrets`, which is what `SecretRefs` writes each
  # resolved reference back under.
  defp webhook_config_schema do
    %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "title" => "Webhook channel configuration",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["url"],
      "properties" => %{
        "url" => %{
          "type" => "string",
          "title" => "Endpoint URL",
          "description" =>
            "HTTPS endpoint. Checked against the outbound URL policy before any request: " <>
              "loopback, link-local, and private addresses are refused.",
          "format" => "uri",
          "maxLength" => 2000
        },
        "method" => %{
          "type" => "string",
          "title" => "HTTP method",
          "enum" => ["POST", "PUT", "PATCH"],
          "default" => "POST"
        },
        "headers" => %{
          "type" => "object",
          "title" => "Extra headers",
          "description" =>
            "Optional request headers, as name to single-line string value. Credential-shaped " <>
              "names are refused - config is not a sensitive column; use the auth mode instead.",
          "additionalProperties" => true
        },
        "auth_mode" => %{
          "type" => "string",
          "title" => "Authentication",
          "description" =>
            "bearer and header send the stored token; basic sends the username with the " <>
              "stored password.",
          "enum" => ["none", "bearer", "basic", "header"],
          "default" => "none"
        },
        "auth_header_name" => %{
          "type" => "string",
          "title" => "Auth header name",
          "description" => "Required in the header mode, for example X-API-Key.",
          "maxLength" => 200
        },
        "username" => %{
          "type" => "string",
          "title" => "Username",
          "description" => "Required in the basic mode. The password is a stored credential.",
          "maxLength" => 200
        },
        "token" => %{
          "type" => "string",
          "title" => "Token",
          "description" =>
            "Used by the bearer and header modes. Stored as a credential reference.",
          "secretRef" => true,
          "credentialKind" => "api_token"
        },
        "password" => %{
          "type" => "string",
          "title" => "Password",
          "description" => "Used by the basic mode. Stored as a credential reference.",
          "secretRef" => true,
          "credentialKind" => "username_password"
        },
        "timeout_ms" => %{
          "type" => "integer",
          "title" => "Timeout (ms)",
          "description" => "Connect and receive timeout. Defaults to 15000.",
          "minimum" => 1,
          "maximum" => 120_000,
          "default" => 15_000
        }
      }
    }
  end

  # No credential field at all: relay host, port, username, password, and TLS are
  # deployment mail configuration, and `Transports.Email.validate_config/1`
  # rejects them by name on a channel. `additionalProperties: false` refuses them
  # here for the same reason - a relay accepted from a channel row would let a
  # notification be aimed at an arbitrary internal service.
  defp email_config_schema do
    %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "title" => "Email channel configuration",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["to"],
      "properties" => %{
        "to" => %{
          "type" => "array",
          "title" => "To",
          "description" => "Recipient addresses. At least one is required.",
          "items" => %{"type" => "string", "minLength" => 3, "maxLength" => 256},
          "minItems" => 1,
          "maxItems" => 100
        },
        "cc" => %{
          "type" => "array",
          "title" => "Cc",
          "description" => "Optional. Leave blank if you do not need carbon copies.",
          "items" => %{"type" => "string", "minLength" => 3, "maxLength" => 256},
          "minItems" => 0,
          "maxItems" => 100
        },
        "bcc" => %{
          "type" => "array",
          "title" => "Bcc",
          "description" => "Optional. Leave blank if you do not need blind carbon copies.",
          "items" => %{"type" => "string", "minLength" => 3, "maxLength" => 256},
          "minItems" => 0,
          "maxItems" => 100
        },
        "from" => %{
          "type" => "string",
          "title" => "From",
          "description" => "Optional sender address. Defaults to the deployment mail identity.",
          "minLength" => 3,
          "maxLength" => 256
        },
        "subject_prefix" => %{
          "type" => "string",
          "title" => "Subject prefix",
          "description" =>
            "Optional text prepended to every subject, for example [ServiceRadar].",
          "maxLength" => 200
        }
      }
    }
  end

  defp stream_config_schema do
    %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "title" => "Event stream channel configuration",
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "topic" => %{
          "type" => "string",
          "title" => "Topic suffix",
          "description" =>
            "Optional. Publishes to notifications:stream:<suffix> instead of the firehose. " <>
              "Subscribing is authorized separately; a topic grants nothing by itself.",
          "pattern" => "^[A-Za-z0-9][A-Za-z0-9_:-]{0,63}$",
          "maxLength" => 64
        },
        "include_payload" => %{
          "type" => "boolean",
          "title" => "Include the rendered payload",
          "description" =>
            "Carry the redacted rendered payload in the envelope. Turn it off to publish " <>
              "identifiers only.",
          "default" => true
        }
      }
    }
  end
end
