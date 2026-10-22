defmodule ServiceRadar.Observability.ThreatIntelInvestigation.Keyset do
  @moduledoc """
  Opaque keyset cursors for the threat-intel investigation pages.

  A cursor is the sort key of the last row on a page. It is URL-safe and
  carries no SQL; a malformed cursor is an explicit `{:error, :invalid_cursor}`
  rather than a silent first page.
  """

  @default_limit 50
  @max_limit 100

  @spec limit(term()) :: pos_integer()
  def limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)

  def limit(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> limit(parsed)
      _ -> @default_limit
    end
  end

  def limit(_value), do: @default_limit

  @spec encode([term()]) :: String.t()
  def encode(key) when is_list(key) do
    key
    |> Enum.map(&encode_value/1)
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Decodes a cursor into its key parts; `kinds` names how to read each part
  (`:datetime`, `:integer`, `:string`, or `:uuid`). `nil` and `""` mean the
  first page.
  """
  @spec decode(term(), [atom()]) :: {:ok, [term()] | nil} | {:error, :invalid_cursor}
  def decode(cursor, _kinds) when cursor in [nil, ""], do: {:ok, nil}

  def decode(cursor, kinds) when is_binary(cursor) and is_list(kinds) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, parts} when is_list(parts) and length(parts) == length(kinds) <- Jason.decode(json),
         {:ok, key} <- decode_parts(Enum.zip(kinds, parts)) do
      {:ok, key}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  def decode(_cursor, _kinds), do: {:error, :invalid_cursor}

  @doc """
  Splits a `limit + 1` read into the page rows and the cursor for the next page.
  """
  @spec page([term()], pos_integer(), (term() -> [term()])) :: %{
          rows: [term()],
          next_cursor: String.t() | nil
        }
  def page(rows, limit, key_fun) do
    {page_rows, rest} = Enum.split(rows, limit)

    next_cursor =
      case {rest, List.last(page_rows)} do
        {[_ | _], last} when not is_nil(last) -> encode(key_fun.(last))
        _ -> nil
      end

    %{rows: page_rows, next_cursor: next_cursor}
  end

  defp encode_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_value(value), do: value

  defp decode_parts(pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn {kind, value}, {:ok, acc} ->
      case decode_part(kind, value) do
        {:ok, decoded} -> {:cont, {:ok, acc ++ [decoded]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp decode_part(_kind, nil), do: {:ok, nil}

  defp decode_part(:datetime, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp decode_part(:integer, value) when is_integer(value), do: {:ok, value}
  defp decode_part(:string, value) when is_binary(value), do: {:ok, value}

  defp decode_part(:uuid, value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp decode_part(_kind, _value), do: :error
end
