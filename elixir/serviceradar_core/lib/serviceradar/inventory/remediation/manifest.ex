defmodule ServiceRadar.Inventory.Remediation.Manifest.FileWriter do
  @moduledoc false

  @spec write(IO.device(), map()) :: :ok | {:error, term()}
  def write(device, map), do: write_batch(device, [map])

  @spec write_batch(IO.device(), [map()]) :: :ok | {:error, term()}
  def write_batch(device, maps) when is_list(maps) do
    encoded = Enum.map(maps, &[Jason.encode!(&1), "\n"])

    case IO.write(device, encoded) do
      :ok -> sync(device)
      {:error, reason} -> {:error, {:manifest_write_failed, reason}}
      other -> {:error, {:manifest_write_failed, other}}
    end
  rescue
    error -> {:error, {:manifest_write_failed, error}}
  catch
    kind, reason -> {:error, {:manifest_write_failed, {kind, reason}}}
  end

  @spec sync(IO.device()) :: :ok | {:error, term()}
  def sync(device) do
    case :file.sync(device) do
      :ok -> :ok
      {:error, reason} -> {:error, {:manifest_sync_failed, reason}}
      other -> {:error, {:manifest_sync_failed, other}}
    end
  rescue
    error -> {:error, {:manifest_sync_failed, error}}
  catch
    kind, reason -> {:error, {:manifest_sync_failed, {kind, reason}}}
  end
end

defmodule ServiceRadar.Inventory.Remediation.Manifest do
  @moduledoc """
  Rollback manifest for `mix serviceradar.dire_remediation`.

  Newline-delimited JSON (one JSON object per line): a header line with run
  metadata followed by one entry per remediation action, each carrying the
  step, action, table, and the ids of every row touched (ids only — values
  are recoverable from source systems by re-sync). The file lets an operator
  target an unmerge/restore of any individual action.
  """

  alias ServiceRadar.Inventory.Remediation.Manifest.FileWriter

  defstruct [:path, :device, writer: FileWriter]

  @type t :: %__MODULE__{path: String.t(), device: IO.device(), writer: module()}

  @doc """
  Open a manifest at `path` and write the run-metadata header line.
  """
  @spec open(String.t(), map()) :: t()
  def open(path, meta) when is_binary(path) and is_map(meta) do
    expanded = Path.expand(path)
    File.mkdir_p!(Path.dirname(expanded))
    device = File.open!(expanded, [:write, :utf8, :exclusive])

    header =
      Map.merge(%{manifest: "dire_remediation", version: 1, started_at: DateTime.utc_now()}, meta)

    case FileWriter.write(device, header) do
      :ok ->
        %__MODULE__{path: expanded, device: device}

      {:error, reason} ->
        _ = File.close(device)

        raise "failed to initialize remediation manifest #{expanded}: #{inspect(reason)}"
    end
  end

  @doc """
  Append one manifest entry. `nil` manifests (dry runs) are a no-op so steps
  can record unconditionally.
  """
  @spec record(t() | nil, atom() | String.t(), atom() | String.t(), String.t(), list(), map()) ::
          :ok | {:error, term()}
  def record(manifest, step, action, table, ids, extra \\ %{})

  def record(nil, _step, _action, _table, _ids, _extra), do: :ok

  def record(%__MODULE__{device: device, writer: writer}, step, action, table, ids, extra)
      when is_list(ids) and is_map(extra) do
    writer.write(device, build_entry(step, action, table, ids, extra))
  end

  def record(_manifest, _step, _action, _table, _ids, _extra), do: {:error, :invalid_manifest}

  @doc "Append a batch of manifest entries and sync it once."
  @spec record_batch(t() | nil, atom() | String.t(), [map()]) :: :ok | {:error, term()}
  def record_batch(manifest, step, entries)

  def record_batch(nil, _step, _entries), do: :ok

  def record_batch(%__MODULE__{device: device, writer: writer}, step, entries)
      when is_list(entries) do
    with {:ok, built} <- build_batch_entries(step, entries) do
      writer.write_batch(device, built)
    end
  end

  def record_batch(_manifest, _step, _entries), do: {:error, :invalid_manifest}

  @doc "Checks that an execute manifest is open and durably writable."
  @spec ensure_writable(t() | nil) :: :ok | {:error, term()}
  def ensure_writable(%__MODULE__{device: device, writer: writer}), do: writer.sync(device)
  def ensure_writable(_manifest), do: {:error, :manifest_required}

  @spec close(t() | nil) :: :ok
  def close(nil), do: :ok

  def close(%__MODULE__{device: device}) do
    _ = File.close(device)
    :ok
  end

  defp build_batch_entries(step, entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn
      %{action: action, table: table, ids: ids} = entry, {:ok, acc}
      when is_list(ids) ->
        extra = Map.get(entry, :extra, %{})

        if is_map(extra) do
          built = build_entry(step, action, table, ids, extra)
          {:cont, {:ok, [built | acc]}}
        else
          {:halt, {:error, :invalid_manifest_entry}}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_manifest_entry}}
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      error -> error
    end
  end

  defp build_entry(step, action, table, ids, extra) do
    Map.merge(extra, %{
      step: to_string(step),
      action: to_string(action),
      table: table,
      ids: ids,
      count: length(ids),
      at: DateTime.utc_now()
    })
  end
end
