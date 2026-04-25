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

  require Logger

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

    control_gateway_resolver =
      Keyword.get(
        opts,
        :control_gateway_resolver,
        &AgentCommandBus.resolve_control_gateway_node/2
      )

    source_gateway_updater =
      Keyword.get(opts, :source_gateway_updater, fn source, gateway_id, actor_or_scope ->
        update_source_gateway(source, gateway_id, actor_or_scope, write_ash_opts)
      end)

    with {:ok, source} <- source_fetcher.(camera_source_id),
         {:ok, _profile} <- profile_fetcher.(camera_source_id, stream_profile_id),
         :ok <- validate_source_assignment(source),
         {:ok, source, gateway_id} <-
           resolve_current_source_gateway(
             source,
             control_gateway_resolver,
             source_gateway_updater,
             write_actor
           ),
         {:ok, session} <-
           session_creator.(
             %{
               camera_source_id: camera_source_id,
               stream_profile_id: stream_profile_id,
               agent_id: source.assigned_agent_id,
               gateway_id: gateway_id,
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
             opts
             |> dispatch_opts(requester)
             |> Keyword.put(:required_gateway_node, gateway_id),
             requester
           ) do
        {:ok, command_id} ->
          with {:ok, updated_session} <-
                 mark_session_opening_safely(
                   session,
                   command_id,
                   lease_token,
                   lease_expiry(opts),
                   write_actor,
                   mark_opening,
                   session_loader
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

    with {:ok, session} <- resolve_session(session_or_id, session_fetcher) do
      case close_transition_mode(session) do
        :skip ->
          load_session_result(session, session_loader)

        :dispatch ->
          with {:ok, updated_session, should_dispatch?} <-
                 mark_session_closing_safely(
                   session,
                   close_reason,
                   write_actor,
                   mark_closing,
                   session_loader
                 ) do
            maybe_dispatch_close(
              updated_session,
              should_dispatch?,
              close_reason,
              opts,
              requester,
              dispatch_close,
              mark_failed,
              write_actor,
              session_loader
            )
          end
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

  defp mark_session_opening_safely(
         session,
         command_id,
         lease_token,
         lease_expires_at,
         actor,
         mark_opening,
         session_loader
       ) do
    mark_opening.(session, command_id, lease_token, lease_expires_at, actor)
  rescue
    error ->
      recover_mark_opening_transition(session, error, session_loader)
  else
    {:error, reason} -> recover_mark_opening_transition(session, reason, session_loader)
    other -> other
  end

  defp recover_mark_opening_transition(%{id: session_id}, reason, session_loader)
       when is_binary(session_id) do
    case session_loader.(session_id) do
      {:ok, %{status: status} = session} when status in [:opening, :active] ->
        Logger.warning(
          "Recovered camera relay mark_opening transition for #{session_id} after #{inspect(reason)}"
        )

        {:ok, session}

      _other ->
        {:error, reason}
    end
  end

  defp recover_mark_opening_transition(_session, reason, _session_loader), do: {:error, reason}

  defp mark_session_closing(session, close_reason, _actor, ash_opts) do
    RelaySession.request_close(session, %{close_reason: close_reason}, ash_opts)
  end

  defp mark_session_closing_safely(session, close_reason, actor, mark_closing, session_loader) do
    mark_closing.(session, close_reason, actor)
  rescue
    error ->
      recover_mark_closing_transition(session, error, session_loader)
  else
    {:ok, updated_session} -> {:ok, updated_session, true}
    {:error, reason} -> recover_mark_closing_transition(session, reason, session_loader)
    other -> other
  end

  defp recover_mark_closing_transition(%{id: session_id}, reason, session_loader)
       when is_binary(session_id) do
    case session_loader.(session_id) do
      {:ok, %{status: status} = session}
      when status in [:closing, "closing", :closed, "closed", :failed, "failed"] ->
        Logger.warning(
          "Recovered camera relay request_close transition for #{session_id} after #{inspect_close_error(reason)}"
        )

        {:ok, session, false}

      _other ->
        {:error, reason}
    end
  end

  defp recover_mark_closing_transition(_session, reason, _session_loader), do: {:error, reason}

  defp maybe_dispatch_close(
         updated_session,
         false,
         _close_reason,
         _opts,
         _requester,
         _dispatch_close,
         _mark_failed,
         _write_actor,
         session_loader
       ) do
    load_session_result(updated_session, session_loader)
  end

  defp maybe_dispatch_close(
         updated_session,
         true,
         close_reason,
         opts,
         requester,
         dispatch_close,
         mark_failed,
         write_actor,
         session_loader
       ) do
    case dispatch_close.(
           updated_session.agent_id,
           %{relay_session_id: updated_session.id, reason: close_reason},
           opts
           |> dispatch_opts(requester)
           |> Keyword.put(:required_gateway_node, updated_session.gateway_id),
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

  defp close_transition_mode(%{status: status})
       when status in [:closing, "closing", :closed, "closed", :failed, "failed"], do: :skip

  defp close_transition_mode(_session), do: :dispatch

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

  defp resolve_current_source_gateway(source, resolver, updater, actor) do
    assigned_agent_id = Map.get(source, :assigned_agent_id)
    assigned_gateway_id = Map.get(source, :assigned_gateway_id)

    case resolver.(assigned_agent_id, assigned_gateway_id) do
      {:ok, gateway_id} when is_binary(gateway_id) and gateway_id != "" ->
        source =
          maybe_update_source_gateway(source, assigned_gateway_id, gateway_id, updater, actor)

        {:ok, source, gateway_id}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:ok, source, assigned_gateway_id}
    end
  end

  defp maybe_update_source_gateway(source, gateway_id, gateway_id, _updater, _actor), do: source

  defp maybe_update_source_gateway(source, _old_gateway_id, new_gateway_id, updater, actor) do
    case updater.(source, new_gateway_id, actor) do
      {:ok, updated_source} ->
        updated_source

      _ ->
        Map.put(source, :assigned_gateway_id, new_gateway_id)
    end
  rescue
    _ -> Map.put(source, :assigned_gateway_id, new_gateway_id)
  end

  defp update_source_gateway(%Source{} = source, gateway_id, _actor, ash_opts) do
    Source.update_source(source, %{assigned_gateway_id: gateway_id}, ash_opts)
  end

  defp update_source_gateway(source, gateway_id, _actor, _ash_opts) when is_map(source) do
    {:ok, Map.put(source, :assigned_gateway_id, gateway_id)}
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

  defp inspect_close_error(%{__struct__: module}) do
    module
    |> inspect()
    |> String.trim_leading("Elixir.")
  end

  defp inspect_close_error(reason), do: inspect(reason)

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false
end
