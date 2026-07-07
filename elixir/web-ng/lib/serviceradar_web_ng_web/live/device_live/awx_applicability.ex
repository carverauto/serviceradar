defmodule ServiceRadarWebNGWeb.DeviceLive.AwxApplicability do
  @moduledoc """
  Classifies a bulk device selection for the Devices "Run Task" modal into the
  AWX-managed (ansible-capable) subset a task can actually run against, and the
  non-applicable remainder the modal must call out and skip.

  The predicate is `AnsiblePanelRuntime.awx_managed?/1` — the exact signal the
  device-detail Ansible panel uses (`metadata.awx.host_id`/`controller_id`) — so
  the bulk modal and the panel agree on which devices are ansible-capable.

  Device metadata is read through Ash with the operator's `scope`, so the reads
  are RBAC-gated the same way the rest of the Devices page is.
  """

  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNGWeb.DeviceLive.AnsiblePanelRuntime

  require Ash.Query

  # Read in modest batches: the primary Device read paginates (default 5000),
  # so chunks well under that ceiling come back in a single page.
  @chunk_size 500

  defstruct applicable_uids: [], non_applicable: [], total: 0

  @type non_applicable_entry :: %{uid: String.t(), label: String.t()}
  @type t :: %__MODULE__{
          applicable_uids: [String.t()],
          non_applicable: [non_applicable_entry()],
          total: non_neg_integer()
        }

  @doc """
  Split `uids` into the AWX-managed subset and the non-applicable remainder,
  loading each device's metadata via Ash with `scope` for RBAC. Selected uids
  that no longer resolve to a readable device are treated as non-applicable
  (labelled by uid) so a task is never launched against them.
  """
  @spec classify(term(), [String.t()]) :: t()
  def classify(scope, uids) when is_list(uids) do
    uids = uids |> Enum.filter(&is_binary/1) |> Enum.uniq()
    rows_by_uid = load_rows_by_uid(scope, uids)

    {applicable, non_applicable} =
      Enum.reduce(uids, {[], []}, fn uid, {app, non} ->
        row = Map.get(rows_by_uid, uid)

        if applicable?(row) do
          {[uid | app], non}
        else
          {app, [non_applicable_entry(row, uid) | non]}
        end
      end)

    %__MODULE__{
      applicable_uids: Enum.reverse(applicable),
      non_applicable: Enum.reverse(non_applicable),
      total: length(uids)
    }
  end

  def classify(_scope, _uids), do: %__MODULE__{}

  @doc "Number of AWX-managed devices in a classification."
  @spec applicable_count(t()) :: non_neg_integer()
  def applicable_count(%__MODULE__{applicable_uids: uids}), do: length(uids)

  @doc "True when at least one selected device is AWX-managed."
  @spec any_applicable?(t()) :: boolean()
  def any_applicable?(%__MODULE__{applicable_uids: [_ | _]}), do: true
  def any_applicable?(%__MODULE__{}), do: false

  defp applicable?(nil), do: false
  defp applicable?(row), do: AnsiblePanelRuntime.awx_managed?(row)

  defp non_applicable_entry(row, uid), do: %{uid: uid, label: device_label(row, uid)}

  defp device_label(nil, uid), do: uid

  defp device_label(row, uid) do
    presence(field(row, :name)) || presence(field(row, :hostname)) || uid
  end

  defp load_rows_by_uid(_scope, []), do: %{}

  defp load_rows_by_uid(scope, uids) do
    uids
    |> Enum.chunk_every(@chunk_size)
    |> Enum.flat_map(&read_chunk(scope, &1))
    |> Map.new(fn row -> {field(row, :uid), row} end)
  end

  defp read_chunk(scope, chunk) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.filter(uid in ^chunk)

    case Ash.read(query, scope: scope) do
      {:ok, %{results: results}} when is_list(results) -> results
      {:ok, results} when is_list(results) -> results
      _ -> []
    end
  end

  defp field(row, key) when is_map(row), do: Map.get(row, key) || Map.get(row, to_string(key))
  defp field(_row, _key), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
