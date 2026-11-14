defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Targeting do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.AgentConfig.Compilers.SNMPCompiler
  alias ServiceRadar.SRQLAst

  def assign_target_preview(socket, target_query) do
    scope = socket.assigns.current_scope

    is_default =
      case socket.assigns.selected_profile do
        %{is_default: true} -> true
        _ -> false
      end

    normalized_query = normalize_target_query(target_query, is_default)

    if is_nil(normalized_query) do
      socket
      |> assign(:target_device_count, nil)
      |> assign(:target_entity, "devices")
    else
      target_entity = extract_srql_entity(normalized_query)
      device_count = count_target_devices(scope, normalized_query)

      socket
      |> assign(:target_device_count, device_count)
      |> assign(:target_entity, target_entity)
    end
  end

  def normalize_target_query(target_query, is_default) do
    cond do
      target_query in [nil, ""] and is_default ->
        "in:devices"

      target_query in [nil, ""] ->
        nil

      true ->
        normalize_target_query(target_query)
    end
  end

  def normalize_target_query(query) when is_binary(query) do
    query = String.trim(query)

    cond do
      query == "" ->
        "in:devices"

      String.starts_with?(query, "in:") ->
        query

      true ->
        "in:devices " <> query
    end
  end

  def normalize_target_query(_), do: nil

  def format_target_count({:ok, count}) do
    label = if count == 1, do: "target", else: "targets"
    "#{count} #{label}"
  end

  def format_target_count(_), do: "Unknown"

  def target_count_title({:ok, _count}), do: nil
  def target_count_title(_), do: "Target count unavailable"

  def profile_target_query(profile) do
    target_query = resolve_target_query(profile.target_query, profile.is_default)
    normalize_target_query(target_query, profile.is_default)
  end

  # Resolve target query for a profile, using defaults for default profiles
  def resolve_target_query(nil, true), do: "in:devices"
  def resolve_target_query("", true), do: "in:devices"
  def resolve_target_query(nil, _is_default), do: nil
  def resolve_target_query("", _is_default), do: ""
  def resolve_target_query(query, _is_default), do: query

  def count_target_devices(_scope, nil), do: :unknown
  def count_target_devices(_scope, ""), do: :unknown

  def count_target_devices(scope, target_query) when is_binary(target_query) do
    # The preview counts exactly what the compiler would compile. Folding the
    # same SRQL evaluation the compiler folds -- device queries and interface
    # queries alike, with the same field support, default filters and
    # match-nothing semantics -- keeps the preview equal to the compile by
    # construction, instead of a reimplemented subset that reads "Unknown"
    # for every query the compiler accepts but the subset does not
    # (tags.*, in-lists, and the matcher's wider field and operator support).
    #
    # An unparseable query parses to nothing before any read runs, so typing
    # stays silent the way it did when the preview parsed directly.
    case SRQLAst.parse(target_query) do
      {:ok, _ast} ->
        case SNMPCompiler.reduce_target_pages(target_query, scope, 0, fn devices, acc ->
               {:cont, acc + length(devices)}
             end) do
          {:ok, count} -> {:ok, count}
          {:error, _reason} -> :unknown
        end

      {:error, _reason} ->
        {:ok, 0}
    end
  rescue
    _ -> :unknown
  end

  def extract_srql_entity(query) when is_binary(query) do
    query = String.trim(query)

    case Regex.run(~r/^in:(\S+)/, query) do
      [_, entity] -> String.downcase(entity)
      _ -> "devices"
    end
  end

  def extract_srql_entity(_), do: "devices"
end
