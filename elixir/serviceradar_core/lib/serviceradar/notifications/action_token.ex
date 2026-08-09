defmodule ServiceRadar.Notifications.ActionToken do
  @moduledoc """
  Mint and verify the per-delivery, per-action capability tokens that make
  `Acknowledge`, `Snooze 1h`, and `Resolve` work from inside a notification
  (design D7 Phase 1).

  This is the mechanism that gets acknowledgement working across email, Slack,
  Discord, generic webhook, and every declarative provider with **zero
  per-provider code**, which is why it ships before native interactive
  components. It deliberately reuses the northbound callback scheme rather than
  inventing one: sha256-only persistence
  (`automation/northbound/dispatcher.ex:456`) and constant-time comparison via
  `Plug.Crypto.secure_compare`
  (`automation/northbound/command_result_handler.ex:180`).

  ## Token shape

      srn1.<selector>.<secret>

  `selector` is 12 random bytes and `secret` is 32, both `Base.url_encode64`
  without padding, so the whole token is 65 URL-safe characters and needs no
  escaping in an `href`.

  The split is what keeps verification an indexed lookup **and** a constant-time
  comparison at the same time. `selector` is stored in the clear and is only an
  address; `secret` is never stored in any form. A single opaque token would
  force either a scan over every live digest or an equality lookup on the
  credential itself.

  ## The digest covers the binding, not just the secret

      token_hash = sha256("srn1|<delivery_id>|<alert_id>|<action>|<secret>")

  Storing `sha256(secret)` alone would make the binding a matter of which columns
  the verifier remembered to compare. Hashing the binding makes it structural:
  the digest of a Snooze capability cannot be reproduced from a Resolve one even
  with the secret in hand, and a row whose `action` or `alert_id` was edited in
  the database no longer verifies against any token that was ever issued.

  Every component is a UUID or a member of a closed atom vocabulary, so no
  component can contain the `|` separator and no delimiter confusion is possible.

  ## Cross-alert binding

  The alert a capability acts on comes from **this row**, never from the request.
  `ServiceRadar.Notifications.ActionRedemption` reads `record.alert_id`; there is
  no code path in which a caller-supplied alert id selects the target. `verify/2`
  additionally accepts `:expect_alert_id`, `:expect_delivery_id`, and
  `:expect_action` for callers that already know what they asked for, which is
  belt and braces rather than the primary defence.

  ## Presenting a token twice is an idempotent success

  A human who clicks `Acknowledge` in an email client and does not see the page
  load will click it again. Worse, some corporate mail scanners and link
  previewers issue a request for **every** URL in a message before a human sees
  it, so a GET-based capability link is fetched by machines as a matter of
  routine.

  Two things follow, and they are separate:

  1. The action-link route MUST NOT act on a GET. Task 1.6.3 requires a
     confirmation interstitial for exactly this reason: the prefetch renders a
     page, the human's POST redeems.
  2. A second presentation of an already-consumed token is
     `{:ok, :already_consumed, record}` - a success, not an error. The caller
     renders "already acknowledged"; nothing is applied a second time.

  Idempotent success does not weaken single use, because single use is a property
  of the **state change**, not of the HTTP request: `consume/2` is a
  compare-and-set inside the UPDATE, so exactly one presentation ever transitions
  the row. Returning an error instead would train operators that the link is
  broken and produce a support ticket for every double-click, while buying no
  security - the bearer already holds the token either way.

  Consumption is therefore checked **before** expiry. A token consumed at noon
  and presented after its TTL still reports what it did rather than "expired": at
  that point the row is a receipt, not a credential, and answering "expired"
  would be both less true and less useful.

  ## Failures do not distinguish "no such token" from "wrong secret"

  Both are `:invalid_token`, and an unknown selector still pays for a decoy
  comparison, so neither timing nor the error body is an oracle for which tokens
  exist. `:token_expired` is only reachable **after** the digest has verified, so
  reporting it distinctly tells a bearer nothing they did not already prove.

  ## Purity

  `mint/2` and `verify_record/3` touch no database and no clock they were not
  given, so the whole decision core is tested `async: true`. `verify/2`,
  `create/2`, and `consume/2` are the thin persistence shell around them.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Notifications.NotificationActionToken

  require Ash.Expr

  @token_version "srn1"
  @separator "."
  @selector_bytes 12
  @secret_bytes 32

  # Encoded sizes, checked before any lookup so a pathological URL is rejected on
  # arithmetic rather than on a query.
  @selector_size 16
  @secret_size 43
  @max_token_size 128

  # Three days, chosen to match the default retention of the alert itself
  # (`ServiceRadar.Jobs.AlertsRetentionWorker`). A capability that outlives the
  # thing it acts on is a liability with no upside.
  @default_ttl_seconds 3 * 24 * 60 * 60

  # A decoy of the right shape, compared against when no row matched so that an
  # unknown selector costs what a known one does.
  @decoy_hash String.duplicate("0", 64)

  @actions [:acknowledge, :snooze, :resolve]

  @type action :: :acknowledge | :snooze | :resolve

  @type binding :: %{
          required(:delivery_id) => String.t(),
          required(:alert_id) => String.t(),
          required(:action) => action(),
          optional(:snooze_seconds) => pos_integer()
        }

  @type failure ::
          :malformed_token
          | :invalid_token
          | :token_unbound
          | :token_expired
          | :action_mismatch
          | :alert_mismatch
          | :delivery_mismatch

  @type verified :: {:ok, :active | :already_consumed, map()}

  defmodule Minted do
    @moduledoc """
    The result of `ServiceRadar.Notifications.ActionToken.mint/2`: the plaintext,
    handed back exactly once, plus the attributes to persist.

    `@derive Inspect` omits `:token`. A struct carrying a live credential ends up
    in a Logger call or an exception report sooner or later, and the one place
    that must never leak is the one place that holds the plaintext.
    """

    @derive {Inspect, except: [:token]}

    @enforce_keys [:token, :selector, :action, :expires_at, :attrs]
    defstruct [:token, :selector, :action, :expires_at, :attrs]

    @type t :: %__MODULE__{
            token: String.t(),
            selector: String.t(),
            action: ServiceRadar.Notifications.ActionToken.action(),
            expires_at: DateTime.t(),
            attrs: map()
          }
  end

  @doc "The closed vocabulary of actions a capability may grant."
  @spec actions() :: [action()]
  def actions, do: @actions

  @doc "The default capability lifetime in seconds."
  @spec default_ttl_seconds() :: pos_integer()
  def default_ttl_seconds, do: @default_ttl_seconds

  @doc """
  Mints one capability for one `{delivery_id, alert_id, action}` triple.

  Returns the plaintext token **once**, inside a `Minted` struct, together with
  the attributes `create/2` persists. Nothing here writes: the caller decides
  whether the row is persisted, which is what lets the whole decision core be
  tested without a database.

  ## Options

    * `:now` - the instant the TTL is measured from. Defaults to
      `DateTime.utc_now/0`; supply it to keep a test deterministic.
    * `:ttl_seconds` - capability lifetime, default #{@default_ttl_seconds}.
    * `:snooze_seconds` - required for `:snooze`, rejected otherwise. The
      duration is bound into the token so it cannot be chosen by whoever clicks.

  ## Examples

      iex> {:ok, minted} =
      ...>   ServiceRadar.Notifications.ActionToken.mint(%{
      ...>     delivery_id: "0199a0e8-0000-7000-8000-000000000001",
      ...>     alert_id: "0199a0e8-0000-7000-8000-000000000002",
      ...>     action: :acknowledge
      ...>   })
      iex> String.starts_with?(minted.token, "srn1.")
      true
      iex> Map.has_key?(minted.attrs, :token_hash) and not Map.has_key?(minted.attrs, :token)
      true
  """
  @spec mint(binding(), keyword()) :: {:ok, Minted.t()} | {:error, term()}
  def mint(binding, opts \\ [])

  def mint(binding, opts) when is_map(binding) and is_list(opts) do
    with {:ok, delivery_id} <- required_uuid(binding, :delivery_id),
         {:ok, alert_id} <- required_uuid(binding, :alert_id),
         {:ok, action} <- required_action(binding),
         {:ok, snooze_seconds} <- snooze_seconds(binding, opts, action),
         {:ok, ttl_seconds} <- ttl_seconds(opts) do
      selector = random(@selector_bytes)
      secret = random(@secret_bytes)
      expires_at = DateTime.add(now(opts), ttl_seconds, :second)

      attrs = %{
        selector: selector,
        token_hash: digest(delivery_id, alert_id, action, secret),
        delivery_id: delivery_id,
        alert_id: alert_id,
        action: action,
        snooze_seconds: snooze_seconds,
        expires_at: expires_at
      }

      {:ok,
       %Minted{
         token: Enum.join([@token_version, selector, secret], @separator),
         selector: selector,
         action: action,
         expires_at: expires_at,
         attrs: attrs
       }}
    end
  end

  def mint(_binding, _opts), do: {:error, :invalid_binding}

  @doc """
  Splits a presented token into its public selector and its secret half.

  Fails closed on anything that is not exactly the shape `mint/2` emits, so a
  pathological URL is rejected on sizes before it can reach a query.
  """
  @spec parse(term()) :: {:ok, %{selector: String.t(), secret: String.t()}} | {:error, failure()}
  def parse(token) when is_binary(token) and byte_size(token) <= @max_token_size do
    case String.split(token, @separator) do
      [@token_version, selector, secret]
      when byte_size(selector) == @selector_size and byte_size(secret) == @secret_size ->
        {:ok, %{selector: selector, secret: secret}}

      _other ->
        {:error, :malformed_token}
    end
  end

  def parse(_token), do: {:error, :malformed_token}

  @doc """
  Verifies a presented token against an already-loaded record. Pure.

  Order matters and is deliberate:

  1. shape, then binding completeness - a row whose alert was pruned authorises
     nothing;
  2. the constant-time digest comparison, so nothing below leaks to a bearer who
     failed it;
  3. the caller's stated expectations, if any;
  4. consumption - a spent token reports what it did rather than what it could
     have done (see the moduledoc on double clicks and mail scanners);
  5. expiry, last, because it is only meaningful for a capability that is still
     one.

  ## Options

    * `:now` - the instant expiry is measured against. Defaults to
      `DateTime.utc_now/0`.
    * `:expect_action`, `:expect_alert_id`, `:expect_delivery_id` - assertions
      for a caller that already knows what it asked for.
  """
  @spec verify_record(map() | nil, String.t(), keyword()) :: verified() | {:error, failure()}
  def verify_record(record, token, opts \\ [])

  def verify_record(record, token, opts) when is_map(record) and is_binary(token) do
    with {:ok, %{secret: secret}} <- parse(token),
         {:ok, bound} <- binding_of(record),
         :ok <- compare(record, bound, secret),
         :ok <- expectations(bound, opts) do
      settle(record, opts)
    end
  end

  def verify_record(_record, _token, _opts), do: {:error, :invalid_token}

  @doc """
  Loads the record addressed by a presented token and verifies it.

  An unknown selector still pays for a decoy comparison and returns
  `:invalid_token`, the same failure a wrong secret produces, so neither the
  response nor the timing enumerates which capabilities exist.

  Options are those of `verify_record/3` plus `:actor`.
  """
  @spec verify(term(), keyword()) :: verified() | {:error, failure()}
  def verify(token, opts \\ []) do
    with {:ok, %{selector: selector, secret: secret}} <- parse(token),
         {:ok, record} <- load(selector, secret, opts) do
      verify_record(record, token, opts)
    end
  end

  @doc """
  Persists a minted capability.

  Takes the `Minted` struct so the plaintext cannot be passed to the data layer
  by accident: only `minted.attrs` is handed over, and it holds the digest.
  """
  @spec create(Minted.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def create(%Minted{attrs: attrs}, opts \\ []) do
    NotificationActionToken
    |> Ash.Changeset.for_create(:mint, attrs, actor: actor(opts))
    |> Ash.create()
  end

  @doc """
  Burns a capability, exactly once.

  `is_nil(consumed_at)` rides inside the `UPDATE` as a changeset filter, so two
  concurrent redemptions of one token produce one winner and one
  `{:error, :already_consumed}`. The loser is not a failure the caller should
  surface as one - see `ActionRedemption`, which reports it as the same
  idempotent success a replay gets.

  The filter is applied **here**, on the changeset the caller builds, and not as
  `change filter(...)` inside `update :consume`. That is load bearing:
  `Ash.Changeset.filter/2` records `added_filter` only while `phase == :pending`
  (`ash/changeset.ex:7687`) and changes run in phase `:validate`, after which the
  atomic path overwrites the atomic changeset's filter with the original
  changeset's `added_filter` (`ash/actions/update/update.ex:155`) - nil. A
  change-declared filter on an atomic action therefore compiles, reads correctly,
  and issues an UPDATE with no precondition at all. This is the same shape as the
  `after_action`-inside-`change/3` trap, and it fails just as quietly.

  Pass `return_notifications?: true` when calling inside a transaction, and send
  what comes back once it commits; Ash warns loudly on every missed notification
  otherwise, and an acknowledgement path that logs two warnings per click is a
  paper cut operators will report as a bug.
  """
  @spec consume(struct(), keyword()) ::
          {:ok, struct()} | {:ok, struct(), list()} | {:error, :already_consumed | term()}
  def consume(record, opts \\ []) do
    record
    |> Ash.Changeset.for_update(:consume, %{}, actor: actor(opts))
    |> Ash.Changeset.filter(Ash.Expr.expr(is_nil(consumed_at)))
    |> Ash.update(return_notifications?: Keyword.get(opts, :return_notifications?, false))
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:ok, updated, notifications} -> {:ok, updated, notifications}
      {:error, error} -> {:error, consume_error(error)}
    end
  end

  @doc """
  Collapses a verification failure into what a response body may say.

  `:expired` survives as its own answer because it is actionable ("open the alert
  in ServiceRadar") and is only reachable by a bearer who already proved they
  hold a real token. Everything else becomes `:invalid`, so the endpoint cannot
  be used to enumerate deliveries, alerts, or actions.
  """
  @spec public_reason(failure()) :: :expired | :invalid
  def public_reason(:token_expired), do: :expired
  def public_reason(_reason), do: :invalid

  # --- minting inputs -------------------------------------------------------

  defp required_uuid(binding, key) do
    case fetch(binding, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_binding, key}}
    end
  end

  defp required_action(binding) do
    case fetch(binding, :action) do
      action when action in @actions -> {:ok, action}
      other -> {:error, {:unknown_action, other}}
    end
  end

  defp snooze_seconds(binding, opts, :snooze) do
    case Keyword.get(opts, :snooze_seconds) || fetch(binding, :snooze_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> {:ok, seconds}
      _other -> {:error, :missing_snooze_seconds}
    end
  end

  defp snooze_seconds(_binding, _opts, _action), do: {:ok, nil}

  defp ttl_seconds(opts) do
    case Keyword.get(opts, :ttl_seconds, @default_ttl_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> {:ok, seconds}
      other -> {:error, {:invalid_ttl_seconds, other}}
    end
  end

  # --- verification ---------------------------------------------------------

  defp binding_of(record) do
    delivery_id = fetch(record, :delivery_id)
    alert_id = fetch(record, :alert_id)
    action = fetch(record, :action)

    if is_binary(delivery_id) and is_binary(alert_id) and action in @actions do
      {:ok, %{delivery_id: delivery_id, alert_id: alert_id, action: action}}
    else
      {:error, :token_unbound}
    end
  end

  defp compare(record, bound, secret) do
    expected = digest(bound.delivery_id, bound.alert_id, bound.action, secret)
    stored = fetch(record, :token_hash)

    if is_binary(stored) and byte_size(stored) == byte_size(expected) and
         Plug.Crypto.secure_compare(stored, expected) do
      :ok
    else
      {:error, :invalid_token}
    end
  end

  defp expectations(bound, opts) do
    with :ok <- expect(opts, :expect_action, bound.action, :action_mismatch),
         :ok <- expect(opts, :expect_alert_id, bound.alert_id, :alert_mismatch) do
      expect(opts, :expect_delivery_id, bound.delivery_id, :delivery_mismatch)
    end
  end

  defp expect(opts, key, actual, failure) do
    case Keyword.get(opts, key) do
      nil -> :ok
      ^actual -> :ok
      _other -> {:error, failure}
    end
  end

  defp settle(record, opts) do
    cond do
      not is_nil(fetch(record, :consumed_at)) -> {:ok, :already_consumed, record}
      expired?(record, opts) -> {:error, :token_expired}
      true -> {:ok, :active, record}
    end
  end

  defp expired?(record, opts) do
    case fetch(record, :expires_at) do
      %DateTime{} = expires_at -> DateTime.compare(now(opts), expires_at) != :lt
      _other -> true
    end
  end

  defp load(selector, secret, opts) do
    case NotificationActionToken.get_by_selector(selector, actor: actor(opts)) do
      {:ok, %{} = record} -> {:ok, record}
      _other -> decoy(secret)
    end
  end

  # An unknown selector must cost what a known one does. The comparison is
  # discarded; running it at all is the point.
  defp decoy(secret) do
    _ = Plug.Crypto.secure_compare(@decoy_hash, digest(@decoy_hash, @decoy_hash, :none, secret))
    {:error, :invalid_token}
  end

  defp consume_error(error) do
    if stale_record?(error), do: :already_consumed, else: error
  end

  defp stale_record?(%Ash.Error.Changes.StaleRecord{}), do: true

  defp stale_record?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &stale_record?/1)

  defp stale_record?(_error), do: false

  # --- primitives -----------------------------------------------------------

  # Every component is a UUID or a member of a closed atom vocabulary, so none can
  # contain the separator and the encoding is unambiguous.
  defp digest(delivery_id, alert_id, action, secret) do
    message = Enum.join([@token_version, delivery_id, alert_id, to_string(action), secret], "|")

    :sha256
    |> :crypto.hash(message)
    |> Base.encode16(case: :lower)
  end

  defp random(bytes) do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> now
      _other -> DateTime.utc_now()
    end
  end

  defp actor(opts) do
    Keyword.get(opts, :actor) || SystemActor.system(:notification_action_token)
  end

  # Records arrive as Ash structs and bindings as plain maps with atom or string
  # keys. No atom is ever created from an input.
  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch(_map, _key), do: nil
end
