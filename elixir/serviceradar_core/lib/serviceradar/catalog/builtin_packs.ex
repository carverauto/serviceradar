defmodule ServiceRadar.Catalog.BuiltinPacks do
  @moduledoc """
  Runtime loader for first-party Solution Packs shipped inside
  `:code.priv_dir(:serviceradar_core)/solution_packs/<slug>/` (`2.6`).

  Ensures every built-in Solution Pack (one directory per slug under
  `priv/solution_packs/`) is available offline in the
  Catalog Gallery on boot without requiring external network egress, validated
  through the exact same `PackManifest.validate_pack_tree/2` contract as remote
  release catalogs and GitOps trees.
  """

  alias ServiceRadar.Catalog.PackManifest

  @packs_subdir "solution_packs"

  @doc """
  Directory containing shipped built-in Solution Pack trees.
  """
  @spec packs_dir() :: String.t()
  def packs_dir do
    case :code.priv_dir(:serviceradar_core) do
      {:error, _} ->
        Path.expand("../../../../priv/#{@packs_subdir}", __DIR__)

      dir ->
        Path.join(List.to_string(dir), @packs_subdir)
    end
  end

  @doc """
  Loads and validates all shipped built-in Solution Packs from `dir`.
  """
  @spec list_packs(String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def list_packs(dir \\ nil) do
    root = dir || packs_dir()

    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.filter(&File.dir?(Path.join(root, &1)))
        |> Enum.reduce_while({:ok, []}, fn slug, {:ok, acc} ->
          case load_pack_dir(Path.join(root, slug)) do
            {:ok, validated} -> {:cont, {:ok, [validated | acc]}}
            {:error, reason} -> {:halt, {:error, {slug, reason}}}
          end
        end)
        |> case do
          {:ok, list} -> {:ok, Enum.reverse(list)}
          err -> err
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches a single built-in Solution Pack by `pack_id` or `slug`.
  """
  @spec get_pack(String.t(), String.t() | nil) :: {:ok, map()} | {:error, :not_found | term()}
  def get_pack(id_or_slug, dir \\ nil) when is_binary(id_or_slug) do
    with {:ok, packs} <- list_packs(dir) do
      case Enum.find(packs, fn p ->
             p.manifest["id"] == id_or_slug or p.manifest["slug"] == id_or_slug
           end) do
        nil -> {:error, :not_found}
        pack -> {:ok, pack}
      end
    end
  end

  @doc """
  Alias for `list_packs/1` returning all shipped built-in Solution Packs.
  """
  @spec list_builtin_packs(String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def list_builtin_packs(dir \\ nil), do: list_packs(dir)

  @doc """
  Alias for `get_pack/2` loading a single built-in Solution Pack by `pack_id` or `slug`.
  """
  @spec load_builtin_pack(String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, :not_found | term()}
  def load_builtin_pack(id_or_slug, dir \\ nil) when is_binary(id_or_slug) do
    get_pack(id_or_slug, dir)
  end

  @doc """
  Reads a pack directory recursively into a `%{relative_posix_path => binary}` map
  and validates it with `PackManifest.validate_pack_tree/2`.
  """
  @spec load_pack_dir(String.t()) :: {:ok, map()} | {:error, term()}
  def load_pack_dir(pack_dir) when is_binary(pack_dir) do
    with {:ok, files} <- collect_files(pack_dir, pack_dir, %{}) do
      PackManifest.validate_pack_tree(files, skip_srql_nif?: true)
    end
  end

  defp collect_files(current_dir, root_dir, acc) do
    case File.ls(current_dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while({:ok, acc}, fn name, {:ok, map_acc} ->
          full = Path.join(current_dir, name)

          cond do
            String.starts_with?(name, ".") ->
              {:cont, {:ok, map_acc}}

            File.dir?(full) ->
              case collect_files(full, root_dir, map_acc) do
                {:ok, next_acc} -> {:cont, {:ok, next_acc}}
                {:error, _} = err -> {:halt, err}
              end

            File.regular?(full) ->
              rel =
                full
                |> Path.relative_to(root_dir)
                |> String.replace("\\", "/")

              case File.read(full) do
                {:ok, bytes} -> {:cont, {:ok, Map.put(map_acc, rel, bytes)}}
                {:error, reason} -> {:halt, {:error, reason}}
              end

            true ->
              {:halt, {:error, {:unsupported_file_entry, full}}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
