defmodule ServiceRadar.Camera.RelaySessionManagerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.RelaySessionManager

  test "opens a relay session from inventory-backed camera assignment" do
    parent = self()
    camera_source_id = Ecto.UUID.generate()
    stream_profile_id = Ecto.UUID.generate()

    source_fetcher = fn ^camera_source_id ->
      {:ok,
       %{id: camera_source_id, assigned_agent_id: "agent-1", assigned_gateway_id: "gateway-1"}}
    end

    profile_fetcher = fn ^camera_source_id, ^stream_profile_id ->
      {:ok, %{id: stream_profile_id, camera_source_id: camera_source_id}}
    end

    session_creator = fn attrs, _actor ->
      send(parent, {:session_create, attrs})
      {:ok, Map.put(attrs, :id, Ecto.UUID.generate())}
    end

    dispatch_open = fn agent_id, payload, opts, _actor ->
      send(parent, {:dispatch_open, agent_id, payload, opts})
      {:ok, Ecto.UUID.generate()}
    end

    mark_opening = fn session, command_id, lease_token, lease_expires_at, _actor ->
      send(parent, {:mark_opening, session.id, command_id, lease_token, lease_expires_at})

      {:ok,
       Map.merge(session, %{
         command_id: command_id,
         lease_token: lease_token,
         lease_expires_at: lease_expires_at,
         status: :opening
       })}
    end

    session_loader = fn session_id ->
      send(parent, {:session_load, session_id})

      {:ok,
       %{
         id: session_id,
         camera_source_id: camera_source_id,
         stream_profile_id: stream_profile_id,
         agent_id: "agent-1",
         gateway_id: "gateway-1",
         status: :opening,
         termination_kind: nil
       }}
    end

    assert {:ok, session} =
             RelaySessionManager.request_open(camera_source_id, stream_profile_id,
               source_fetcher: source_fetcher,
               profile_fetcher: profile_fetcher,
               session_creator: session_creator,
               dispatch_open: dispatch_open,
               mark_opening: mark_opening,
               session_loader: session_loader,
               lease_ttl_seconds: 45
             )

    assert session.agent_id == "agent-1"
    assert session.gateway_id == "gateway-1"
    assert session.status == :opening

    assert_receive {:session_create, create_attrs}
    assert create_attrs.camera_source_id == camera_source_id
    assert create_attrs.stream_profile_id == stream_profile_id
    assert create_attrs.agent_id == "agent-1"

    assert_receive {:dispatch_open, "agent-1", payload, opts}
    assert payload.camera_source_id == camera_source_id
    assert payload.stream_profile_id == stream_profile_id
    assert is_binary(payload.lease_token)
    assert opts[:lease_ttl_seconds] == 45

    assert_receive {:mark_opening, _session_id, _command_id, lease_token, lease_expires_at}
    assert_receive {:session_load, session_id}
    assert session.id == session_id
    assert byte_size(lease_token) == 32
    assert %DateTime{} = lease_expires_at
  end

  test "returns a friendly error when the source is not assigned to an agent" do
    camera_source_id = Ecto.UUID.generate()
    stream_profile_id = Ecto.UUID.generate()

    source_fetcher = fn ^camera_source_id ->
      {:ok, %{id: camera_source_id, assigned_agent_id: nil, assigned_gateway_id: "gateway-1"}}
    end

    profile_fetcher = fn ^camera_source_id, ^stream_profile_id ->
      {:ok, %{id: stream_profile_id}}
    end

    assert {:error, "camera source is not assigned to an edge agent"} =
             RelaySessionManager.request_open(camera_source_id, stream_profile_id,
               source_fetcher: source_fetcher,
               profile_fetcher: profile_fetcher
             )
  end

  test "marks a relay session failed when open dispatch fails" do
    parent = self()
    camera_source_id = Ecto.UUID.generate()
    stream_profile_id = Ecto.UUID.generate()

    source_fetcher = fn ^camera_source_id ->
      {:ok,
       %{id: camera_source_id, assigned_agent_id: "agent-1", assigned_gateway_id: "gateway-1"}}
    end

    profile_fetcher = fn ^camera_source_id, ^stream_profile_id ->
      {:ok, %{id: stream_profile_id}}
    end

    session_creator = fn attrs, _actor ->
      {:ok, Map.put(attrs, :id, Ecto.UUID.generate())}
    end

    mark_failed = fn session, reason, _actor ->
      send(parent, {:mark_failed, session.id, reason})
      {:ok, session}
    end

    assert {:error, :agent_offline} =
             RelaySessionManager.request_open(camera_source_id, stream_profile_id,
               source_fetcher: source_fetcher,
               profile_fetcher: profile_fetcher,
               session_creator: session_creator,
               dispatch_open: fn _agent_id, _payload, _opts, _actor ->
                 {:error, :agent_offline}
               end,
               mark_failed: mark_failed
             )

    assert_receive {:mark_failed, _session_id, :agent_offline}
  end

  test "treats mark_opening as idempotent when the session already advanced" do
    parent = self()
    camera_source_id = Ecto.UUID.generate()
    stream_profile_id = Ecto.UUID.generate()
    relay_session_id = Ecto.UUID.generate()

    source_fetcher = fn ^camera_source_id ->
      {:ok,
       %{id: camera_source_id, assigned_agent_id: "agent-1", assigned_gateway_id: "gateway-1"}}
    end

    profile_fetcher = fn ^camera_source_id, ^stream_profile_id ->
      {:ok, %{id: stream_profile_id, camera_source_id: camera_source_id}}
    end

    session_creator = fn attrs, _actor ->
      {:ok, Map.put(attrs, :id, relay_session_id)}
    end

    dispatch_open = fn _agent_id, _payload, _opts, _actor ->
      {:ok, Ecto.UUID.generate()}
    end

    mark_opening = fn _session, _command_id, _lease_token, _lease_expires_at, _actor ->
      raise KeyError,
        key: :field,
        term: [required_message: "is required", no_password_message: nil]
    end

    session_loader = fn ^relay_session_id ->
      send(parent, {:session_load, relay_session_id})

      {:ok,
       %{
         id: relay_session_id,
         camera_source_id: camera_source_id,
         stream_profile_id: stream_profile_id,
         agent_id: "agent-1",
         gateway_id: "gateway-1",
         status: :opening,
         termination_kind: nil
       }}
    end

    assert {:ok, session} =
             RelaySessionManager.request_open(camera_source_id, stream_profile_id,
               source_fetcher: source_fetcher,
               profile_fetcher: profile_fetcher,
               session_creator: session_creator,
               dispatch_open: dispatch_open,
               mark_opening: mark_opening,
               session_loader: session_loader
             )

    assert session.id == relay_session_id
    assert session.status == :opening
    assert_receive {:session_load, ^relay_session_id}
  end

  test "uses a system actor for relay writes while preserving the viewer requester" do
    parent = self()
    camera_source_id = Ecto.UUID.generate()
    stream_profile_id = Ecto.UUID.generate()

    source_fetcher = fn ^camera_source_id ->
      {:ok,
       %{id: camera_source_id, assigned_agent_id: "agent-1", assigned_gateway_id: "gateway-1"}}
    end

    profile_fetcher = fn ^camera_source_id, ^stream_profile_id ->
      {:ok, %{id: stream_profile_id, camera_source_id: camera_source_id}}
    end

    session_creator = fn attrs, actor ->
      send(parent, {:session_create, attrs, actor})
      {:ok, Map.put(attrs, :id, Ecto.UUID.generate())}
    end

    dispatch_open = fn agent_id, payload, opts, actor ->
      send(parent, {:dispatch_open, agent_id, payload, opts, actor})
      {:ok, Ecto.UUID.generate()}
    end

    mark_opening = fn session, command_id, lease_token, lease_expires_at, actor ->
      send(parent, {:mark_opening, session.id, command_id, lease_token, lease_expires_at, actor})

      {:ok,
       Map.merge(session, %{
         command_id: command_id,
         lease_token: lease_token,
         lease_expires_at: lease_expires_at,
         status: :opening
       })}
    end

    requester = %{id: "user-1", email: "viewer@example.com", role: :viewer}
    scope = %{user: requester}

    assert {:ok, _session} =
             RelaySessionManager.request_open(camera_source_id, stream_profile_id,
               source_fetcher: source_fetcher,
               profile_fetcher: profile_fetcher,
               session_creator: session_creator,
               dispatch_open: dispatch_open,
               mark_opening: mark_opening,
               scope: scope
             )

    assert_receive {:session_create, create_attrs, create_actor}
    assert create_attrs.requested_by == "user-1"
    assert create_actor.role == :system

    assert_receive {:dispatch_open, "agent-1", _payload, opts, dispatch_actor}
    assert dispatch_actor.id == "user-1"
    assert opts[:actor].id == "user-1"

    assert_receive {:mark_opening, _session_id, _command_id, _lease_token, _lease_expires_at,
                    mark_opening_actor}

    assert mark_opening_actor.role == :system
  end

  test "passes insecure skip verify through the open command payload when requested" do
    parent = self()
    camera_source_id = Ecto.UUID.generate()
    stream_profile_id = Ecto.UUID.generate()

    source_fetcher = fn ^camera_source_id ->
      {:ok,
       %{id: camera_source_id, assigned_agent_id: "agent-1", assigned_gateway_id: "gateway-1"}}
    end

    profile_fetcher = fn ^camera_source_id, ^stream_profile_id ->
      {:ok, %{id: stream_profile_id, camera_source_id: camera_source_id}}
    end

    session_creator = fn attrs, _actor ->
      {:ok, Map.put(attrs, :id, Ecto.UUID.generate())}
    end

    dispatch_open = fn agent_id, payload, _opts, _actor ->
      send(parent, {:dispatch_open, agent_id, payload})
      {:ok, Ecto.UUID.generate()}
    end

    mark_opening = fn session, command_id, lease_token, lease_expires_at, _actor ->
      {:ok,
       Map.merge(session, %{
         command_id: command_id,
         lease_token: lease_token,
         lease_expires_at: lease_expires_at,
         status: :opening
       })}
    end

    session_loader = fn session_id ->
      {:ok,
       %{
         id: session_id,
         camera_source_id: camera_source_id,
         stream_profile_id: stream_profile_id,
         agent_id: "agent-1",
         gateway_id: "gateway-1",
         status: :opening
       }}
    end

    assert {:ok, _session} =
             RelaySessionManager.request_open(camera_source_id, stream_profile_id,
               source_fetcher: source_fetcher,
               profile_fetcher: profile_fetcher,
               session_creator: session_creator,
               dispatch_open: dispatch_open,
               mark_opening: mark_opening,
               session_loader: session_loader,
               insecure_skip_verify: true
             )

    assert_receive {:dispatch_open, "agent-1", payload}
    assert payload.insecure_skip_verify == true
  end

  test "requests close and dispatches a stop command" do
    parent = self()
    relay_session_id = Ecto.UUID.generate()

    session_fetcher = fn ^relay_session_id ->
      {:ok, %{id: relay_session_id, agent_id: "agent-2", status: :opening}}
    end

    mark_closing = fn session, reason, _actor ->
      send(parent, {:mark_closing, session.id, reason})
      {:ok, Map.put(session, :status, :closing)}
    end

    dispatch_close = fn agent_id, payload, opts, _actor ->
      send(parent, {:dispatch_close, agent_id, payload, opts})
      {:ok, Ecto.UUID.generate()}
    end

    session_loader = fn ^relay_session_id ->
      send(parent, {:session_load, relay_session_id})

      {:ok,
       %{
         id: relay_session_id,
         agent_id: "agent-2",
         status: :closing,
         termination_kind: "manual_stop"
       }}
    end

    assert {:ok, session} =
             RelaySessionManager.request_close(relay_session_id,
               reason: "viewer disconnected",
               session_fetcher: session_fetcher,
               mark_closing: mark_closing,
               dispatch_close: dispatch_close,
               session_loader: session_loader
             )

    assert session.status == :closing

    assert_receive {:mark_closing, ^relay_session_id, "viewer disconnected"}
    assert_receive {:dispatch_close, "agent-2", payload, _opts}
    assert_receive {:session_load, ^relay_session_id}
    assert payload.relay_session_id == relay_session_id
    assert payload.reason == "viewer disconnected"
    assert session.termination_kind == "manual_stop"
  end
end
