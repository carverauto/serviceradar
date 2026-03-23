defmodule ServiceRadar.Camera.RelaySessionLifecycle do
  @moduledoc """
  Synchronizes media-plane ingress events into persisted camera relay sessions.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RelaySession

  @default_actor_component :camera_relay_session_lifecycle

  @spec activate_session(String.t(), String.t(), map(), keyword()) ::
          {:ok, RelaySession.t() | map()} | {:error, term()}
  def activate_session(relay_session_id, media_ingest_id, attrs \\ %{}, opts \\ []) do
    with {:ok, session} <- fetch_session(relay_session_id, opts),
         :ok <- ensure_status(session, [:requested, :opening, :active]),
         :ok <- ensure_media_ingest_id(session, media_ingest_id),
         {:ok, normalized_attrs} <- activation_attrs(media_ingest_id, attrs) do
      if Map.get(session, :status) == :active do
        renew_lease_session(session, normalized_attrs, opts)
      else
        activate_session_record(session, normalized_attrs, opts)
      end
    end
  end

  @spec heartbeat_session(String.t(), String.t(), map(), keyword()) ::
          {:ok, RelaySession.t() | map()} | {:error, term()}
  def heartbeat_session(relay_session_id, media_ingest_id, attrs \\ %{}, opts \\ []) do
    with {:ok, session} <- fetch_session(relay_session_id, opts),
         :ok <- ensure_status(session, [:opening, :active]),
         :ok <- ensure_media_ingest_id(session, media_ingest_id),
         {:ok, normalized_attrs} <- lease_attrs(attrs) do
      renew_lease_session(session, normalized_attrs, opts)
    end
  end

  @spec close_session(String.t(), String.t(), map(), keyword()) ::
          {:ok, RelaySession.t() | map()} | {:error, term()}
  def close_session(relay_session_id, media_ingest_id, attrs \\ %{}, opts \\ []) do
    with {:ok, session} <- fetch_session(relay_session_id, opts),
         :ok <- ensure_media_ingest_id(session, media_ingest_id) do
      case Map.get(session, :status) do
        status when status in [:closed, :failed] ->
          {:ok, session}

        status when status in [:requested, :opening, :active, :closing] ->
          close_session_record(session, %{close_reason: close_reason(attrs)}, opts)

        status ->
          {:error, {:invalid_status, status}}
      end
    end
  end

  @spec fail_session(String.t(), String.t(), map(), keyword()) ::
          {:ok, RelaySession.t() | map()} | {:error, term()}
  def fail_session(relay_session_id, media_ingest_id, attrs \\ %{}, opts \\ []) do
    with {:ok, session} <- fetch_session(relay_session_id, opts),
         :ok <- ensure_media_ingest_id(session, media_ingest_id) do
      fail_session_record(
        session,
        %{
          failure_reason: failure_reason(attrs),
          close_reason: close_reason(attrs)
        },
        opts
      )
    end
  end

  defp fetch_session(relay_session_id, opts) do
    actor = actor(opts)
    fetcher = Keyword.get(opts, :session_fetcher, &fetch_session_record/2)

    case fetcher.(relay_session_id, actor) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, session} -> {:ok, session}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_session_record(relay_session_id, actor) do
    RelaySession.get_by_id(relay_session_id, actor: actor)
  end

  defp activate_session_record(session, attrs, opts) do
    actor = actor(opts)
    activator = Keyword.get(opts, :activator, &run_activate/3)
    activator.(session, attrs, actor)
  end

  defp run_activate(session, attrs, actor) do
    RelaySession.activate(session, attrs, actor: actor)
  end

  defp renew_lease_session(session, attrs, opts) do
    if map_size(attrs) == 0 do
      {:ok, session}
    else
      actor = actor(opts)
      renewer = Keyword.get(opts, :renewer, &run_renew_lease/3)
      renewer.(session, attrs, actor)
    end
  end

  defp run_renew_lease(session, attrs, actor) do
    RelaySession.renew_lease(session, attrs, actor: actor)
  end

  defp close_session_record(session, attrs, opts) do
    actor = actor(opts)
    closer = Keyword.get(opts, :closer, &run_close/3)
    closer.(session, attrs, actor)
  end

  defp run_close(session, attrs, actor) do
    RelaySession.mark_closed(session, attrs, actor: actor)
  end

  defp fail_session_record(session, attrs, opts) do
    actor = actor(opts)
    failer = Keyword.get(opts, :failer, &run_fail/3)
    failer.(session, attrs, actor)
  end

  defp run_fail(session, attrs, actor) do
    RelaySession.fail_session(session, attrs, actor: actor)
  end

  defp activation_attrs(media_ingest_id, attrs) do
    with {:ok, lease_attrs} <- lease_attrs(attrs) do
      {:ok, Map.put(lease_attrs, :media_ingest_id, media_ingest_id)}
    end
  end

  defp lease_attrs(attrs) when is_map(attrs) do
    case normalize_lease_expiry(attrs) do
      {:ok, nil} -> {:ok, %{}}
      {:ok, lease_expires_at} -> {:ok, %{lease_expires_at: lease_expires_at}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lease_attrs(_attrs), do: {:ok, %{}}

  defp normalize_lease_expiry(attrs) when is_map(attrs) do
    cond do
      match?(%DateTime{}, Map.get(attrs, :lease_expires_at)) ->
        {:ok, Map.get(attrs, :lease_expires_at)}

      is_integer(Map.get(attrs, :lease_expires_at_unix)) ->
        DateTime.from_unix(Map.get(attrs, :lease_expires_at_unix), :second)

      true ->
        {:ok, nil}
    end
  end

  defp ensure_status(session, allowed_statuses) do
    if Map.get(session, :status) in allowed_statuses do
      :ok
    else
      {:error, {:invalid_status, Map.get(session, :status)}}
    end
  end

  defp ensure_media_ingest_id(session, media_ingest_id) do
    case Map.get(session, :media_ingest_id) do
      nil -> :ok
      "" -> :ok
      ^media_ingest_id -> :ok
      _other -> {:error, :media_ingest_mismatch}
    end
  end

  defp close_reason(attrs) when is_map(attrs) do
    attrs
    |> Map.get(:close_reason)
    |> blank_to_default("media ingress closed")
  end

  defp close_reason(_attrs), do: "media ingress closed"

  defp failure_reason(attrs) when is_map(attrs) do
    attrs
    |> Map.get(:failure_reason)
    |> blank_to_default("media ingress failure")
  end

  defp failure_reason(_attrs), do: "media ingress failure"

  defp blank_to_default(value, default) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: default, else: value
  end

  defp blank_to_default(nil, default), do: default
  defp blank_to_default(value, _default), do: to_string(value)

  defp actor(opts) do
    Keyword.get(opts, :actor, SystemActor.system(@default_actor_component))
  end
end
