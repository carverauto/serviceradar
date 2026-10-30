defmodule ServiceRadar.Camera.RelaySessionManager do
  @moduledoc """
  Opens and closes one durable camera/profile relay shared by independent consumers.

  Reservation commits before the agent command is sent. Viewer disconnects and
  idle timeouts close only when no current consumer lease remains. Explicit
  operator stops can use `force: true` to invalidate all consumers.

  When several pre-existing relays are still live, an authenticated active
  session can be reserved exactly, without adopting the profile or retiring a
  different owner. Any other ambiguous relay keeps the adoption refusal. A
  non-force close still waits while that session has viewers or the profile
  epoch has an unexpired consumer.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.RelayHealthEventRouter
  alias ServiceRadar.Camera.RelayOwnership
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.RelaySessionLifecycle
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Identity.RBAC

  @camera_view_permission "devices.cameras.view"

  def request_open(camera_source_id, stream_profile_id, opts \\ []) do
    requester = resolve_requester(opts)
    read_opts = Keyword.put(read_ash_opts(opts, requester), :not_found_error?, false)
    write_opts = write_ash_opts(resolve_write_actor(opts))

    with :ok <- authorize_requester(requester),
         {:ok, %Source{} = source} <- Source.get_by_id(camera_source_id, read_opts),
         {:ok, %StreamProfile{}} <-
           StreamProfile.get_for_relay(stream_profile_id, camera_source_id, read_opts),
         :ok <- validate_source_assignment(source),
         {:ok, source} <- resolve_current_source_gateway(source, opts, write_opts),
         {:ok, plan} <-
           RelayOwnership.reserve_open(
             source,
             stream_profile_id,
             %{
               camera_source_id: source.id,
               stream_profile_id: stream_profile_id,
               agent_id: source.assigned_agent_id,
               gateway_id: source.assigned_gateway_id,
               requested_by: requested_by_id(requester)
             },
             write_opts
           ) do
      case plan do
        {:reuse, session} ->
          {:ok, session}

        {:new, session} ->
          with {:ok, persisted} <- dispatch_reserved_session(session, requester, opts, write_opts),
               do: RelaySession.get_by_id(persisted.id, read_opts)
      end
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def open_session(source_id, profile_id, opts \\ []),
    do: request_open(source_id, profile_id, opts)

  def request_close(session_or_id, opts \\ []) do
    requester = resolve_requester(opts)
    write_opts = write_ash_opts(resolve_write_actor(opts))
    reason = Keyword.get(opts, :reason, "viewer disconnected")

    with {:ok, id} <- session_id(session_or_id),
         {:ok, %RelaySession{}} <-
           RelaySession.get_by_id(
             id,
             Keyword.put(read_ash_opts(opts, requester), :not_found_error?, false)
           ),
         {:ok, plan} <-
           RelayOwnership.with_session(
             id,
             fn owner, session ->
               reserve_close(owner, session, reason, opts, write_opts)
             end,
             write_opts
           ) do
      case plan do
        {:retain, session} -> {:ok, session}
        {:close, session} -> dispatch_reserved_close(session, reason, requester, opts, write_opts)
      end
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def close_session(session, opts \\ []), do: request_close(session, opts)

  defp dispatch_reserved_session(session, requester, opts, write_opts) do
    dispatch = Keyword.get(opts, :dispatch_open, &dispatch_open_command/4)
    payload = Map.take(session, [:camera_source_id, :stream_profile_id, :lease_token])
    payload = Map.put(payload, :relay_session_id, session.id)

    payload =
      if opts[:insecure_skip_verify] == true,
        do: Map.put(payload, :insecure_skip_verify, true),
        else: payload

    case dispatch.(
           session.agent_id,
           payload,
           opts
           |> dispatch_opts(requester, session.gateway_id)
           |> Keyword.put(:command_id, session.command_id),
           requester
         ) do
      {:ok, command_id} when command_id == session.command_id ->
        RelayOwnership.with_session(
          session.id,
          fn owner, current ->
            if RelayOwnership.current?(owner, current),
              do: {:ok, current},
              else: {:error, :ownership_lost}
          end,
          write_opts
        )

      {:ok, _other_command_id} ->
        {:error, :relay_command_id_mismatch}

      {:error, reason} = error ->
        fail_dispatch(session, reason, "request_open", write_opts)
        error
    end
  end

  defp reserve_close(_owner, %{status: status} = session, _reason, _opts, _write_opts)
       when status in [:closing, :closed, :failed], do: {:ok, {:retain, session}}

  defp reserve_close(owner, session, reason, opts, write_opts) do
    case RelayOwnership.adopt(owner, session, write_opts) do
      {:ok, owner} ->
        fenced_close(owner, session, reason, opts, write_opts)

      {:error, :ambiguous_live_relays} = error ->
        if authenticated_legacy?(session),
          do: legacy_session_close(owner, session, reason, opts, write_opts),
          else: error

      {:error, _} = error ->
        error
    end
  end

  defp fenced_close(owner, session, reason, opts, write_opts) do
    close =
      cond do
        force_close?(opts) ->
          IngestOwnership.begin_close(owner, write_opts)

        soft_viewer_release?(reason) and session.viewer_count > 0 ->
          {:error, :consumers_active}

        true ->
          # Retention is decided under the profile lock before a nested refusal
          # can roll back the surrounding transaction.
          with :ok <- IngestOwnership.require_idle(owner, write_opts),
               do: IngestOwnership.begin_idle_close(owner, write_opts)
      end

    case close do
      {:ok, _closing} -> commit_session_close(session, reason, write_opts)
      {:error, :consumers_active} -> {:ok, {:retain, session}}
      {:error, _} = error -> error
    end
  end

  defp authenticated_legacy?(%{status: :active, media_ingest_id: id})
       when is_binary(id) and id != "", do: true

  defp authenticated_legacy?(_session), do: false

  defp legacy_session_close(owner, session, reason, opts, write_opts) do
    cond do
      force_close?(opts) ->
        commit_session_close(session, reason, write_opts)

      session.viewer_count > 0 ->
        {:ok, {:retain, session}}

      true ->
        case IngestOwnership.require_idle(owner, write_opts) do
          :ok -> commit_session_close(session, reason, write_opts)
          {:error, :consumers_active} -> {:ok, {:retain, session}}
          {:error, _} = error -> error
        end
    end
  end

  defp commit_session_close(session, reason, write_opts) do
    with {:ok, updated} <-
           RelaySession.request_close(session, %{close_reason: reason}, write_opts),
         do: {:ok, {:close, updated}}
  end

  defp dispatch_reserved_close(session, reason, requester, opts, write_opts) do
    dispatch = Keyword.get(opts, :dispatch_close, &dispatch_close_command/4)

    case dispatch.(
           session.agent_id,
           %{relay_session_id: session.id, reason: reason},
           dispatch_opts(opts, requester, session.gateway_id),
           requester
         ) do
      {:ok, _command_id} ->
        {:ok, session}

      {:error, failure} = error ->
        fail_dispatch(session, failure, "request_close", write_opts)
        error
    end
  end

  defp fail_dispatch(session, reason, stage, write_opts) do
    _ =
      RelaySessionLifecycle.fail_session(
        session.id,
        session.media_ingest_id,
        %{
          failure_reason: format_reason(reason),
          close_reason: "relay session failed"
        },
        write_opts
      )

    maybe_record_session_failure(session, nil, reason, stage)
  end

  defp dispatch_open_command(agent, payload, opts, _actor),
    do: AgentCommandBus.start_camera_relay(agent, payload, opts)

  defp dispatch_close_command(agent, payload, opts, _actor),
    do: AgentCommandBus.stop_camera_relay(agent, payload, opts)

  defp dispatch_opts(opts, actor, gateway) do
    opts
    |> Keyword.drop([
      :dispatch_open,
      :dispatch_close,
      :control_gateway_resolver,
      :write_actor,
      :reason,
      :scope
    ])
    |> Keyword.put(:actor, actor)
    |> Keyword.put(:required_gateway_node, gateway)
  end

  defp resolve_current_source_gateway(source, opts, write_opts) do
    resolver =
      Keyword.get(
        opts,
        :control_gateway_resolver,
        &AgentCommandBus.resolve_control_gateway_node/2
      )

    case resolver.(source.assigned_agent_id, source.assigned_gateway_id) do
      {:ok, gateway} when is_binary(gateway) and gateway != "" ->
        if gateway == source.assigned_gateway_id,
          do: {:ok, source},
          else: Source.update_source(source, %{assigned_gateway_id: gateway}, write_opts)

      {:error, _} = error ->
        error

      _ ->
        {:error, :control_gateway_unavailable}
    end
  end

  defp validate_source_assignment(source) do
    cond do
      blank?(source.assigned_agent_id) ->
        {:error, "camera source is not assigned to an edge agent"}

      blank?(source.assigned_gateway_id) ->
        {:error, "camera source is not assigned to an edge gateway"}

      true ->
        :ok
    end
  end

  defp force_close?(opts), do: opts[:force] == true or opts[:force_close] == true

  defp soft_viewer_release?(reason) do
    reason = reason |> to_string() |> String.downcase() |> String.trim()

    reason == "" or String.contains?(reason, "viewer disconnected") or
      String.contains?(reason, "viewer closed")
  end

  defp session_id(%{id: id}), do: session_id(id)
  defp session_id(id) when is_binary(id), do: {:ok, id}
  defp session_id(_), do: {:error, :invalid_session}

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

  # Opening a relay starts an agent pulling the camera's stream, so every
  # user-initiated open needs the live-video permission, not just inventory
  # access. System actors (agent- and lifecycle-driven opens) are exempt.
  defp authorize_requester(requester) do
    cond do
      SystemActor.system_actor?(requester) -> :ok
      RBAC.has_permission?(requester, @camera_view_permission) -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp resolve_write_actor(opts) do
    Keyword.get(opts, :write_actor, SystemActor.system(:camera_relay_session_manager))
  end

  defp read_ash_opts(opts, actor) do
    case Keyword.get(opts, :scope) do
      nil ->
        [actor: actor]

      scope ->
        [scope: scope]
    end
  end

  defp write_ash_opts(actor), do: [actor: actor]

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_), do: false
end
