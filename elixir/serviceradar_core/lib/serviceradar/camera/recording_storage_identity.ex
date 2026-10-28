defmodule ServiceRadar.Camera.RecordingStorageIdentity do
  @moduledoc """
  Selects a provisioned storage lifetime from installation configuration.

  A member name is only a lookup key, never a source of identity. This loader
  does not inspect or initialize the spool. Storage.open/2 independently checks
  the selected UUID against the volume marker before any recording operation.
  """

  alias ServiceRadar.JSONDocument

  @max_bytes 65_536
  @max_members 256

  @doc """
  Resolves the scalar UUID or a version-1 member document, refusing mixed modes.

  With no document or member, the scalar value passes through unchanged for
  compatibility (including nil). Explicit document configuration fails startup
  when invalid, even when recording admission is disabled.
  """
  def resolve!(scalar, nil, nil), do: scalar

  def resolve!(nil, path, member) when is_binary(path) and is_binary(member) do
    with true <- valid_member?(member),
         {:ok, bytes} <- read_document(path),
         {:ok, document} <- JSONDocument.decode_object(bytes, @max_bytes),
         {:ok, members} <- validate_document(document),
         {:ok, id} <- Map.fetch(members, member) do
      id
    else
      :error -> invalid!(:member_not_installed)
      _ -> invalid!(:invalid_document_or_member)
    end
  end

  def resolve!(scalar, path, _member) when not is_nil(scalar) and not is_nil(path),
    do: invalid!(:conflicting_identity_sources)

  def resolve!(_scalar, _path, _member), do: invalid!(:document_and_member_required)

  # Projected ConfigMap files are symlinks. Follow the configuration path, but
  # accept only regular files and read at most one byte beyond the byte budget.
  defp read_document(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_bytes <- File.stat(path),
         {:ok, result} <- File.open(path, [:read, :binary, :raw], &read_regular_file/1) do
      result
    else
      _ -> {:error, :invalid_file}
    end
  end

  defp read_regular_file(device) do
    with {:ok, info} <- :file.read_file_info(device),
         %File.Stat{type: :regular, size: size} when size <= @max_bytes <-
           File.Stat.from_record(info) do
      :file.read(device, @max_bytes + 1)
    else
      _ -> {:error, :invalid_file}
    end
  end

  defp validate_document(%{"version" => 1, "members" => members} = document)
       when map_size(document) == 2 and is_map(members) and map_size(members) in 1..@max_members do
    ids = Map.values(members)

    if Enum.all?(members, fn {member, id} -> valid_member?(member) and canonical_uuid?(id) end) and
         MapSet.size(MapSet.new(ids)) == map_size(members) do
      {:ok, members}
    else
      {:error, :invalid_members}
    end
  end

  defp validate_document(_), do: {:error, :invalid_document}

  defp valid_member?(member) when is_binary(member) and byte_size(member) in 1..253,
    do: Regex.match?(~r/\A[a-z0-9](?:[-a-z0-9.]*[a-z0-9])?\z/, member)

  defp valid_member?(_), do: false

  defp canonical_uuid?(id) when is_binary(id) and byte_size(id) == 36,
    do: Ecto.UUID.cast(id) == {:ok, id}

  defp canonical_uuid?(_), do: false

  defp invalid!(reason),
    do: raise(ArgumentError, "invalid camera recording storage identity configuration: #{reason}")
end
