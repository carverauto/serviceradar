defmodule ServiceRadarWebNG.Auth.TokenRevocation do
  @moduledoc """
  Cluster-safe token revocation service backed by CNPG.
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.RevokedToken

  require Ash.Query
  require Logger

  @table :revoked_tokens
  @cleanup_interval to_timeout(hour: 1)
  @default_ttl_seconds 30 * 24 * 60 * 60

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec revoke_token(String.t(), keyword()) :: :ok | {:error, term()}
  def revoke_token(jti, opts \\ []) when is_binary(jti) do
    reason = Keyword.get(opts, :reason, :manual)
    user_id = Keyword.get(opts, :user_id)
    ttl = Keyword.get(opts, :ttl, default_ttl_ms())
    revoked_at = DateTime.utc_now()

    entry = %{
      jti: jti,
      user_id: user_id,
      reason: reason,
      revoked_at: revoked_at,
      expires_at: DateTime.add(revoked_at, ttl, :millisecond)
    }

    case persist_entry(entry) do
      {:ok, persisted} ->
        cache_entry(persisted)
        Logger.info("Token revoked", jti: persisted.jti, user_id: persisted.user_id, reason: persisted.reason)
        :ok

      {:error, reason} = error ->
        Logger.warning("Failed to persist token revocation", jti: entry.jti, reason: inspect(reason))
        error
    end
  end

  @spec check_revoked(String.t() | nil) :: :ok | {:error, :revoked}
  def check_revoked(nil), do: :ok

  def check_revoked(jti) when is_binary(jti) do
    case lookup_active_entry(jti) do
      {:ok, _entry} -> {:error, :revoked}
      :not_found -> :ok
    end
  end

  @spec revoke_all_for_user(String.t(), keyword()) :: :ok | {:error, term()}
  def revoke_all_for_user(user_id, opts \\ []) when is_binary(user_id) do
    reason = Keyword.get(opts, :reason, :user_tokens_revoked)
    revoked_before = DateTime.utc_now()

    entry = %{
      jti: user_marker_jti(user_id),
      user_id: user_id,
      reason: reason,
      revoked_at: revoked_before,
      revoked_before: revoked_before,
      expires_at: DateTime.add(revoked_before, default_ttl_ms(), :millisecond)
    }

    case persist_entry(entry) do
      {:ok, persisted} ->
        cache_entry(persisted)
        Logger.info("Token revoked", jti: persisted.jti, user_id: persisted.user_id, reason: persisted.reason)
        :ok

      {:error, reason} = error ->
        Logger.warning("Failed to persist token revocation", jti: entry.jti, reason: inspect(reason))
        error
    end
  end

  @spec check_user_revoked(String.t(), DateTime.t() | integer() | binary() | nil) ::
          :ok | {:error, :user_revoked}
  def check_user_revoked(_user_id, nil), do: :ok

  def check_user_revoked(user_id, issued_at) when is_binary(user_id) do
    case lookup_active_entry(user_marker_jti(user_id)) do
      {:ok, %{revoked_before: %DateTime{} = revoked_before}} ->
        check_revoked_before(issued_at, revoked_before, user_id)

      _ ->
        :ok
    end
  end

  @spec check_user_tokens_revoked(String.t(), DateTime.t() | integer() | binary() | nil) ::
          :ok | {:error, :user_revoked}
  def check_user_tokens_revoked(user_id, issued_at), do: check_user_revoked(user_id, issued_at)

  @spec get_revocation_info(String.t()) :: {:ok, map()} | :not_found
  def get_revocation_info(jti) when is_binary(jti) do
    case lookup_active_entry(jti) do
      {:ok, entry} -> {:ok, entry}
      :not_found -> :not_found
    end
  end

  @spec clear_revocation(String.t()) :: :ok | {:error, term()}
  def clear_revocation(jti) when is_binary(jti) do
    with :ok <- delete_persisted_entry(jti) do
      maybe_delete_cached_entry(jti)
      :ok
    end
  end

  @impl true
  def init(_opts) do
    reset_cache_table()
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired_entries()
    schedule_cleanup()
    {:noreply, state}
  end

  defp default_ttl_ms, do: @default_ttl_seconds * 1000

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp reset_cache_table do
    case :ets.whereis(@table) do
      :undefined -> :ok
      tid -> :ets.delete(tid)
    end

    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  end

  defp lookup_active_entry(jti) do
    case cached_entry(jti) do
      {:ok, entry} ->
        {:ok, entry}

      :not_found ->
        load_active_entry(jti)
    end
  end

  defp cached_entry(jti) do
    with table when table != :undefined <- :ets.whereis(@table),
         [{^jti, entry}] <- :ets.lookup(table, jti),
         false <- expired?(entry) do
      {:ok, entry}
    else
      true ->
        maybe_delete_cached_entry(jti)
        :not_found

      _ ->
        :not_found
    end
  end

  defp load_active_entry(jti) do
    case active_revocation(jti) do
      {:ok, entry} ->
        cache_entry(entry)
        {:ok, entry}

      :not_found ->
        :not_found
    end
  end

  defp active_revocation(jti) do
    actor = system_actor()

    RevokedToken
    |> Ash.Query.for_read(:active_by_jti, %{jti: jti}, actor: actor)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} ->
        :not_found

      {:ok, record} ->
        {:ok, to_entry(record)}

      {:error, reason} ->
        Logger.warning("Failed to read token revocation", jti: jti, reason: inspect(reason))
        :not_found
    end
  end

  defp persist_entry(entry) do
    actor = system_actor()

    RevokedToken
    |> Ash.Changeset.for_create(:upsert, revocation_attrs(entry), actor: actor)
    |> Ash.create(actor: actor)
    |> case do
      {:ok, record} -> {:ok, to_entry(record)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_persisted_entry(jti) do
    actor = system_actor()

    case RevokedToken.get_by_jti(jti, actor: actor) do
      {:ok, nil} ->
        :ok

      {:ok, record} ->
        case Ash.destroy(record, actor: actor) do
          :ok -> :ok
          {:ok, _destroyed} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup_expired_entries do
    purge_expired_cache_entries()
    purge_expired_db_entries()
  end

  defp purge_expired_cache_entries do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ ->
        now = DateTime.utc_now()

        expired_keys =
          :ets.foldl(
            fn {jti, entry}, acc ->
              collect_expired_cache_key(jti, entry, now, acc)
            end,
            [],
            @table
          )

        Enum.each(expired_keys, &maybe_delete_cached_entry/1)
    end
  end

  defp destroy_expired_records([]), do: :ok

  defp destroy_expired_records(records) do
    records
    |> Ash.bulk_destroy(:destroy, %{}, actor: system_actor(), return_records?: false, return_errors?: true)
    |> case do
      %Ash.BulkResult{status: :error} = result ->
        Logger.warning("Failed to delete expired token revocations", reason: inspect(result))

      _ ->
        :ok
    end
  end

  defp cache_entry(entry) do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {entry.jti, entry})
    end
  end

  defp maybe_delete_cached_entry(jti) do
    if :ets.whereis(@table) != :undefined do
      :ets.delete(@table, jti)
    end
  end

  defp collect_expired_cache_key(jti, entry, now, acc) do
    if expired?(entry, now), do: [jti | acc], else: acc
  end

  defp purge_expired_db_entries do
    actor = system_actor()

    query =
      RevokedToken
      |> Ash.Query.for_read(:expired, %{}, actor: actor)
      |> Ash.Query.limit(500)

    case Ash.read(query, actor: actor) do
      {:ok, []} ->
        :ok

      {:ok, %Ash.Page.Keyset{results: records}} ->
        destroy_expired_records(records)

      {:ok, records} ->
        destroy_expired_records(records)

      {:error, reason} ->
        Logger.warning("Failed to query expired token revocations", reason: inspect(reason))
    end
  end

  defp revocation_attrs(entry) do
    %{
      jti: entry.jti,
      user_id: entry.user_id,
      reason: normalize_reason(entry.reason),
      revoked_at: entry.revoked_at,
      revoked_before: entry[:revoked_before],
      expires_at: entry.expires_at
    }
  end

  defp to_entry(record) do
    %{
      jti: record.jti,
      user_id: record.user_id,
      reason: denormalize_reason(record.reason),
      revoked_at: record.revoked_at,
      revoked_before: record.revoked_before,
      expires_at: record.expires_at
    }
  end

  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason), do: inspect(reason)

  defp denormalize_reason(reason) when is_binary(reason) do
    String.to_existing_atom(reason)
  rescue
    ArgumentError -> reason
  end

  defp denormalize_reason(reason), do: reason

  defp expired?(entry), do: expired?(entry, DateTime.utc_now())

  defp expired?(%{expires_at: %DateTime{} = expires_at}, now) do
    DateTime.before?(expires_at, now)
  end

  defp expired?(_entry, _now), do: false

  defp check_revoked_before(issued_at, revoked_before, user_id) do
    case normalize_issued_at(issued_at) do
      {:ok, issued_at_dt} ->
        if DateTime.before?(issued_at_dt, revoked_before) do
          {:error, :user_revoked}
        else
          :ok
        end

      :error ->
        Logger.warning(
          "Unable to normalize token issued_at for revocation check: " <>
            "issued_at=#{inspect(issued_at)} user_id=#{user_id}"
        )

        {:error, :user_revoked}
    end
  end

  defp normalize_issued_at(%DateTime{} = issued_at), do: {:ok, issued_at}

  defp normalize_issued_at(issued_at) when is_integer(issued_at) do
    DateTime.from_unix(issued_at)
  end

  defp normalize_issued_at(issued_at) when is_float(issued_at) do
    issued_at
    |> trunc()
    |> DateTime.from_unix()
  end

  defp normalize_issued_at(issued_at) when is_binary(issued_at) do
    case Integer.parse(issued_at) do
      {unix, ""} -> DateTime.from_unix(unix)
      _ -> :error
    end
  end

  defp normalize_issued_at(_issued_at), do: :error

  defp system_actor, do: SystemActor.system(:token_revocation)
  defp user_marker_jti(user_id), do: "user:#{user_id}:all"
end
