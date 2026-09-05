defmodule ServiceRadarWebNGWeb.Settings.RbacLive.DashboardAudience do
  @moduledoc false

  @sources [:authored, :package]
  @page_size 50

  @empty_source %{
    before: nil,
    after: nil,
    request_ref: nil,
    loading?: false,
    error: nil,
    expected: %{}
  }

  @spec new() :: map()
  def new do
    %{
      group_token: nil,
      group_id: nil,
      group_name: nil,
      epoch: 0,
      authored: @empty_source,
      package: @empty_source
    }
  end

  @spec select_group(map(), String.t(), String.t(), String.t()) :: map()
  def select_group(state, group_token, group_id, group_name)
      when is_binary(group_token) and is_binary(group_id) and is_binary(group_name) do
    %{
      state
      | group_token: group_token,
        group_id: group_id,
        group_name: group_name,
        epoch: state.epoch + 1,
        authored: @empty_source,
        package: @empty_source
    }
  end

  @spec sync_group_token(map(), String.t(), String.t()) :: {:ok, map()} | {:error, :stale}
  def sync_group_token(%{group_id: group_id} = state, group_token, group_id) when is_binary(group_token) do
    {:ok, %{state | group_token: group_token}}
  end

  def sync_group_token(_state, _group_token, _group_id), do: {:error, :stale}

  @spec start_request(map(), :authored | :package, :first | :next | :previous, String.t()) ::
          {:ok, map(), :first | {:after, String.t()} | {:before, String.t()}, non_neg_integer()}
          | {:error, :stale, map()}
  def start_request(state, source, direction, request_ref) when source in @sources and is_binary(request_ref) do
    source_state = Map.fetch!(state, source)

    case selector(source_state, direction) do
      {:ok, selector} ->
        requested =
          source_state
          |> Map.put(:request_ref, request_ref)
          |> Map.put(:loading?, true)
          |> Map.put(:error, nil)

        {:ok, Map.put(state, source, requested), selector, state.epoch}

      :error ->
        {:error, :stale, state}
    end
  end

  def start_request(state, _source, _direction, _request_ref), do: {:error, :stale, state}

  @spec accept_result(map(), :authored | :package, non_neg_integer(), String.t(), term()) ::
          {:replace, map(), list()} | {:preserve, map()} | {:ignore, map()}
  def accept_result(state, source, epoch, request_ref, result) when source in @sources do
    source_state = Map.fetch!(state, source)

    if state.epoch == epoch and source_state.request_ref == request_ref do
      accept_current_result(state, source, result)
    else
      {:ignore, state}
    end
  end

  def accept_result(state, _source, _epoch, _request_ref, _result), do: {:ignore, state}

  @spec resolve_row(map(), String.t()) :: {:ok, map()} | {:error, :stale}
  def resolve_row(state, row_token) when is_binary(row_token) do
    Enum.find_value(@sources, {:error, :stale}, fn source ->
      case resolve_row(state, source, row_token) do
        {:ok, entry} -> {:ok, entry}
        {:error, :stale} -> nil
      end
    end)
  end

  def resolve_row(_state, _row_token), do: {:error, :stale}

  @spec resolve_row(map(), :authored | :package, String.t()) ::
          {:ok, map()} | {:error, :stale}
  def resolve_row(state, source, row_token) when source in @sources and is_binary(row_token) do
    with %{loading?: false, error: nil} <- Map.fetch!(state, source),
         %{source: ^source, group_id: group_id, epoch: epoch} = entry <-
           get_in(state, [source, :expected, row_token]),
         true <- group_id == state.group_id,
         true <- epoch == state.epoch do
      {:ok, entry}
    else
      _ -> {:error, :stale}
    end
  end

  def resolve_row(_state, _source, _row_token), do: {:error, :stale}

  defp accept_current_result(state, source, {:ok, page}) do
    {rows, expected} = build_window(source, state.group_id, state.epoch, page.results)

    source_state =
      state
      |> Map.fetch!(source)
      |> Map.put(:before, page.before)
      |> Map.put(:after, page.after)
      |> Map.put(:request_ref, nil)
      |> Map.put(:loading?, false)
      |> Map.put(:error, nil)
      |> Map.put(:expected, expected)

    {:replace, Map.put(state, source, source_state), rows}
  end

  defp accept_current_result(state, source, {:error, _reason}) do
    source_state =
      state
      |> Map.fetch!(source)
      |> Map.put(:request_ref, nil)
      |> Map.put(:loading?, false)
      |> Map.put(:error, :load_failed)

    {:preserve, Map.put(state, source, source_state)}
  end

  defp accept_current_result(state, source, _unexpected) do
    accept_current_result(state, source, {:error, :invalid_result})
  end

  defp build_window(source, group_id, epoch, results) do
    results
    |> Enum.take(@page_size)
    |> Enum.map_reduce(%{}, fn target, expected ->
      row_token = opaque_token()
      grant = selected_grant(target)

      entry = %{
        source: source,
        group_id: group_id,
        epoch: epoch,
        target_id: to_string(target.id),
        fingerprint: {
          target.visibility,
          target.updated_at,
          grant && grant.id,
          grant && grant.access,
          grant && grant.updated_at
        }
      }

      row = %{
        id: row_token,
        row_token: row_token,
        name: target_name(source, target),
        public?: target.visibility == :public,
        access: grant && grant.access
      }

      {row, Map.put(expected, row_token, entry)}
    end)
  end

  defp selector(_source_state, :first), do: {:ok, :first}
  defp selector(%{after: cursor}, :next) when is_binary(cursor), do: {:ok, {:after, cursor}}

  defp selector(%{before: cursor}, :previous) when is_binary(cursor), do: {:ok, {:before, cursor}}

  defp selector(_source_state, _direction), do: :error

  defp selected_grant(%{access_grants: [grant]}), do: grant
  defp selected_grant(_target), do: nil

  defp target_name(:authored, target), do: target.title
  defp target_name(:package, target), do: target.name

  defp opaque_token do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
