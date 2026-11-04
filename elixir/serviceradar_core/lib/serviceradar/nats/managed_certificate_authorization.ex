defmodule ServiceRadar.NATS.ManagedCertificateAuthorization do
  @moduledoc """
  Hub certificate authorization from durable policy, with bounded broker grants.

  The protected AUTH account is the trust boundary for server-signed requests.
  Each core replica subscribes in one queue group. Accepted sessions are tracked
  locally for prompt targeted KICKs; the broker's user-JWT expiry independently
  bounds sessions even after every authorizer disappears. Grants default to 12
  hours with +/-20% jitter, capped at certificate expiry. Policy freshness remains
  short and independent: stale policy cannot admit a new connection.
  Local leaf authorization has a separate offline policy contract.
  A stored account other than the deployment account is answered with an
  authorization error and no user JWT.

  An adopted infrastructure certificate that presents one of the chart's
  built-in identities is granted that identity's static permissions instead of
  its stored grant (`ServiceRadar.NATS.StaticIdentityGrants`), so a release that
  adds a subject to the broker's static configuration grants it here too.
  """
  use GenServer

  alias NKEYS.Keypair
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ComponentCertificateAuthority, as: Authority
  alias ServiceRadar.Edge.ManagedCertificateLifecycle
  alias ServiceRadar.NATS.CertificateAuthorizationToken, as: Token
  alias ServiceRadar.NATS.ManagedCertificateConfiguration, as: Configuration
  alias ServiceRadar.NATS.StaticIdentityGrants

  require Logger

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
       connz: %{offsets: %{}, turn: 0},
       static_users: %{},
       static_users_status: :ok,
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
    state = state |> configure() |> subscribe() |> load_static_users() |> refresh()
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

  def handle_info({ref, {:ok, %{offsets: offsets, turn: turn}}}, %{probe: ref} = state)
      when is_reference(ref) and is_map(offsets) and is_integer(turn) and turn >= 0 do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | probe: nil, connz: %{offsets: offsets, turn: turn}}}
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
        decision = authorization_decision(state, request)

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

  defp authorization_decision(state, request) do
    account = stored_account_name(state)

    if is_binary(account) and account == Configuration.deployment_account() do
      decision(state.snapshot, request.fingerprint, &static_grant(state, &1, request))
    else
      {:deny, "nats_account_mismatch"}
    end
  end

  # Admission is the stored policy alone. `static` only replaces the permissions
  # of an admitted infrastructure certificate; session reconciliation and the
  # presented-certificate scan pass none.
  defp decision(snapshot, fingerprint, static \\ fn _component_id -> nil end)

  defp decision(nil, _, _), do: {:deny, "certificate policy unavailable"}

  defp decision(snapshot, fingerprint, static) do
    with %{component_id: id, not_after: not_after} <-
           Enum.find(snapshot.certificates, &(&1.fingerprint == fingerprint)),
         :ok <- Authority.authorize(snapshot, id, fingerprint),
         %{publish: _, subscribe: _} = stored <-
           Map.get(snapshot.nats_permissions, fingerprint) do
      permissions = static.(id) || stored
      {:allow, Map.put(permissions, :expires_at, Token.grant_expiry(not_after))}
    else
      _ -> {:deny, "certificate not authorized"}
    end
  end

  defp static_grant(%{static_users: static_users}, _component_id, _request)
       when map_size(static_users) == 0, do: nil

  defp static_grant(state, component_id, request) do
    type =
      Enum.find_value(state.snapshot.components, fn component ->
        if component.component_id == component_id, do: Map.get(component, :component_type)
      end)

    StaticIdentityGrants.grant(state.static_users, type, request.certificate_der)
  end

  # Re-read on every tick: a chart upgrade updates the mounted ConfigMap in
  # place. An unreadable file keeps the previous list and is logged once.
  defp load_static_users(state) do
    case StaticIdentityGrants.load() do
      {:ok, static_users} ->
        %{state | static_users: static_users, static_users_status: :ok}

      {:error, reason} ->
        if state.static_users_status != {:error, reason} do
          Logger.warning("NATS static users file is unreadable; keeping the previous list",
            reason: inspect(reason)
          )
        end

        %{state | static_users_status: {:error, reason}}
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
    progress = connz_progress(state)

    task =
      Task.Supervisor.async_nolink(ServiceRadar.NATS.CertificateObservationTasks, fn ->
        {:ok, observe_account(account, snapshot, progress)}
      end)

    %{state | probe: task.ref}
  catch
    :exit, _ -> state
  end

  defp observe_presented(state), do: state

  defp observe_account(account, snapshot, progress) do
    {connections, progress} = scan_presented_connections(account, progress)

    Enum.each(connections, fn connection ->
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

    progress
  end

  defp known_certificate?(snapshot, fingerprint) do
    Enum.any?(snapshot.certificates, &(certificate_fingerprint(&1) == fingerprint)) or
      Enum.any?(snapshot.revocations, &(certificate_fingerprint(&1) == fingerprint))
  end

  defp certificate_fingerprint(record) when is_map(record) do
    Map.get(record, :fingerprint) || Map.get(record, "fingerprint")
  end

  @doc false
  def scan_presented_connections(account, progress \\ %{offsets: %{}, turn: 0}) do
    progress = connz_progress(%{connz: progress})

    try do
      read_connz(account, progress)
    rescue
      _ -> {[], public_connz(progress)}
    catch
      :exit, _ -> {[], public_connz(progress)}
    end
  end

  defp read_connz(account, progress) do
    inbox = "_INBOX." <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    case Gnat.sub(@system, self(), inbox) do
      {:ok, sid} ->
        try do
          publish_connz(inbox, "$SYS.REQ.SERVER.PING.CONNZ", account, 0)
          first = collect_connz(sid, System.monotonic_time(:millisecond) + 800, [])
          {pages, progress} = expand_connz(inbox, sid, account, first, progress, 8)

          connections =
            pages
            |> Enum.flat_map(& &1.connections)
            |> Enum.uniq()

          {connections, finish_connz(progress, first)}
        after
          Gnat.unsub(@system, sid)
        end

      _ ->
        {[], public_connz(progress)}
    end
  end

  defp public_connz(progress), do: %{offsets: progress.offsets, turn: progress.turn}

  defp connz_progress(%{connz: %{offsets: offsets, turn: turn}})
       when is_map(offsets) and is_integer(turn) and turn >= 0 do
    %{offsets: offsets, turn: turn, totals: %{}, seen: MapSet.new()}
  end

  defp connz_progress(_state), do: %{offsets: %{}, turn: 0, totals: %{}, seen: MapSet.new()}

  defp publish_connz(inbox, subject, account, offset) do
    Gnat.pub(
      @system,
      subject,
      Jason.encode!(%{auth: true, acc: account, offset: offset, limit: 256}),
      reply_to: inbox
    )
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

  defp expand_connz(inbox, sid, account, bodies, progress, remaining) do
    {pages, progress} = absorb_connz(bodies, progress)

    if remaining <= 0 do
      {pages, progress}
    else
      case choose_connz_server(progress) do
        :none ->
          {pages, progress}

        {:ok, server, offset} ->
          publish_connz(inbox, "$SYS.REQ.SERVER.#{server}.CONNZ", account, offset)
          more = collect_connz(sid, System.monotonic_time(:millisecond) + 400, [])
          progress = %{progress | turn: progress.turn + 1}
          {rest, progress} = expand_connz(inbox, sid, account, more, progress, remaining - 1)
          {pages ++ rest, progress}
      end
    end
  end

  defp absorb_connz(bodies, progress) do
    pages = Enum.flat_map(bodies, &parse_connz/1)

    progress =
      Enum.reduce(pages, progress, fn page, progress ->
        current = Map.get(progress.offsets, page.server, 0)
        current = if current > page.total, do: 0, else: current

        advanced =
          cond do
            page.next_offset >= page.total -> 0
            current > page.next_offset -> current
            true -> page.next_offset
          end

        %{
          progress
          | offsets: Map.put(progress.offsets, page.server, advanced),
            totals: Map.put(progress.totals, page.server, page.total),
            seen: MapSet.put(progress.seen, page.server)
        }
      end)

    {pages, progress}
  end

  defp choose_connz_server(%{offsets: offsets, totals: totals, turn: turn}) do
    outstanding =
      offsets
      |> Map.keys()
      |> Enum.filter(&connz_page_outstanding?(&1, offsets, totals))
      |> Enum.sort()

    case outstanding do
      [] ->
        :none

      outstanding ->
        server = Enum.at(outstanding, rem(turn, length(outstanding)))
        {:ok, server, Map.fetch!(offsets, server)}
    end
  end

  defp connz_page_outstanding?(server, offsets, totals) do
    offset = Map.fetch!(offsets, server)

    case Map.get(totals, server) do
      total when is_integer(total) -> offset > 0 and offset < total
      _ -> false
    end
  end

  defp finish_connz(progress, ping_bodies) do
    discovered = Enum.any?(ping_bodies, &(parse_connz(&1) != []))

    offsets =
      if discovered do
        Map.take(progress.offsets, MapSet.to_list(progress.seen))
      else
        progress.offsets
      end

    %{offsets: offsets, turn: progress.turn}
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
