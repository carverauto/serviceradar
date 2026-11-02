defmodule ServiceRadar.Security.PeerCertificatePolicyRefresh do
  @moduledoc """
  Refreshes signed peer admission independently of ERTS and managed NATS links.

  HTTPS uses ordinary CA and hostname verification. The separately pinned policy
  key authenticates the exact response bytes; this bootstrap connection must not
  depend on the policy it retrieves. Failed refreshes never extend a lease.
  """
  use GenServer

  alias ServiceRadar.HTTP.EgressClient
  alias ServiceRadar.Security.PeerCertificatePolicy

  require Logger

  @domain "serviceradar.certificate-policy.v1\0"
  @max_bytes 4 * 1024 * 1024

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  def status(server), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    with :ok <- validate_url(Keyword.fetch!(opts, :url)),
         {:ok, key} <- public_key(opts) do
      send(self(), :refresh)

      {:ok,
       %{
         url: Keyword.fetch!(opts, :url),
         public_key: key,
         store: Keyword.get(opts, :store, PeerCertificatePolicy),
         interval: Keyword.get(opts, :interval, 5_000),
         http_options: Keyword.get(opts, :http_options, []),
         last_success_at: nil,
         last_error: nil
       }}
    else
      error -> {:stop, error}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     state
     |> Map.take([:last_success_at, :last_error])
     |> Map.put(:policy, PeerCertificatePolicy.status(state.store)), state}
  end

  @impl true
  def handle_info(:refresh, state) do
    # Fixed bounds apply even when a deployment supplies a private HTTPS CA.
    opts =
      Keyword.merge(state.http_options,
        redirect: false,
        connect_timeout: 3_000,
        receive_timeout: 5_000,
        max_bytes: @max_bytes
      )

    result =
      with {:ok, %{status: 200, body: body}} <- EgressClient.fetch_body(state.url, opts),
           {:ok, snapshot} <- verify_envelope(body, state.public_key) do
        PeerCertificatePolicy.apply_snapshot(snapshot, state.store)
      else
        {:ok, %{status: status}} -> {:error, {:http_status, status}}
        error -> error
      end

    state = record_result(result, state)
    Process.send_after(self(), :refresh, state.interval)
    {:noreply, state}
  end

  defp record_result(:ok, state),
    do: %{state | last_success_at: DateTime.utc_now(), last_error: nil}

  defp record_result(error, state) do
    if state.last_error != error do
      Logger.warning("Managed peer certificate policy refresh rejected: #{inspect(error)}")
    end

    %{state | last_error: error}
  end

  defp verify_envelope(body, key) when is_binary(body) and byte_size(body) <= @max_bytes do
    with {:ok, %{"payload" => encoded, "signature" => signature}} <- Jason.decode(body),
         true <- is_binary(encoded) and is_binary(signature),
         {:ok, payload} <- Base.decode64(encoded),
         {:ok, signature} when byte_size(signature) == 64 <- Base.decode64(signature),
         true <- :crypto.verify(:eddsa, :none, @domain <> payload, signature, [key, :ed25519]),
         {:ok, snapshot} when is_map(snapshot) <- Jason.decode(payload) do
      {:ok, snapshot}
    else
      _ -> {:error, :invalid_signed_policy}
    end
  end

  defp verify_envelope(_, _), do: {:error, :invalid_signed_policy}

  defp validate_url(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        :ok

      _ ->
        {:error, :policy_url_requires_https}
    end
  end

  defp public_key(opts), do: public_key_file(Keyword.fetch!(opts, :public_key_file))

  defp public_key_file(path) do
    with {:ok, %{uid: 0, mode: mode, type: :regular}} <- File.stat(path),
         0 <- Bitwise.band(mode, 0o022),
         {:ok, encoded} <- File.read(path),
         {:ok, key} when byte_size(key) == 32 <- Base.decode64(String.trim(encoded)) do
      {:ok, key}
    else
      _ -> {:error, :invalid_policy_public_key_file}
    end
  end
end
