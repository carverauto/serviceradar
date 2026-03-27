defmodule ServiceRadar.Camera.RelaySessionManager do
  @moduledoc """
  Opens and closes camera relay sessions from the core control plane.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RelayHealthEventRouter
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Edge.AgentCommandBus

  @default_lease_ttl_seconds 30

  @spec request_open(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, RelaySession.t() | map()} | {:error, term()}
  def request_open(camera_source_id, stream_profile_id, opts \\ []) do
    do_open_session(camera_source_id, stream_profile_id, opts)
  end

  @spec open_session(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, RelaySession.t() | map()} | {:error, term()}
  def open_session(camera_source_id, stream_profile_id, opts \\ []) do
    request_open(camera_source_id, stream_profile_id, opts)
  end

  defp do_open_session(camera_source_id, stream_profile_id, opts) do
    requester = resolve_requester(opts)
    read_ash_opts = read_ash_opts(opts, requester)
    write_actor = resolve_write_actor(opts)
    write_ash_opts = write_ash_opts(write_actor)

    source_fetcher =
      Keyword.get(opts, :source_fetcher, fn id -> fetch_source(id, read_ash_opts) end)

    profile_fetcher =
      Keyword.get(opts, :profile_fetcher, fn source_id, profile_id ->
        fetch_profile(source_id, profile_id, read_ash_opts)
      end)

    session_creator =
      Keyword.get(opts, :session_creator, fn attrs, actor_or_scope ->
        create_session(attrs, actor_or_scope, write_ash_opts)
      end)

    session_loader =
      Keyword.get(opts, :session_loader, fn session_id ->
        fetch_session(session_id, read_ash_opts)
      end)

    mark_opening =
      Keyword.get(opts, :mark_opening, fn session,
                                          command_id,
                                          lease_token,
                                          lease_expires_at,
                                          actor_or_scope ->
        mark_session_opening(
          session,
          command_id,
          lease_token,
          lease_expires_at,
          actor_or_scope,
          write_ash_opts
        )
      end)

    mark_failed =
      Keyword.get(opts, :mark_failed, fn session, reason, actor_or_scope ->
        mark_session_failed(session, reason, actor_or_scope, write_ash_opts)
      end)

    dispatch_open = Keyword.get(opts, :dispatch_open, &dispatch_open_command/4)

    with {:ok, source} <- source_fetcher.(camera_source_id),
         {:ok, _profile} <- profile_fetcher.(camera_source_id, stream_profile_id),
         :ok <- validate_source_assignment(source),
         {:ok, session} <-
           session_creator.(
             %{
               camera_source_id: camera_source_id,
               stream_profile_id: stream_profile_id,
               agent_id: source.assigned_agent_id,
               gateway_id: source.assigned_gateway_id,
               lease_expires_at: lease_expiry(opts),
               requested_by: requested_by_id(requester)
             },
             write_actor
           ) do
      lease_token = lease_token()

      case dispatch_open.(
             source.assigned_agent_id,
             open_command_payload(
               session.id,
               camera_source_id,
               stream_profile_id,
               lease_token,
               opts
             ),
             dispatch_opts(opts, requester),
             requester
           ) do
        {:ok, command_id} ->
          with {:ok, updated_session} <-
                 mark_opening.(
                   session,
                   command_id,
                   lease_token,
                   lease_expiry(opts),
                   write_actor
                 ) do
            load_session_result(updated_session, session_loader)
          end

        {:error, reason} = error ->
          _ = mark_failed.(session, reason, write_actor)
          maybe_record_session_failure(session, source, reason, "request_open")
          error
      end
    end
  end

  @spec request_close(Ecto.UUID.t() | RelaySession.t() | map(), keyword()) ::
          {:ok, RelaySession.t() | map()} | {:error, term()}
  def request_close(session_or_id, opts \\ []) do
    do_close_session(session_or_id, opts)
  end

  @spec close_session(Ecto.UUID.t() | RelaySession.t() | map(), keyword()) ::
          {:ok, RelaySession.t() | map()} | {:error, term()}
  def close_session(session_or_id, opts \\ []) do
    request_close(session_or_id, opts)
  end

  defp do_close_session(session_or_id, opts) do
    requester = resolve_requester(opts)
    read_ash_opts = read_ash_opts(opts, requester)
    write_actor = resolve_write_actor(opts)
    write_ash_opts = write_ash_opts(write_actor)

    session_fetcher =
      Keyword.get(opts, :session_fetcher, fn session_id ->
        fetch_session(session_id, read_ash_opts)
      end)

    session_loader = Keyword.get(opts, :session_loader, session_fetcher)

    mark_closing =
      Keyword.get(opts, :mark_closing, fn session, reason, actor_or_scope ->
        mark_session_closing(session, reason, actor_or_scope, write_ash_opts)
      end)

    mark_failed =
      Keyword.get(opts, :mark_failed, fn session, reason, actor_or_scope ->
        mark_session_failed(session, reason, actor_or_scope, write_ash_opts)
      end)

    dispatch_close = Keyword.get(opts, :dispatch_close, &dispatch_close_command/4)
    close_reason = Keyword.get(opts, :reason, "viewer disconnected")

    with {:ok, session} <- resolve_session(session_or_id, session_fetcher),
         {:ok, updated_session} <- mark_closing.(session, close_reason, write_actor) do
      case dispatch_close.(
             updated_session.agent_id,
             %{relay_session_id: updated_session.id, reason: close_reason},
             dispatch_opts(opts, requester),
             requester
           ) do
        {:ok, _command_id} ->
          load_session_result(updated_session, session_loader)

        {:error, reason} = error ->
          _ = mark_failed.(updated_session, reason, write_actor)
          maybe_record_session_failure(updated_session, nil, reason, "request_close")
          error
      end
    end
  end

  defp fetch_source(camera_source_id, ash_opts) do
    Source.get_by_id(camera_source_id, Keyword.merge([load: [:stream_profiles]], ash_opts))
  end

  defp fetch_profile(camera_source_id, stream_profile_id, ash_opts) do
    StreamProfile.get_for_relay(stream_profile_id, camera_source_id, ash_opts)
  end

  defp fetch_session(session_id, ash_opts) do
    RelaySession.get_by_id(session_id, ash_opts)
  end

  defp create_session(attrs, _actor, ash_opts) do
    RelaySession.create_session(attrs, ash_opts)
  end

  defp mark_session_opening(session, command_id, lease_token, lease_expires_at, _actor, ash_opts) do
    RelaySession.mark_opening(
      session,
      %{
        command_id: command_id,
        lease_token: lease_token,
        lease_expires_at: lease_expires_at
      },
      ash_opts
    )
  end

  defp mark_session_closing(session, close_reason, _actor, ash_opts) do
    RelaySession.request_close(session, %{close_reason: close_reason}, ash_opts)
  end

  defp mark_session_failed(session, reason, _actor, ash_opts) do
    RelaySession.fail_session(
      session,
      %{
        failure_reason: format_reason(reason),
        close_reason: "relay session failed"
      },
      ash_opts
    )
  end

  defp dispatch_open_command(agent_id, payload, opts, _actor) do
    AgentCommandBus.start_camera_relay(agent_id, payload, opts)
  end

  defp dispatch_close_command(agent_id, payload, opts, _actor) do
    AgentCommandBus.stop_camera_relay(agent_id, payload, opts)
  end

  defp open_command_payload(
         relay_session_id,
         camera_source_id,
         stream_profile_id,
         lease_token,
         opts
       ) do
    payload = %{
      relay_session_id: relay_session_id,
      camera_source_id: camera_source_id,
      stream_profile_id: stream_profile_id,
      lease_token: lease_token
    }

    if Keyword.get(opts, :insecure_skip_verify) == true do
      Map.put(payload, :insecure_skip_verify, true)
    else
      payload
    end
  end

  defp maybe_record_session_failure(session, source, reason, stage) do
    %{
      relay_boundary: "core",
      relay_session_id: Map.get(session, :id),
      agent_id: Map.get(session, :agent_id) || Map.get(source || %{}, :assigned_agent_id),
      gateway_id: Map.get(session, :gateway_id) || Map.get(source || %{}, :assigned_gateway_id),
      camera_source_id: Map.get(session, :camera_source_id),
      stream_profile_id: Map.get(session, :stream_profile_id),
      relay_status: Map.get(session, :status),
      failure_reason: format_reason(reason),
      reason: format_reason(reason),
      stage: stage
    }
    |> RelayHealthEventRouter.record_session_failure()
    |> case do
      :ok -> :ok
      {:error, _router_error} -> :ok
    end
  end

  defp resolve_session(%RelaySession{} = session, _fetcher), do: {:ok, session}
  defp resolve_session(%{id: id}, fetcher) when is_binary(id), do: fetcher.(id)
  defp resolve_session(session_id, fetcher) when is_binary(session_id), do: fetcher.(session_id)
  defp resolve_session(_session_or_id, _fetcher), do: {:error, :invalid_session}

  defp load_session_result(%{id: session_id} = fallback_session, session_loader)
       when is_binary(session_id) do
    case session_loader.(session_id) do
      {:ok, nil} -> {:ok, fallback_session}
      {:ok, session} -> {:ok, session}
      {:error, _reason} -> {:ok, fallback_session}
    end
  end

  defp load_session_result(session, _session_loader), do: {:ok, session}

  defp validate_source_assignment(source) do
    cond do
      blank?(Map.get(source, :assigned_agent_id)) ->
        {:error, "camera source is not assigned to an edge agent"}

      blank?(Map.get(source, :assigned_gateway_id)) ->
        {:error, "camera source is not assigned to an edge gateway"}

      true ->
        :ok
    end
  end

  defp dispatch_opts(opts, actor) do
    opts
    |> Keyword.drop([
      :source_fetcher,
      :profile_fetcher,
      :session_creator,
      :mark_opening,
      :mark_failed,
      :dispatch_open,
      :session_fetcher,
      :mark_closing,
      :dispatch_close,
      :reason,
      :scope
    ])
    |> Keyword.put(:actor, actor)
  end

  defp lease_expiry(opts) do
    ttl_seconds = Keyword.get(opts, :lease_ttl_seconds, @default_lease_ttl_seconds)
    DateTime.utc_now() |> DateTime.add(ttl_seconds, :second) |> DateTime.truncate(:microsecond)
  end

  defp lease_token do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp requested_by_id(nil), do: nil
  defp requested_by_id(%{id: id}) when is_binary(id), do: id
  defp requested_by_id(%{id: id}), do: to_string(id)
  defp requested_by_id(%{email: email}) when is_binary(email), do: email
  defp requested_by_id(_), do: nil

  defp resolve_requester(opts) do
    case Keyword.get(opts, :scope) do
      %{user: user} when not is_nil(user) ->
        user

      _ ->
        Keyword.get(opts, :actor, SystemActor.system(:camera_relay_session_manager))
    end
  end

  defp resolve_write_actor(opts) do
    Keyword.get(opts, :write_actor, SystemActor.system(:camera_relay_session_manager))
  end

  defp read_ash_opts(opts, actor) do
    case Keyword.get(opts, :scope) do
      nil -> [actor: actor]
      scope -> [scope: scope]
    end
  end

  defp write_ash_opts(actor), do: [actor: actor]

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false
end
