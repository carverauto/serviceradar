defmodule ServiceRadar.Inventory.Remediation.Manifest do
  @moduledoc """
  Rollback manifest for `mix serviceradar.dire_remediation`.

  Newline-delimited JSON (one JSON object per line): a header line with run
  metadata followed by one entry per remediation action, each carrying the
  step, action, table, and the ids of every row touched (ids only — values
  are recoverable from source systems by re-sync). The file lets an operator
  target an unmerge/restore of any individual action.
  """

  defstruct [:path, :device]

  @type t :: %__MODULE__{path: String.t(), device: IO.device()}

  @doc """
  Open a manifest at `path` and write the run-metadata header line.
  """
  @spec open(String.t(), map()) :: t()
  def open(path, meta) when is_binary(path) and is_map(meta) do
    expanded = Path.expand(path)
    File.mkdir_p!(Path.dirname(expanded))
    device = File.open!(expanded, [:write, :utf8])

    header =
      Map.merge(%{manifest: "dire_remediation", version: 1, started_at: DateTime.utc_now()}, meta)

    write_line(device, header)
    %__MODULE__{path: expanded, device: device}
  end

  @doc """
  Append one manifest entry. `nil` manifests (dry runs) are a no-op so steps
  can record unconditionally.
  """
  @spec record(t() | nil, atom() | String.t(), atom() | String.t(), String.t(), list(), map()) ::
          :ok
  def record(manifest, step, action, table, ids, extra \\ %{})

  def record(nil, _step, _action, _table, _ids, _extra), do: :ok

  def record(%__MODULE__{device: device}, step, action, table, ids, extra)
      when is_list(ids) and is_map(extra) do
    entry =
      Map.merge(extra, %{
        step: to_string(step),
        action: to_string(action),
        table: table,
        ids: ids,
        count: length(ids),
        at: DateTime.utc_now()
      })

    write_line(device, entry)
  end

  @spec close(t() | nil) :: :ok
  def close(nil), do: :ok

  def close(%__MODULE__{device: device}) do
    _ = File.close(device)
    :ok
  end

  defp write_line(device, map) do
    IO.write(device, [Jason.encode!(map), "\n"])
    :ok
  end
end
