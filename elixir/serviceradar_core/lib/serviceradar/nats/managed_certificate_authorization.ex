defmodule ServiceRadar.NATS.ManagedCertificateAuthorization do
  @moduledoc """
  Hub certificate authorization from durable policy, with bounded broker grants.

  The protected AUTH account is the trust boundary for server-signed requests.
  Each core replica subscribes in one queue group. Accepted sessions are tracked
  locally for prompt targeted KICKs; the broker's user-JWT expiry independently
  limits every grant to the current snapshot lease, including after a core crash.
  This implies periodic managed-client reconnects, which acceptance must measure.
  Local leaf authorization has a separate offline policy contract.
  A stored account other than the deployment account is answered with an
  authorization error and no user JWT.
  """
  use GenServer

  alias NKEYS.Keypair
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ComponentCertificateAuthority, as: Authority
  alias ServiceRadar.Edge.ManagedCertificateLifecycle
  alias ServiceRadar.NATS.CertificateAuthorizationToken, as: Token
  alias ServiceRadar.NATS.ManagedCertificateConfiguration, as: Configuration

  @auth :serviceradar_certificate_auth
  @system :serviceradar_certificate_system
  @refresh_ms 10_000
  @subject "$SYS.REQ.USER.AUTH"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def readiness do
    GenServer.call(__MODULE__, :readiness)
  catch
    :exit, _ ->
      %{auth_mode: nil, account_name: nil, ready: false, reason: "authorizer_unavailable"}
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(ServiceRadar.PubSub, Authority.topic())
    send(self(), :tick)

    {:ok,
     %{
       config: nil,
       signer: nil,
       snapshot: nil,
       subscription: nil,
       sessions: %{},
       probe: nil,
       reason: "not_configured"
     }}
  end

  @impl true
  def handle_call(:readiness, _from, state) do
    account_name = stored_account_name(state)
    reason = readiness_reason(state.reason, account_name)

    status = %{
      auth_mode: state.config && state.config.auth_mode,
      account_name: account_name,
      ready: reason == nil,
      reason: reason
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = state |> configure() |> subscribe() |> refresh()
    Process.send_after(self(), :tick, @refresh_ms)
    {:noreply, state}
  end

  def handle_info(:certificate_policy_changed, state), do: {:noreply, refresh(state)}

  def handle_info(
        {:msg, %{topic: @subject, body: token, reply_to: reply, gnat: connection}},
        state
      ) do
    case state.subscription do
      {^connection, _sid} -> {:noreply, respond(token, reply, connection, state)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({ref, :ok}, %{probe: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | probe: nil}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{probe: ref} = state),
    do: {:noreply, %{state | probe: nil}}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status), do: Map.put(status, :state, %{reason: status.state.reason})

  defp stored_account_name(%{config: %{account_name: name}}) when is_binary(name), do: name
  defp stored_account_name(_state), do: nil

  defp readiness_reason(nil, account_name) when is_binary(account_name) do
    if Configuration.deployment_account() == account_name do
      nil
    else
      "nats_account_mismatch"
    end
  end

  defp readiness_reason(nil, _account_name), do: "nats_account_mismatch"
  defp readiness_reason(reason, _account_name), do: reason

  defp configure(%{config: nil} = state) do
    with {:ok, %{auth_mode: "static_mtls"} = config} <- Configuration.credentials(),
         {:ok, signer} <- Keypair.from_seed(config.issuer_seed),
         {:ok, settings, backoff} <- ServiceRadar.NATS.Supervisor.connection_settings(),
         :ok <- start_connection(@auth, config.auth_seed, settings, backoff),
         :ok <- start_connection(@system, config.system_seed, settings, backoff) do
      %{state | config: Configuration.public_config(config), signer: signer, reason: "connecting"}
    else
      {:ok, %{auth_mode: "operator_jwt"} = config} ->
        %{
          state
          | config: Configuration.public_config(config),
            signer: nil,
            reason: "jwt_account_signer_unconfigured"
        }

      {:ok, %{auth_mode: mode}} ->
        %{state | reason: "unsupported_auth_mode:#{mode}"}

      _ ->
        state
    end
  end

  defp configure(state), do: state

  defp start_connection(name, seed, settings, backoff) do
    settings =
      settings
      |> Map.drop([:jwt, :nkey_seed, :user, :username, :password, :token])
      |> Map.put(:nkey_seed, fn -> seed end)
      |> Map.put(:auth_required, true)

    supervisor_name =
      if name == @auth,
        do: ServiceRadar.NATS.CertificateAuthConnection,
        else: ServiceRadar.NATS.CertificateSystemConnection

    spec = %{
      id: name,
      start:
        {Gnat.ConnectionSupervisor, :start_link,
         [
           %{name: name, backoff_period: backoff, connection_settings: [settings]},
           [name: supervisor_name]
         ]}
    }

    case DynamicSupervisor.start_child(ServiceRadar.NATS.CertificateConnections, spec) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, _} = error -> error
    end
  end

  defp subscribe(%{reason: "jwt_account_signer_unconfigured"} = state), do: state
  defp subscribe(%{config: nil} = state), do: state

  defp subscribe(state) do
    case Process.whereis(@auth) do
      nil -> %{state | subscription: nil, reason: "auth_connection_unavailable"}
      pid -> ensure_subscription(pid, state)
    end
  catch
    :exit, _ -> %{state | subscription: nil, reason: "auth_connection_unavailable"}
  end

  defp ensure_subscription(pid, %{subscription: {pid, _}} = state), do: state

  defp ensure_subscription(pid, state) do
    case Gnat.sub(pid, self(), @subject, queue_group: "serviceradar-certificate-authority") do
      {:ok, sid} -> %{state | subscription: {pid, sid}}
      _ -> %{state | subscription: nil, reason: "auth_subscription_failed"}
    end
  end

  defp refresh(%{reason: "jwt_account_signer_unconfigured"} = state), do: state
  defp refresh(%{config: nil} = state), do: state

  defp refresh(state) do
    case Authority.snapshot() do
      {:ok, snapshot} ->
        sessions = reconcile_sessions(state.sessions, snapshot)
        reason = if state.subscription && Process.whereis(@system), do: nil, else: "connecting"
        observe_presented(%{state | snapshot: snapshot, sessions: sessions, reason: reason})

      _ ->
        %{state | reason: "policy_unavailable"}
    end
  end

  defp respond(token, reply, connection, state) do
    case Token.decode_request(token, state.config.issuer_nkey) do
      {:ok, request} ->
        decision = authorization_decision(state, request.fingerprint)

        encoded =
          Token.encode_response(request, decision, state.signer, state.config.account_name)

        case Gnat.pub(connection, reply, encoded) do
          :ok -> remember_session(state, request, decision)
          _ -> state
        end

      _ ->
        state
    end
  catch
    :exit, _ -> state
  end

  defp authorization_decision(state, fingerprint) do
    account = stored_account_name(state)

    if is_binary(account) and account == Configuration.deployment_account() do
      decision(state.snapshot, fingerprint)
    else
      {:deny, "nats_account_mismatch"}
    end
  end

  defp decision(nil, _), do: {:deny, "certificate policy unavailable"}

  defp decision(snapshot, fingerprint) do
    with %{component_id: id} <-
           Enum.find(snapshot.certificates, &(&1.fingerprint == fingerprint)),
         :ok <- Authority.authorize(snapshot, id, fingerprint),
         %{publish: _, subscribe: _} = permissions <-
           Map.get(snapshot.nats_permissions, fingerprint) do
      {:allow, Map.put(permissions, :expires_at, DateTime.to_unix(snapshot.valid_until))}
    else
      _ -> {:deny, "certificate not authorized"}
    end
  end

  defp remember_session(state, request, {:allow, %{expires_at: expires_at}}) do
    key = {request.server_id, request.connection_id}

    value = %{
      fingerprint: request.fingerprint,
      expires_at: expires_at
    }

    %{state | sessions: Map.put(state.sessions, key, value)}
  end

  defp remember_session(state, _, _), do: state

  # NATS 2.14 puts leaf connections in an authenticated CONNZ listing and omits
  # them from a CID lookup. LEAFZ has no peer certificate. The scan is the
  # presented-certificate evidence and does not consult callout sessions.
  defp observe_presented(
         %{probe: nil, snapshot: snapshot, config: %{account_name: account}} = state
       )
       when is_map(snapshot) and is_binary(account) do
    task =
      Task.Supervisor.async_nolink(ServiceRadar.NATS.CertificateObservationTasks, fn ->
        observe_account(account, snapshot)
        :ok
      end)

    %{state | probe: task.ref}
  catch
    :exit, _ -> state
  end

  defp observe_presented(state), do: state

  defp observe_account(account, snapshot) do
    Enum.each(presented_connections(account), fn connection ->
      case decision(snapshot, connection.fingerprint) do
        {:allow, _} ->
          _ =
            ManagedCertificateLifecycle.confirm_use(
              connection.fingerprint,
              "nats:" <> connection.server,
              actor: SystemActor.system(:managed_certificate_nats)
            )

        {:deny, _} ->
          if known_certificate?(snapshot, connection.fingerprint) do
            kick(connection.server, connection.cid)
          end
      end
    end)
  end

  defp known_certificate?(snapshot, fingerprint) do
    Enum.any?(snapshot.certificates, &(certificate_fingerprint(&1) == fingerprint)) or
      Enum.any?(snapshot.revocations, &(certificate_fingerprint(&1) == fingerprint))
  end

  defp certificate_fingerprint(record) when is_map(record) do
    Map.get(record, :fingerprint) || Map.get(record, "fingerprint")
  end

  defp presented_connections(account) do
    inbox = "_INBOX." <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    {:ok, sid} = Gnat.sub(@system, self(), inbox)

    try do
      publish_connz(inbox, "$SYS.REQ.SERVER.PING.CONNZ", account, 0)
      first = collect_connz(sid, System.monotonic_time(:millisecond) + 800, [])

      inbox
      |> expand_connz(sid, account, first, 8)
      |> Enum.flat_map(& &1.connections)
      |> Enum.uniq()
    after
      Gnat.unsub(@system, sid)
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp publish_connz(inbox, subject, account, offset) do
    Gnat.pub(
      @system,
      subject,
      Jason.encode!(%{auth: true, acc: account, offset: offset, limit: 256}), reply_to: inbox)
  end

  defp collect_connz(sid, deadline, pages) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      pages
    else
      receive do
        {:msg, %{sid: ^sid, body: body}} ->
          collect_connz(sid, deadline, [body | pages])
      after
        remaining -> pages
      end
    end
  end

  defp expand_connz(inbox, sid, account, bodies, rounds) do
    pages = Enum.flat_map(bodies, &parse_connz/1)

    next =
      pages
      |> Enum.group_by(& &1.server)
      |> Enum.flat_map(fn {server, server_pages} ->
        covered = server_pages |> Enum.map(& &1.next_offset) |> Enum.max()
        total = server_pages |> Enum.map(& &1.total) |> Enum.max()
        if covered < total, do: [{server, covered}], else: []
      end)

    case {next, rounds} do
      {[], _} ->
        pages

      {_, 0} ->
        pages

      {[{server, offset} | _], _} ->
        publish_connz(inbox, "$SYS.REQ.SERVER.#{server}.CONNZ", account, offset)
        more = collect_connz(sid, System.monotonic_time(:millisecond) + 400, [])
        expand_connz(inbox, sid, account, bodies ++ more, rounds - 1)
    end
  end

  defp parse_connz(body) when is_binary(body) do
    with {:ok, decoded} <- Jason.decode(body),
         %{"connections" => connections, "total" => total, "offset" => offset} <- decoded["data"],
         true <- is_list(connections) and is_integer(total) and is_integer(offset),
         server when is_binary(server) and server != "" <- get_in(decoded, ["server", "id"]) do
      found = Enum.flat_map(connections, &presented_connection(&1, server))

      [
        %{
          server: server,
          total: total,
          next_offset: offset + length(connections),
          connections: found
        }
      ]
    else
      _ -> []
    end
  end

  defp parse_connz(_), do: []

  defp presented_connection(%{"kind" => kind, "cid" => cid} = connection, server)
       when kind in ["Leafnode", "Client"] do
    with certs when is_list(certs) <- connection["tls_peer_certs"],
         %{"cert_sha256" => fingerprint} <- List.first(certs),
         true <- is_binary(fingerprint),
         cid when is_integer(cid) and cid > 0 <- connection_id(cid) do
      [%{server: server, cid: cid, fingerprint: String.downcase(fingerprint), kind: kind}]
    else
      _ -> []
    end
  end

  defp presented_connection(_, _), do: []

  defp connection_id(id) when is_integer(id), do: id
  defp connection_id(id) when is_float(id) and id > 0, do: trunc(id)
  defp connection_id(_), do: 0

  defp reconcile_sessions(sessions, snapshot) do
    now = System.system_time(:second)

    Map.reject(sessions, fn {{server, cid}, session} ->
      cond do
        session.expires_at <= now -> true
        match?({:allow, _}, decision(snapshot, session.fingerprint)) -> false
        true -> kick(server, cid)
      end
    end)
  end

  defp kick(server, cid) do
    case Gnat.request(@system, "$SYS.REQ.SERVER.#{server}.KICK", Jason.encode!(%{cid: cid}),
           receive_timeout: 1_000
         ) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"error" => _}} -> false
          {:ok, %{"data" => _}} -> true
          _ -> false
        end

      _ ->
        false
    end
  catch
    :exit, _ -> false
  end
end
