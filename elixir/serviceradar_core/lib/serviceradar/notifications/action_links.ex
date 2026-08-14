defmodule ServiceRadar.Notifications.ActionLinks do
  @moduledoc """
  Builds the `opts[:links]` map `ServiceRadar.Notifications.Renderer` accepts, and
  is the only place a capability token is turned into a URL (design D7 Phase 1).

  Three action links plus one plain deep link:

      %{
        "acknowledge" => "https://.../api/notifications/actions/srn1.<selector>.<secret>",
        "snooze"      => "https://.../api/notifications/actions/srn1....",
        "resolve"     => "https://.../api/notifications/actions/srn1....",
        "alert"       => "https://.../alerts/<alert_id>"
      }

  `links.alert` carries no capability and is present for every destination,
  including the ones exempt from action links: a subscriber still needs somewhere
  to go.

  ## The action is in the token, not in the URL

  The path names no action and no alert. Both are bound into the token and read
  back off the persisted row, so editing the URL cannot turn a Snooze link into a
  Resolve, and cannot retarget either at a different alert. That is one fewer
  parameter for the controller to validate and one fewer way to get it wrong.

  ## The `:stream` provider is exempt, structurally (design D7, C2)

  A capability token is a single-use credential scoped to one delivery. The
  firehose is a broadcast to every subscriber authorised for the topic, so
  embedding one there hands an acknowledgement credential to every listener at
  once - and the first to click it consumes it, leaving the rest a dead link and
  the alert acknowledged by an unattributable actor.

  The exemption is enforced by construction rather than by remembering to pass a
  flag:

    * `build/3` requires the provider and routes on `provider_type` through an
      **allowlist**, `#{inspect([:native, :declarative, :wasm_plugin])}`. A
      denylist of `:stream` would silently issue tokens to whatever fifth
      provider type is added next; an allowlist makes the safe answer the
      default, and a new tier has to be added here deliberately.
    * The exempt branch calls `broadcast_links/2`, which has no reference to
      `ActionToken` in its call graph. There is no code path from a `:stream`
      channel to a minted token to fail to take.
    * `issue/3` persists `token_attrs/1`, which is `[]` for an exempt set, so a
      `:stream` channel never writes to `notification_action_tokens` at all.
    * `to_renderer_opts/1` derives `include_action_links?` from the struct rather
      than from the caller, so the renderer drops the three action names from the
      variable context and a hand-written template cannot reintroduce one.

  `ServiceRadar.Notifications.Transports.Stream` then strips action links a
  second time from the payload it is handed. That belt-and-braces is deliberate
  and is documented there: an invariant that depends on its caller remembering is
  not an invariant.

  ## Without a configured base URL there are no links, and that is visible

  A notification is worth sending with no links; a notification carrying
  `/api/notifications/actions/...` as a bare path is not - it is a dead link in
  an email client, and it looks like a bug in the platform rather than in the
  deployment. So an unconfigured base URL yields an empty link set with
  `exempt_reason: :base_url_unconfigured`, the delivery still goes out, and the
  reason is on the struct for a caller that wants to warn.

  Configure `:notification_action_base_url` (or
  `SERVICERADAR_NOTIFICATION_ACTION_BASE_URL`), matching the northbound callback
  base URL it sits beside.

  ## Purity

  `build/3` mints and formats but writes nothing, so link shape, the exemption,
  and the token binding are all tested `async: true`. `issue/3` is the thin
  persistence shell.
  """

  alias ServiceRadar.Notifications.ActionToken

  @action_path "/api/notifications/actions/"
  @alert_path "/alerts/"

  # The allowlist, not a `:stream` denylist. See the moduledoc.
  @token_bearing_provider_types [:native, :declarative, :wasm_plugin]

  # "Snooze 1h" is the label `Renderers.Content` renders; this is the duration it
  # means. It is bound into the token so it cannot be chosen by whoever clicks.
  @default_snooze_seconds 3600

  @actions [:acknowledge, :snooze, :resolve]

  defstruct links: %{},
            minted: [],
            action_links?: false,
            exempt_reason: nil,
            alert_id: nil,
            delivery_id: nil

  @type t :: %__MODULE__{
          links: %{optional(String.t()) => String.t()},
          minted: [ActionToken.Minted.t()],
          action_links?: boolean(),
          exempt_reason:
            nil
            | :stream_provider
            | :unknown_provider_type
            | :base_url_unconfigured
            | :unbindable_delivery,
          alert_id: String.t() | nil,
          delivery_id: String.t() | nil
        }

  @doc "The default `Snooze 1h` duration, in seconds."
  @spec default_snooze_seconds() :: pos_integer()
  def default_snooze_seconds, do: @default_snooze_seconds

  @doc "Provider types that may carry a capability token."
  @spec token_bearing_provider_types() :: [atom()]
  def token_bearing_provider_types, do: @token_bearing_provider_types

  @doc """
  Builds the link set for one delivery. Pure: nothing is persisted.

  `provider` is required, because whether a token may be minted at all is a
  property of the destination and not of the caller's intent.

  ## Options

    * `:base_url` - overrides the configured base URL.
    * `:snooze_seconds` - the duration the Snooze capability grants, default
      #{@default_snooze_seconds}.
    * `:ttl_seconds` - capability lifetime, default
      `ActionToken.default_ttl_seconds/0`.
    * `:actions` - a subset of `#{inspect(@actions)}` to mint. Anything outside
      that vocabulary is dropped rather than minted.
    * `:now` - the instant TTLs are measured from.
  """
  @spec build(map(), map() | nil, keyword()) :: t()
  def build(delivery, provider, opts \\ [])

  def build(delivery, provider, opts) when is_map(delivery) and is_list(opts) do
    case provider_type(provider) do
      type when type in @token_bearing_provider_types -> minted_links(delivery, opts)
      :stream -> broadcast_links(delivery, opts, :stream_provider)
      _other -> broadcast_links(delivery, opts, :unknown_provider_type)
    end
  end

  def build(_delivery, _provider, _opts), do: %__MODULE__{}

  @doc """
  Builds a link set and persists the capabilities it minted.

  An exempt destination persists nothing, because `token_attrs/1` is empty for
  one - a `:stream` channel never reaches the token table.

  Options are those of `build/3` plus `:actor`.
  """
  @spec issue(map(), map() | nil, keyword()) :: {:ok, t()} | {:error, term()}
  def issue(delivery, provider, opts \\ []) do
    links = build(delivery, provider, opts)

    Enum.reduce_while(links.minted, {:ok, links}, fn minted, acc ->
      case ActionToken.create(minted, opts) do
        {:ok, _record} -> {:cont, acc}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  The renderer options this link set implies.

  `include_action_links?` comes from the struct, never from the caller, which is
  what makes the `:stream` exemption survive a caller that forgets it.
  """
  @spec to_renderer_opts(t()) :: keyword()
  def to_renderer_opts(%__MODULE__{} = links) do
    [links: links.links, include_action_links?: links.action_links?]
  end

  @doc """
  The plaintext tokens this set embedded, for `Renderer`'s `:sensitive_values`.

  `ActionRedaction` matches on key names, and a token inside a `url` value has no
  sensitive key to match, so the redacted payload that gets persisted and
  displayed needs this second, value-based pass. Without it the Delivery Log
  would store live capabilities in plain text.
  """
  @spec sensitive_values(t()) :: [String.t()]
  def sensitive_values(%__MODULE__{minted: minted}), do: Enum.map(minted, & &1.token)

  @doc "The attributes to persist, one per minted capability. Empty when exempt."
  @spec token_attrs(t()) :: [map()]
  def token_attrs(%__MODULE__{minted: minted}), do: Enum.map(minted, & &1.attrs)

  @doc """
  The configured base URL for action links, or nil.

  Nil is not an error here; see the moduledoc for what an unconfigured
  deployment renders.
  """
  @spec base_url() :: String.t() | nil
  def base_url do
    presence(Application.get_env(:serviceradar_core, :notification_action_base_url)) ||
      presence(System.get_env("SERVICERADAR_NOTIFICATION_ACTION_BASE_URL"))
  end

  @doc "The path an action link points at. The token is the whole address."
  @spec action_path(String.t()) :: String.t()
  def action_path(token) when is_binary(token), do: @action_path <> token

  # --- token-bearing destinations -------------------------------------------

  defp minted_links(delivery, opts) do
    alert_id = field(delivery, :alert_id)
    delivery_id = field(delivery, :id)

    case {resolved_base_url(opts), alert_id, delivery_id} do
      {nil, _alert_id, _delivery_id} ->
        broadcast_links(delivery, opts, :base_url_unconfigured)

      # A capability binds to BOTH a delivery and an alert. With either missing
      # there is nothing to bind to, so no token is minted; the deep link, which
      # binds to nothing, still stands on its own.
      {_base, nil, _delivery_id} ->
        broadcast_links(delivery, opts, :unbindable_delivery)

      {_base, _alert_id, nil} ->
        broadcast_links(delivery, opts, :unbindable_delivery)

      {base, alert_id, delivery_id} ->
        mint_all(base, alert_id, delivery_id, opts)
    end
  end

  defp mint_all(base, alert_id, delivery_id, opts) do
    minted =
      opts
      |> requested_actions()
      |> Enum.flat_map(fn action ->
        binding = %{delivery_id: delivery_id, alert_id: alert_id, action: action}

        case ActionToken.mint(binding, mint_opts(action, opts)) do
          {:ok, minted} -> [minted]
          {:error, _reason} -> []
        end
      end)

    links =
      Enum.reduce(minted, alert_link(base, alert_id), fn token, acc ->
        Map.put(acc, Atom.to_string(token.action), url(base, action_path(token.token)))
      end)

    %__MODULE__{
      links: links,
      minted: minted,
      action_links?: minted != [],
      exempt_reason: nil,
      alert_id: alert_id,
      delivery_id: delivery_id
    }
  end

  defp mint_opts(:snooze, opts) do
    snooze_seconds =
      case Keyword.get(opts, :snooze_seconds, @default_snooze_seconds) do
        seconds when is_integer(seconds) and seconds > 0 -> seconds
        _other -> @default_snooze_seconds
      end

    Keyword.put(mint_opts(nil, opts), :snooze_seconds, snooze_seconds)
  end

  defp mint_opts(_action, opts), do: Keyword.take(opts, [:now, :ttl_seconds])

  defp requested_actions(opts) do
    case Keyword.get(opts, :actions) do
      nil -> @actions
      requested when is_list(requested) -> Enum.filter(@actions, &(&1 in requested))
      _other -> @actions
    end
  end

  # --- exempt destinations --------------------------------------------------

  # Deliberately has no call into ActionToken. The exemption is what this
  # function IS, not a branch inside a function that could also mint.
  defp broadcast_links(delivery, opts, reason) do
    alert_id = field(delivery, :alert_id)

    links =
      case {resolved_base_url(opts), alert_id} do
        {nil, _alert_id} -> %{}
        {_base, nil} -> %{}
        {base, alert_id} -> alert_link(base, alert_id)
      end

    %__MODULE__{
      links: links,
      minted: [],
      action_links?: false,
      exempt_reason: reason,
      alert_id: alert_id,
      delivery_id: field(delivery, :id)
    }
  end

  # --- helpers --------------------------------------------------------------

  defp alert_link(base, alert_id), do: %{"alert" => url(base, @alert_path <> alert_id)}

  defp url(base, path) do
    base |> URI.parse() |> URI.merge(path) |> URI.to_string()
  end

  defp resolved_base_url(opts) do
    case Keyword.fetch(opts, :base_url) do
      {:ok, value} -> presence(value)
      :error -> base_url()
    end
  end

  defp provider_type(provider) when is_map(provider) do
    case field(provider, :provider_type) do
      type when is_atom(type) -> type
      _other -> nil
    end
  end

  defp provider_type(_provider), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  # Deliveries and providers arrive as Ash structs in the pipeline and as plain
  # maps in tests. No atom is ever created from an input.
  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_map, _key), do: nil
end
