defmodule ServiceRadar.WebRTC.IceCredentials do
  @moduledoc """
  Shared ICE credential provider for WebRTC viewers (camera relay and
  remote desktop).

  A behaviour plus a dispatcher, both loaded by the web-ng and core-elx
  releases. Callers mint per-viewer TURN credentials through `mint/2`;
  the configured backend produces the ICE servers for the signaling
  response (browser side) or the peer configuration (core side).

  Configuration (`config :serviceradar_core, #{__MODULE__}`):

    * `:backend` — `:none` (default; `mint/2` returns
      `{:error, :no_backend}`), `:static_secret`, or `:cloudflare`.
    * `:default_ttl_seconds` — default 600, bounded to `60..3600`.
    * `:rate_limit` — per-actor/per-session mint limit,
      `%{max_mints: pos_integer(), window_seconds: pos_integer()}`,
      default `%{max_mints: 30, window_seconds: 60}`. Exceeding it returns
      `{:error, :rate_limited}`.

  ## Subject binding

  The subject binds one credential to one viewer:
  `{feature, session_id, viewer_id}`. By default the TURN username embeds
  the expiry and a non-reversible digest of the subject — never raw user or
  session identifiers. Remote desktop opts into its legacy raw binding
  (`legacy_subject: true`) because its shipped username format predates
  this provider and stays byte-identical.

  `ServiceRadar.WebRTC.IceCredentials.StaticSecret` implements the TURN
  REST scheme (`username = "<unix_expiry>:<subject>"`,
  `credential = base64(HMAC-SHA1(secret, username))`) that both coturn
  `use-auth-secret` and eturnal `secret` verify.
  """

  @behaviour __MODULE__

  alias ServiceRadar.WebRTC.IceCredentials.MintLimiter

  require Logger

  @min_ttl_seconds 60
  @max_ttl_seconds 3_600
  @default_ttl_seconds 600

  @doc """
  Mints ICE servers for one viewer session.

  `subject` is `{feature, session_id, viewer_id}` (any binary parts) or,
  when a caller supplies `:legacy_subject`, the exact subject string the
  legacy TURN REST username must embed (remote desktop's
  `"actor:session:viewer"` form).

  Returns `{:ok, %{ice_servers: [...], expires_at: DateTime.t()}}` or
  `{:error, reason}` with reason class `:no_backend`, `:rate_limited`,
  `:missing_binding`, `:missing_secret` or a backend-specific reason.
  """
  @callback mint(subject :: term(), opts :: keyword()) ::
              {:ok, %{ice_servers: list(), expires_at: DateTime.t()}} | {:error, term()}

  @doc """
  Dispatches `mint/2` to the configured backend after TTL normalization,
  subject binding and the per-actor/per-session rate limit.
  """
  @spec mint(term(), keyword()) ::
          {:ok, %{ice_servers: list(), expires_at: DateTime.t()}} | {:error, term()}
  def mint(subject, opts \\ []) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    with :ok <- MintLimiter.check(config, opts),
         {:ok, ttl} <- ttl_seconds(config, opts) do
      case Keyword.get(config, :backend, :none) do
        :none ->
          {:error, :no_backend}

        backend when is_atom(backend) ->
          case backend_module(backend) do
            {:ok, module} ->
              opts = opts |> Keyword.put(:ttl_seconds, ttl) |> put_subject(subject, config)
              module.mint(normalized_subject(subject), opts)

            {:error, reason} ->
              {:error, reason}
          end

        _other ->
          {:error, :invalid_backend}
      end
    end
  end

  @doc """
  The subject digest embedded in TURN usernames for non-legacy callers:
  a non-reversible SHA-256 digest of a length-prefixed encoding of the
  subject tuple, hex-encoded and truncated to 32 characters. Raw user or
  session identifiers never reach the username.
  """
  @spec subject_digest({feature :: binary(), session_id :: binary(), viewer_id :: binary()}) ::
          String.t()
  def subject_digest({feature, session_id, viewer_id})
      when is_binary(feature) and is_binary(session_id) and is_binary(viewer_id) do
    payload =
      <<byte_size(feature)::32, feature::binary, byte_size(session_id)::32, session_id::binary,
        byte_size(viewer_id)::32, viewer_id::binary>>

    :sha256
    |> :crypto.hash(payload)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  @doc false
  def min_ttl_seconds, do: @min_ttl_seconds

  @doc false
  def max_ttl_seconds, do: @max_ttl_seconds

  @doc false
  def default_ttl_seconds, do: @default_ttl_seconds

  defp normalized_subject({feature, session_id, viewer_id} = subject)
       when is_binary(feature) and is_binary(session_id) and is_binary(viewer_id), do: subject

  defp normalized_subject(_), do: nil

  defp put_subject(opts, {feature, session_id, viewer_id} = subject, _config)
       when is_binary(feature) and is_binary(session_id) and is_binary(viewer_id) do
    if opts[:legacy_subject] do
      opts
    else
      Keyword.put(opts, :subject_digest, subject_digest(subject))
    end
  end

  defp put_subject(opts, subject, _config) when is_binary(subject) do
    # Legacy raw subject string (remote desktop): passed through verbatim.
    if opts[:legacy_subject], do: Keyword.put(opts, :legacy_subject_value, subject), else: opts
  end

  defp put_subject(opts, _subject, _config), do: Keyword.put(opts, :subject_missing, true)

  defp ttl_seconds(config, opts) do
    requested = Keyword.get(opts, :ttl_seconds) || Keyword.get(config, :default_ttl_seconds)

    case requested do
      seconds when is_integer(seconds) and seconds > 0 ->
        {:ok, min(max(seconds, @min_ttl_seconds), @max_ttl_seconds)}

      _other ->
        {:ok, @default_ttl_seconds}
    end
  end

  defp backend_module(:static_secret), do: {:ok, ServiceRadar.WebRTC.IceCredentials.StaticSecret}
  # Task 1.3 adds the Cloudflare backend; this slice only reserves the atom.
  defp backend_module(:cloudflare), do: {:error, :invalid_backend}
  defp backend_module(_other), do: {:error, :invalid_backend}
end

defmodule ServiceRadar.WebRTC.IceCredentials.MintLimiter do
  @moduledoc false

  use GenServer

  @table :webrtc_ice_mint_counters
  @default_limit %{max_mints: 30, window_seconds: 60}

  def check(config, opts) do
    with {:ok, key} <- rate_key(opts) do
      GenServer.call(__MODULE__, {:check, key, limit(config)})
    end
  end

  defp limit(config) do
    case Keyword.get(config, :rate_limit) do
      %{max_mints: m, window_seconds: w}
      when is_integer(m) and m > 0 and is_integer(w) and w > 0 ->
        %{max_mints: m, window_seconds: w}

      _other ->
        @default_limit
    end
  end

  defp rate_key(opts) do
    actor_id = normalize(Keyword.get(opts, :actor_id))
    session_id = normalize(Keyword.get(opts, :session_id))

    if is_binary(actor_id) and is_binary(session_id) do
      {:ok, {actor_id, session_id}}
    else
      {:error, :missing_binding}
    end
  end

  defp normalize(value) when is_binary(value),
    do: value |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))

  defp normalize(_), do: nil

  @impl GenServer
  def init(:ok) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, table}
  end

  @impl GenServer
  def handle_call(
        {:check, key, %{max_mints: max_mints, window_seconds: window_seconds}},
        _from,
        table
      ) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - window_seconds * 1_000
    drop_idle_keys(cutoff)

    queue =
      case :ets.lookup(@table, key) do
        [{^key, existing}] -> existing
        [] -> :queue.new()
      end

    if :queue.len(queue) >= max_mints do
      {:reply, {:error, :rate_limited}, table}
    else
      :ets.insert(@table, {key, :queue.in(now, queue)})
      {:reply, :ok, table}
    end
  end

  defp drop_idle_keys(cutoff) do
    @table
    |> :ets.tab2list()
    |> Enum.each(fn {key, queue} ->
      pruned = prune_deque(queue, cutoff)

      if :queue.is_empty(pruned) do
        :ets.delete(@table, key)
      else
        :ets.insert(@table, {key, pruned})
      end
    end)
  end

  defp prune_deque(queue, cutoff) do
    case :queue.out(queue) do
      {{:value, timestamp}, rest} when timestamp < cutoff -> prune_deque(rest, cutoff)
      _still_live -> queue
    end
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end
end
