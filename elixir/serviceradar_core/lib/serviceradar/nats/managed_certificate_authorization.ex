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

  def handle_info({ref, fingerprints}, %{probe: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    sessions =
      Map.new(state.sessions, fn {key, session} ->
        {key,
         %{
           session
           | observed: session.observed or MapSet.member?(fingerprints, session.fingerprint)
         }}
      end)

    {:noreply, %{state | probe: nil, sessions: sessions}}
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
      {:ok, %{auth_mode: mode}} -> %{state | reason: "unsupported_auth_mode:#{mode}"}
      _ -> state
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

  defp refresh(%{config: nil} = state), do: state

  defp refresh(state) do
    case Authority.snapshot() do
      {:ok, snapshot} ->
        sessions = reconcile_sessions(state.sessions, snapshot)
        reason = if state.subscription && Process.whereis(@system), do: nil, else: "connecting"
        observe_sessions(%{state | snapshot: snapshot, sessions: sessions, reason: reason})

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
      expires_at: expires_at,
      observed: false,
      last_probe: System.monotonic_time(:millisecond)
    }

    %{state | sessions: Map.put(state.sessions, key, value)}
  end

  defp remember_session(state, _, _), do: state

  defp observe_sessions(%{probe: nil} = state) do
    candidates =
      state.sessions
      |> Enum.reject(fn {_, session} -> session.observed end)
      |> Enum.sort_by(fn {_, session} -> session.last_probe end)
      |> Enum.uniq_by(fn {_, session} -> session.fingerprint end)
      |> Enum.take(32)

    if candidates == [] do
      state
    else
      account = state.config.account_name

      task =
        Task.Supervisor.async_nolink(ServiceRadar.NATS.CertificateObservationTasks, fn ->
          Enum.reduce(candidates, MapSet.new(), fn {{server, _cid}, session}, confirmed ->
            if confirm_observation(server, account, session.fingerprint),
              do: MapSet.put(confirmed, session.fingerprint),
              else: confirmed
          end)
        end)

      now = System.monotonic_time(:millisecond)

      sessions =
        Enum.reduce(candidates, state.sessions, fn {key, _}, sessions ->
          Map.update!(sessions, key, &%{&1 | last_probe: now})
        end)

      %{state | probe: task.ref, sessions: sessions}
    end
  catch
    :exit, _ -> state
  end

  defp observe_sessions(state), do: state

  defp confirm_observation(server, account, fingerprint) do
    # NATS 2.14's CID lookup omits leaves. The authorization response names the
    # user by fingerprint, so this query finds an actual accepted client or leaf
    # without scanning the account's entire connection inventory.
    body = Jason.encode!(%{auth: true, acc: account, user: fingerprint, limit: 1})

    with {:ok, %{body: response}} <-
           Gnat.request(@system, "$SYS.REQ.SERVER.#{server}.CONNZ", body, receive_timeout: 1_000),
         {:ok, %{"data" => %{"connections" => [connection]}}} <- Jason.decode(response),
         [%{"cert_sha256" => ^fingerprint} | _] <- connection["tls_peer_certs"],
         {:ok, _} <-
           ManagedCertificateLifecycle.confirm_use(fingerprint, "nats:" <> server,
             actor: SystemActor.system(:managed_certificate_nats)
           ) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

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
