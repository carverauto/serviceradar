defmodule ServiceRadar.Notifications.Transport do
  @moduledoc """
  The single contract every notification provider tier implements (design D2).

  Two concerns are routinely conflated in notification systems and want opposite
  treatment (design D1):

    1. The **decision engine** - deduplicate, route, fan out, escalate, suppress,
       track, and close the loop on acknowledgement. Nothing plugs into it.
    2. The **transport** - take a rendered payload and get it to a destination.
       This is the only extensible boundary, and this behaviour is it.

  ## The invariant this behaviour exists to protect

  Routing, escalation, deduplication, suppression, and acknowledgement MUST NEVER
  branch on `provider_type`. A channel that changes tier from `:native` to
  `:declarative` to `:wasm_plugin` MUST NOT change a single decision the engine
  makes; only the module on the far side of `deliver/2` changes.

  Concretely, no module in the decision path may contain a
  `case provider_type do` or a `if provider_type == :wasm_plugin`. The tier is
  resolved exactly once - when the dispatcher looks up which transport to invoke -
  and is never consulted again. A transport result cannot suppress, escalate, or
  acknowledge anything either: the engine records the transport outcome on the
  `NotificationDelivery` row and takes its decisions from its own state.

  ## Callbacks

  Exactly four, in every tier:

    * `deliver/2` - send one rendered payload. NOT `send/2`; a module exporting
      `send/2` is the old, wrong spelling and is rejected by the registry
      conformance check.
    * `validate_config/1` - check a channel's configuration at save time, so a
      broken channel fails when an operator saves it rather than during an
      incident.
    * `capabilities/0` - what this transport can do. It MUST contain both `:send`
      and `:test`; `ServiceRadar.Notifications.Validations.ProviderTransportContract`
      rejects a provider that declares otherwise.
    * `test/2` - a test send. It is NOT optional in any tier, because
      "test-send before saving" has to work uniformly, and it MUST exercise the
      same transport, credential resolution, and rendering path a real dispatch
      does, or a passing test is not evidence the channel works. Deliveries it
      produces carry `is_test: true` and never count toward an alert's totals.

  ## Why the result has three dispositions and not two

  `NotificationDelivery` treats `:failed` as **terminal** (design D4, C7). A
  retry-eligible delivery stays `:pending` with `next_attempt_at` set and
  `attempt_count` incremented - it does not pass through `:failed` and come back,
  because retry-due selection reads `:pending` rows and a scan that picks up
  `:failed` rows retries forever and defeats the attempt bound entirely.

  A boolean "did it work" result cannot express that, so `Result.disposition` is
  one of:

  | Disposition | Meaning | Delivery outcome |
  | --- | --- | --- |
  | `:delivered` | The destination accepted the payload | `:sent` |
  | `:retryable_failure` | 5xx, 429, timeout, agent offline | stays `:pending` while attempts remain, else `:failed` |
  | `:permanent_failure` | 4xx other than 429, payload rejected, config invalid | `:failed`, terminal |

  `outcome/2` is the pure function that applies that table, so the rule lives in
  one place instead of being re-derived at each call site.

  ## What a transport carries back

    * `external_correlation_id` - the provider-side handle for the message: a
      Slack `ts`, a PagerDuty `dedup_key`, a message id. It is what lets a later
      inbound interaction resolve back to the originating delivery, and what
      makes threading and resolution updates possible at all.
    * `error_class` - a short, stable, machine-comparable classifier
      (`"http_503"`, `"timeout"`, `"agent_offline"`, `"invalid_config"`). Telemetry
      and the Delivery Log group by it, so it must not carry per-request detail.
    * `error_message` - the human sentence. Redacted before persistence.

  ## Purity

  This module is a contract plus pure constructors. It performs no I/O, holds no
  process state, and never reads the clock: a `Result` records what happened, and
  the caller stamps the timestamps it persists.

  See `openspec/changes/add-notification-platform/design.md` (D1, D2, D4).
  """

  alias ServiceRadar.Notifications.Transport

  @capabilities [
    :send,
    :test,
    :resolve_update,
    :inbound_callback,
    :rich_payload,
    :attachments,
    :threading
  ]

  @required_capabilities [:send, :test]

  @payload_formats [
    :slack_blocks,
    :discord_embed,
    :markdown,
    :plain,
    :html,
    :pagerduty_v2,
    :json
  ]

  @execution_routes [:control_plane, :edge_agent]

  @type capability ::
          :send
          | :test
          | :resolve_update
          | :inbound_callback
          | :rich_payload
          | :attachments
          | :threading

  @type payload_format ::
          :slack_blocks
          | :discord_embed
          | :markdown
          | :plain
          | :html
          | :pagerduty_v2
          | :json

  @type execution_route :: :control_plane | :edge_agent

  @type config_error :: %{field: String.t() | nil, message: String.t()}

  defmodule Request do
    @moduledoc """
    One rendered notification, ready to hand to a destination.

    A request is a plain struct of already-decided values. A transport never
    re-decides anything on it: it does not consult routing, does not re-run
    suppression, and does not choose a payload format - `payload_format` is the
    format the renderer already negotiated against the provider's declared
    `payload_formats`, and it is the value persisted on the delivery row.

    `secrets` holds credential material resolved through
    `ServiceRadar.Credentials.SecretBroker`. It is deliberately a separate field
    from `config` so that persistence and logging can serialise `config` and
    never `secrets`, and so a transport cannot accidentally echo a secret back
    inside `result_summary`.
    """

    @enforce_keys [:delivery_id, :channel_id, :payload_format, :payload]

    defstruct [
      :delivery_id,
      :alert_id,
      :route_id,
      :policy_id,
      :step_number,
      :channel_id,
      :provider_key,
      :provider_version,
      :intent,
      :lifecycle_reason,
      :alert_snapshot,
      :payload_format,
      :payload,
      :subject,
      :body,
      :dedupe_key,
      :external_correlation_id,
      :agent_uid,
      :partition_id,
      :queued_at,
      :started_at,
      :next_attempt_at,
      :command_id,
      config: %{},
      secrets: %{},
      action_links: %{},
      execution_route: :control_plane,
      attempt: 1,
      max_attempts: 3,
      is_test: false,
      metadata: %{}
    ]

    @type t :: %__MODULE__{
            delivery_id: String.t() | nil,
            alert_id: String.t() | nil,
            route_id: String.t() | nil,
            policy_id: String.t() | nil,
            step_number: integer() | nil,
            channel_id: String.t() | nil,
            provider_key: String.t() | nil,
            provider_version: pos_integer() | nil,
            intent: :send | :resolve_update | :test | nil,
            lifecycle_reason: atom() | nil,
            alert_snapshot: map(),
            payload_format: Transport.payload_format(),
            payload: map(),
            subject: String.t() | nil,
            body: String.t() | nil,
            dedupe_key: String.t() | nil,
            external_correlation_id: String.t() | nil,
            agent_uid: String.t() | nil,
            partition_id: String.t() | nil,
            queued_at: DateTime.t() | nil,
            started_at: DateTime.t() | nil,
            next_attempt_at: DateTime.t() | nil,
            command_id: String.t() | nil,
            config: map(),
            secrets: map(),
            action_links: map(),
            execution_route: Transport.execution_route(),
            attempt: pos_integer(),
            max_attempts: pos_integer(),
            is_test: boolean(),
            metadata: map()
          }
  end

  defmodule Result do
    @moduledoc """
    What one transport attempt did.

    The three dispositions are the whole point of the struct; see the
    `ServiceRadar.Notifications.Transport` moduledoc for why a boolean is not
    enough. `outcome/2` maps a disposition plus the remaining attempt budget onto
    the delivery state the engine should record, so C7 ("`:failed` is terminal,
    retries stay `:pending`") is decided in exactly one place.
    """

    @dispositions [:delivered, :retryable_failure, :permanent_failure]

    @enforce_keys [:disposition]

    defstruct [
      :disposition,
      :external_correlation_id,
      :error_class,
      :error_message,
      :retry_after_ms,
      result_summary: %{},
      provider_metadata: %{}
    ]

    @type disposition :: :delivered | :retryable_failure | :permanent_failure

    @type t :: %__MODULE__{
            disposition: disposition(),
            external_correlation_id: String.t() | nil,
            error_class: String.t() | nil,
            error_message: String.t() | nil,
            retry_after_ms: non_neg_integer() | nil,
            result_summary: map(),
            provider_metadata: map()
          }

    @doc "The closed disposition vocabulary."
    @spec dispositions() :: [disposition()]
    def dispositions, do: @dispositions

    @doc """
    The destination accepted the payload.

    `:external_correlation_id` is the provider-side handle (Slack `ts`,
    PagerDuty `dedup_key`) and should be supplied whenever the provider returns
    one, because inbound callbacks resolve back to the delivery through it.
    """
    @spec delivered(keyword()) :: t()
    def delivered(opts \\ []) do
      %__MODULE__{
        disposition: :delivered,
        external_correlation_id: Keyword.get(opts, :external_correlation_id),
        result_summary: Keyword.get(opts, :result_summary, %{}),
        provider_metadata: Keyword.get(opts, :provider_metadata, %{})
      }
    end

    @doc """
    The attempt failed in a way that is worth repeating: 5xx, 429, a timeout, a
    connection reset, or an offline agent.

    The delivery stays `:pending` with `next_attempt_at` set while attempts
    remain. `:retry_after_ms` carries a provider-supplied hint (a `Retry-After`
    header); the scheduler MAY honour it but is still bound by `max_attempts`.
    """
    @spec retryable_failure(String.t(), keyword()) :: t()
    def retryable_failure(error_class, opts \\ []) when is_binary(error_class) do
      %__MODULE__{
        disposition: :retryable_failure,
        error_class: error_class,
        error_message: Keyword.get(opts, :error_message),
        retry_after_ms: Keyword.get(opts, :retry_after_ms),
        result_summary: Keyword.get(opts, :result_summary, %{}),
        provider_metadata: Keyword.get(opts, :provider_metadata, %{})
      }
    end

    @doc """
    The attempt failed in a way repeating cannot fix: a 4xx other than 429, a
    rejected payload, an invalid configuration.

    The delivery moves straight to `:failed`, which is terminal.
    """
    @spec permanent_failure(String.t(), keyword()) :: t()
    def permanent_failure(error_class, opts \\ []) when is_binary(error_class) do
      %__MODULE__{
        disposition: :permanent_failure,
        error_class: error_class,
        error_message: Keyword.get(opts, :error_message),
        result_summary: Keyword.get(opts, :result_summary, %{}),
        provider_metadata: Keyword.get(opts, :provider_metadata, %{})
      }
    end

    @doc "True when the destination accepted the payload."
    @spec delivered?(t()) :: boolean()
    def delivered?(%__MODULE__{disposition: :delivered}), do: true
    def delivered?(%__MODULE__{}), do: false

    @doc "True when repeating the attempt could succeed."
    @spec retryable?(t()) :: boolean()
    def retryable?(%__MODULE__{disposition: :retryable_failure}), do: true
    def retryable?(%__MODULE__{}), do: false

    @doc """
    The delivery state this result implies, given whether the attempt budget has
    anything left.

    This is C7 in one function:

      * `:delivered` -> `:sent`
      * `:retryable_failure` with attempts remaining -> `:retry` (the row stays
        `:pending` with `next_attempt_at` set; it does NOT visit `:failed`)
      * `:retryable_failure` with the budget exhausted -> `:failed`
      * `:permanent_failure` -> `:failed`, always, regardless of the budget
    """
    @spec outcome(t(), boolean()) :: :sent | :retry | :failed
    def outcome(%__MODULE__{disposition: :delivered}, _attempts_remaining?), do: :sent
    def outcome(%__MODULE__{disposition: :permanent_failure}, _attempts_remaining?), do: :failed
    def outcome(%__MODULE__{disposition: :retryable_failure}, true), do: :retry
    def outcome(%__MODULE__{disposition: :retryable_failure}, false), do: :failed
  end

  @doc """
  Send one rendered payload.

  Named `deliver`, never `send`: `send/2` collides with `Kernel.send/2` and was
  the earlier, incorrect spelling of this callback. The registry's conformance
  check rejects a transport that still exports it.

  A transport MUST return a `Result`. It MUST NOT raise for an ordinary transport
  failure, MUST NOT sleep or retry internally (retry is the engine's bounded,
  Oban-backed mechanism), and MUST NOT return a value that implies a routing,
  suppression, escalation, or acknowledgement decision.
  """
  @callback deliver(Request.t(), opts :: keyword()) :: Result.t()

  @doc """
  Check a channel configuration at save time.

  Returning `{:error, errors}` prevents the channel from being saved, so the
  operator learns about a missing relay host or an unusable URL when they press
  save, not when an incident fires.
  """
  @callback validate_config(config :: map()) :: :ok | {:error, [config_error()]}

  @doc """
  What this transport can do.

  MUST include both `:send` and `:test`.
  """
  @callback capabilities() :: [capability()]

  @doc """
  Test send.

  Mandatory in every tier. It exercises the same transport, credential
  resolution, and rendering path as `deliver/2` - a test that takes a shortcut is
  not evidence the channel works. The delivery it produces is marked
  `is_test: true` so it never counts toward an alert's delivery count,
  notification count, escalation progress, retry budget, renotify cadence, or
  dedupe state.
  """
  @callback test(Request.t(), opts :: keyword()) :: Result.t()

  @doc "The closed capability vocabulary, matching `NotificationProvider.capabilities`."
  @spec capabilities() :: [capability()]
  def capabilities, do: @capabilities

  @doc "The capabilities every provider must declare, in every tier (design D2)."
  @spec required_capabilities() :: [capability()]
  def required_capabilities, do: @required_capabilities

  @doc "The closed payload-format vocabulary."
  @spec payload_formats() :: [payload_format()]
  def payload_formats, do: @payload_formats

  @doc "The closed execution-route vocabulary."
  @spec execution_routes() :: [execution_route()]
  def execution_routes, do: @execution_routes

  @doc """
  The four callbacks, as `{name, arity}`, for conformance checking.

  `send/2` is deliberately absent and is treated as a defect; see `deliver/2`.
  """
  @spec required_callbacks() :: [{atom(), arity()}]
  def required_callbacks,
    do: [{:capabilities, 0}, {:deliver, 2}, {:test, 2}, {:validate_config, 1}]

  @doc """
  Classifies an HTTP status into a transport disposition.

  Retryable: 408, 429, and every 5xx. Everything else that is not a 2xx is
  permanent, which is what keeps a 400 from consuming five attempts against a
  payload that will never be accepted.
  """
  @spec classify_http_status(integer()) :: Result.disposition()
  def classify_http_status(status) when is_integer(status) and status >= 200 and status < 300 do
    :delivered
  end

  def classify_http_status(status) when status in [408, 429], do: :retryable_failure

  def classify_http_status(status) when is_integer(status) and status >= 500 do
    :retryable_failure
  end

  def classify_http_status(status) when is_integer(status), do: :permanent_failure

  @doc """
  Builds a `Result` from an HTTP status, applying `classify_http_status/1`.

  `error_class` defaults to `"http_<status>"`, which is stable enough to group by
  in telemetry and in the Delivery Log.
  """
  @spec result_from_http_status(integer(), keyword()) :: Result.t()
  def result_from_http_status(status, opts \\ []) when is_integer(status) do
    error_class = Keyword.get(opts, :error_class, "http_#{status}")

    case classify_http_status(status) do
      :delivered -> Result.delivered(opts)
      :retryable_failure -> Result.retryable_failure(error_class, opts)
      :permanent_failure -> Result.permanent_failure(error_class, opts)
    end
  end

  @doc """
  True when the capability list satisfies the `send` + `test` requirement.
  """
  @spec declares_required_capabilities?(term()) :: boolean()
  def declares_required_capabilities?(capabilities) when is_list(capabilities) do
    Enum.all?(@required_capabilities, &(&1 in capabilities))
  end

  def declares_required_capabilities?(_capabilities), do: false
end
