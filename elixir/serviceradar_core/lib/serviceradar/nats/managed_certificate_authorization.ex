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
  adds a subject to the broker's static configuration grants it here too. Until
  the static list has been read once, an infrastructure certificate is refused
  rather than granted the stored permissions the list replaces.

  Every grant names the permissions it carries (`Token.grant_name/2`), and the
  broker reports that name for the session. The presented-certificate scan
  disconnects a session whose name differs from the grant its certificate would
  receive now: a grant issued under an older static list or stored grant, by
  an older release, or by a replica with a different view. The client
  reconnects and receives the current grant. A session whose grant is current
  is left alone. Each scan disconnects at most `@grant_kicks_per_scan` such
  sessions, and a certificate whose reconnect returned with the same grant
  waits `@grant_retry_ms` before it is disconnected for it again, so a
  responder that still disagrees cannot keep a client reconnecting.

  Configuration and policy are database reads. A failed read keeps the last
  state, so a database outage cannot restart the authorizer and discard its
  static list, sessions and subscription.
  """
  use GenServer

  alias NKEYS.Keypair
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ComponentCertificateAuthority, as: Authority
  alias ServiceRadar.Edge.ManagedCertificateLifecycle
  alias ServiceRadar.Edge.ManagedComponent
  alias ServiceRadar.NATS.CertificateAuthorizationToken, as: Token
  alias ServiceRadar.NATS.ManagedCertificateConfiguration, as: Configuration
  alias ServiceRadar.NATS.StaticIdentityGrants

  require Logger

  @auth :serviceradar_certificate_auth
  @system :serviceradar_certificate_system
  @refresh_ms 10_000
  @grant_kicks_per_scan 64
  @grant_retry_ms 300_000
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
       grant_kicks: %{},
       static_users: %{},
       static_users_loaded: false,
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
    state =
      state
      |> guarded(&configure/1)
      |> subscribe()
      |> load_static_users()
      |> guarded(&refresh/1)

    Process.send_after(self(), :tick, @refresh_ms)
    {:noreply, state}
  end

  def handle_info(:certificate_policy_changed, state), do: {:noreply, guarded(state, &refresh/1)}

  def handle_info(
        {:msg, %{topic: @subject, body: token, reply_to: reply, gnat: connection}},
        state
      ) do
    case state.subscription do
      {^connection, _sid} -> {:noreply, respond(token, reply, connection, state)}
      _ -> {:noreply, state}
    end
  end

  def handle_info(
        {ref, {:ok, %{connz: %{offsets: offsets, turn: turn}, grant_kicks: grant_kicks}}},
        %{probe: ref} = state
      )
      when is_reference(ref) and is_map(offsets) and is_integer(turn) and turn >= 0 and
             is_map(grant_kicks) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     %{state | probe: nil, connz: %{offsets: offsets, turn: turn}, grant_kicks: grant_kicks}}
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

  # A raised database error or exit keeps the previous state. The last
  # snapshot stops admitting by itself once it is stale.
  defp guarded(state, step) do
    step.(state)
  rescue
    exception -> policy_unavailable(state, exception.__struct__)
  catch
    :exit, _reason -> policy_unavailable(state, :exit)
  end

  defp policy_unavailable(state, cause) do
    if state.reason != "policy_unavailable" do
      Logger.warning("NATS certificate policy is unavailable; keeping the last authorizer state",
        cause: inspect(cause)
      )
    end

    %{state | reason: "policy_unavailable"}
  end

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
      decision(state.snapshot, request.fingerprint, callout_static(state, request))
    else
      {:deny, "nats_account_mismatch"}
    end
  end

  # Admission is the stored policy alone. `static` only replaces the permissions
  # of an admitted infrastructure certificate, or refuses it with
  # `:unavailable`. Session reconciliation passes none.
  defp decision(snapshot, fingerprint, static \\ fn _component_id -> nil end)

  defp decision(nil, _, _), do: {:deny, "certificate policy unavailable"}

  defp decision(snapshot, fingerprint, static) do
    with %{component_id: id, not_after: not_after} <-
           Enum.find(snapshot.certificates, &(&1.fingerprint == fingerprint)),
         :ok <- Authority.authorize(snapshot, id, fingerprint),
         %{publish: _, subscribe: _} = stored <-
           Map.get(snapshot.nats_permissions, fingerprint) do
      case static.(id) do
        :unavailable ->
          {:deny, "static identity grants unavailable"}

        static_permissions ->
          permissions = static_permissions || stored
          {:allow, Map.put(permissions, :expires_at, Token.grant_expiry(not_after))}
      end
    else
      _ -> {:deny, "certificate not authorized"}
    end
  end

  defp callout_static(%{static_users_loaded: true} = state, request) do
    &static_grant(state.static_users, state.snapshot, &1, {:der, request.certificate_der})
  end

  defp callout_static(state, _request) do
    fn component_id ->
      type = component_type(state.snapshot, component_id)
      if is_binary(type) and ManagedComponent.infrastructure_type?(type), do: :unavailable
    end
  end

  defp static_grant(static_users, _snapshot, _component_id, _certificate)
       when map_size(static_users) == 0, do: nil

  defp static_grant(static_users, snapshot, component_id, {:der, der}),
    do: StaticIdentityGrants.grant(static_users, component_type(snapshot, component_id), der)

  defp static_grant(static_users, snapshot, component_id, {:subject, subject}) do
    type = component_type(snapshot, component_id)
    StaticIdentityGrants.presented_grant(static_users, type, subject)
  end

  defp component_type(snapshot, component_id) do
    Enum.find_value(snapshot.components, fn component ->
      if component.component_id == component_id, do: Map.get(component, :component_type)
    end)
  end

  # Re-read on every tick: a chart upgrade updates the mounted ConfigMap in
  # place. An unreadable file keeps the previous list and is logged once.
  defp load_static_users(state) do
    case StaticIdentityGrants.load() do
      {:ok, static_users} ->
        %{state | static_users: static_users, static_users_loaded: true, static_users_status: :ok}

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
    observation = %{connz: state.connz, grant_kicks: state.grant_kicks}
    static_users = if state.static_users_loaded, do: state.static_users, else: :unloaded

    task =
      Task.Supervisor.async_nolink(ServiceRadar.NATS.CertificateObservationTasks, fn ->
        {:ok, observe_account(account, snapshot, static_users, observation)}
      end)

    %{state | probe: task.ref}
  rescue
    # The single task slot is still held by an earlier scan, for example one
    # a restarted authorizer no longer tracks. The next tick tries again.
    RuntimeError -> state
  catch
    :exit, _ -> state
  end

  defp observe_presented(state), do: state

  # `static_users` is `:unloaded` until the list has been read once. The scan
  # then cannot know an infrastructure certificate's current grant and leaves
  # every admitted session alone. Disconnects run before confirmations, so a
  # database error while confirming cannot skip one.
  @doc false
  def observe_account(account, snapshot, static_users, %{connz: connz, grant_kicks: grant_kicks}) do
    {connections, connz} = scan_presented_connections(account, connz)
    now = System.monotonic_time(:millisecond)
    previous = Map.reject(grant_kicks, fn {_key, at} -> now - at >= @grant_retry_ms end)
    scan = %{previous: previous, kicked: previous, budget: @grant_kicks_per_scan, admitted: []}

    scan =
      Enum.reduce(connections, scan, fn connection, scan ->
        static = &presented_static(static_users, snapshot, &1, connection)

        case decision(snapshot, connection.fingerprint, static) do
          {:allow, permissions} ->
            scan = converge_grant(scan, connection, permissions, static_users, now)
            %{scan | admitted: [connection | scan.admitted]}

          {:deny, _} ->
            if known_certificate?(snapshot, connection.fingerprint) do
              kick(connection.server, connection.cid)
            end

            scan
        end
      end)

    report_grant_kicks(@grant_kicks_per_scan - scan.budget)
    scan.admitted |> Enum.reverse() |> Enum.each(&confirm_use/1)
    %{connz: connz, grant_kicks: scan.kicked}
  end

  defp presented_static(:unloaded, _snapshot, _component_id, _connection), do: nil

  defp presented_static(static_users, snapshot, component_id, connection),
    do: static_grant(static_users, snapshot, component_id, {:subject, connection.subject})

  defp converge_grant(scan, _connection, _permissions, :unloaded, _now), do: scan

  defp converge_grant(scan, connection, permissions, _static_users, now) do
    observed = connection.authorized_user
    key = {connection.fingerprint, observed}

    # A listing without the name gives no evidence about the grant.
    cond do
      not is_binary(observed) -> scan
      observed == Token.grant_name(connection.fingerprint, permissions) -> scan
      scan.budget == 0 -> scan
      Map.has_key?(scan.previous, key) -> scan
      kick(connection.server, connection.cid) -> grant_kicked(scan, key, now)
      true -> scan
    end
  end

  defp grant_kicked(scan, key, now),
    do: %{scan | kicked: Map.put(scan.kicked, key, now), budget: scan.budget - 1}

  defp report_grant_kicks(0), do: :ok

  defp report_grant_kicks(count) do
    Logger.info("Disconnected NATS sessions holding a grant other than the current one",
      count: count
    )
  end

  # A confirmation is an observation. A database error must not end the scan.
  defp confirm_use(connection) do
    ManagedCertificateLifecycle.confirm_use(
      connection.fingerprint,
      "nats:" <> connection.server,
      actor: SystemActor.system(:managed_certificate_nats)
    )
  rescue
    _exception -> :error
  catch
    :exit, _reason -> :error
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
      [
        %{
          server: server,
          cid: cid,
          fingerprint: String.downcase(fingerprint),
          kind: kind,
          subject: presented_subject(List.first(certs)),
          authorized_user: connection["authorized_user"]
        }
      ]
    else
      _ -> []
    end
  end

  defp presented_connection(_, _), do: []

  defp presented_subject(%{"subject" => subject}) when is_binary(subject), do: subject
  defp presented_subject(_certificate), do: ""

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
