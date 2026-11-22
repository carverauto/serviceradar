defmodule ServiceRadar.Edge.RuntimeCertificateRotation do
  @moduledoc """
  Records the chart's rotated runtime certificates on the infrastructure
  components that held their predecessors.

  With the NATS certificate authorization callout enabled, an adopted
  infrastructure component is admitted by recorded fingerprint. The chart's
  certificate generator reissues every runtime certificate when
  `certs.runtimeLayoutVersion` changes (and on every upgrade when the
  regenerator is enabled). Each reissue writes `runtime-cert-rotation.json` into
  the runtime certificate Secret, next to the certificates: for every reissued
  public certificate, the fingerprint it replaced, its own fingerprint, and its
  PEM with the issuing CA. The file holds no key material.

  `reconcile/1` records each named replacement with
  `ComponentCertificateAuthority.record_rotated_infrastructure_successor/3`.
  A replacement whose predecessor was never recorded is skipped: that certificate
  was not adopted, so its replacement is not either. Recording is idempotent.

  It runs twice. The core migrations hook runs it before any workload rolls onto
  the new certificates, which is the ordering a Helm upgrade needs. This process
  repeats it whenever the mounted file changes, for rotations that happen while
  core keeps running and for installs whose migrations hook does not run first.
  """
  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ComponentCertificateAuthority, as: Authority

  require Logger

  @interval_ms 30_000

  @type outcome :: {:recorded | :skipped | :refused, String.t() | nil, term()}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns the latest refusal reason per certificate fingerprint from the
  rotation manifest, or nil when unavailable or unreconciled.
  """
  @spec refusals() :: %{optional(String.t()) => String.t()} | nil
  def refusals do
    GenServer.call(__MODULE__, :refusals)
  catch
    :exit, _ -> nil
  end

  @doc "The configured manifest path, or nil when none is mounted."
  def configured_path, do: Application.get_env(:serviceradar, :runtime_cert_rotation_file)

  @doc """
  Records every replacement named in the manifest at `path`.

  A missing or unset file is no rotation. A file that does not parse is an error.
  """
  @spec reconcile(String.t() | nil) :: {:ok, [outcome()]} | {:error, term()}
  def reconcile(path \\ configured_path())

  def reconcile(path) when path in [nil, ""], do: {:ok, []}

  def reconcile(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> contents |> decode() |> record()
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Runs `reconcile/1` and logs the outcome. Never raises."
  @spec reconcile_and_log(String.t() | nil) :: :ok
  def reconcile_and_log(path \\ configured_path()) do
    case reconcile(path) do
      {:ok, outcomes} ->
        log(outcomes)

      {:error, reason} ->
        Logger.warning("Runtime certificate rotation file is unreadable: #{inspect(reason)}")
    end

    :ok
  rescue
    exception ->
      Logger.warning(
        "Runtime certificate rotation was not recorded: #{Exception.message(exception)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning("Runtime certificate rotation was not recorded: #{inspect(reason)}")
      :ok
  end

  @impl true
  def init(_opts) do
    send(self(), :tick)
    {:ok, %{digest: nil, refusals: nil}}
  end

  @impl true
  def handle_call(:refusals, _from, state) do
    {:reply, state.refusals, state}
  end

  # An unchanged file is not read into the database again once every entry is
  # settled. An entry refused for a transient reason (a database error rather
  # than a refusal such as `:untrusted_issuer`) is retried on the next tick.
  @impl true
  def handle_info(:tick, state) do
    state = tick(state, configured_path())
    Process.send_after(self(), :tick, @interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp tick(state, path) when path in [nil, ""], do: %{state | digest: nil, refusals: %{}}

  defp tick(state, path) do
    case File.read(path) do
      {:ok, contents} ->
        digest = :crypto.hash(:sha256, contents)

        if digest == state.digest do
          state
        else
          {settled?, refusals} = settle(contents)
          %{state | digest: if(settled?, do: digest), refusals: refusals}
        end

      {:error, :enoent} ->
        %{state | digest: nil, refusals: %{}}

      {:error, _reason} ->
        %{state | digest: nil, refusals: nil}
    end
  rescue
    exception ->
      Logger.warning(
        "Runtime certificate rotation was not recorded: #{Exception.message(exception)}"
      )

      %{state | digest: nil, refusals: nil}
  catch
    :exit, _reason -> %{state | digest: nil, refusals: nil}
  end

  defp settle(contents) do
    case contents |> decode() |> record() do
      {:ok, outcomes} ->
        log(outcomes)
        {not Enum.any?(outcomes, &transient?/1), refusals_from_outcomes(outcomes)}

      {:error, reason} ->
        Logger.warning("Runtime certificate rotation file is unreadable: #{inspect(reason)}")
        {true, nil}
    end
  end

  @doc false
  @spec refusals_from_outcomes([outcome()]) :: %{optional(String.t()) => String.t()}
  def refusals_from_outcomes(outcomes) do
    Enum.reduce(outcomes, %{}, fn
      {:refused, fingerprint, reason}, acc when is_binary(fingerprint) ->
        Map.put(acc, String.downcase(fingerprint), format_refusal_reason(reason))

      _other, acc ->
        acc
    end)
  end

  defp format_refusal_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_refusal_reason(_reason), do: "transient_error"

  defp transient?({:refused, _fingerprint, reason}), do: not is_atom(reason)
  defp transient?(_outcome), do: false

  defp decode(contents) do
    case Jason.decode(contents) do
      {:ok, %{"version" => 1, "certificates" => entries}} when is_list(entries) ->
        if Enum.all?(entries, &entry?/1), do: {:ok, entries}, else: {:error, :invalid_manifest}

      _ ->
        {:error, :invalid_manifest}
    end
  end

  defp entry?(%{"previous_fingerprint" => previous, "certificate_pem" => pem}),
    do: is_binary(previous) and is_binary(pem)

  defp entry?(_entry), do: false

  defp record({:ok, entries}) do
    opts = [actor: SystemActor.system(:runtime_certificate_rotation)]
    {:ok, Enum.map(entries, &record_entry(&1, opts))}
  end

  defp record(error), do: error

  # The PEM is authoritative; the record's `fingerprint` only labels an entry
  # that was not recorded.
  defp record_entry(%{"previous_fingerprint" => previous, "certificate_pem" => pem} = entry, opts) do
    label = entry["fingerprint"]

    case Authority.record_rotated_infrastructure_successor(
           previous,
           %{certificate_pem: pem},
           opts
         ) do
      {:ok, %{certificate: certificate, component: component}} ->
        {:recorded, certificate.fingerprint, component.component_id}

      {:error, :unknown_certificate} ->
        {:skipped, label, :predecessor_not_recorded}

      {:error, reason} ->
        {:refused, label, reason}
    end
  end

  defp log(outcomes) do
    Enum.each(outcomes, fn
      {:recorded, fingerprint, component_id} ->
        Logger.info("Recorded rotated runtime certificate #{fingerprint} for #{component_id}")

      {:skipped, _fingerprint, _reason} ->
        :ok

      {:refused, fingerprint, reason} ->
        Logger.warning(
          "Rotated runtime certificate #{inspect(fingerprint)} was not recorded: #{inspect(reason)}"
        )
    end)
  end
end
