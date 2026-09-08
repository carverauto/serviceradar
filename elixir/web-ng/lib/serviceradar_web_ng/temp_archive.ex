defmodule ServiceRadarWebNG.TempArchive do
  @moduledoc false

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @retry_attempts 5

  @spec create_tar_gz(String.t(), [{String.t(), iodata() | nil}]) ::
          {:ok, binary()} | {:error, term()}
  @sobelow_skip ["Traversal.FileModule"]
  def create_tar_gz(prefix, files) when is_binary(prefix) and is_list(files) do
    entries =
      Enum.map(files, fn {name, content} ->
        data =
          case content do
            nil -> ""
            _ -> IO.iodata_to_binary(content)
          end

        {String.to_charlist(name), data}
      end)

    with_secure_temp_path(prefix, fn tmp_path ->
      case :erl_tar.create(String.to_charlist(tmp_path), entries, [:compressed]) do
        :ok -> File.read(tmp_path)
        {:error, reason} -> {:error, reason}
      end
    end)
  rescue
    error -> {:error, {:tar_creation_failed, error}}
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp with_secure_temp_path(prefix, fun) when is_function(fun, 1) do
    base_dir = Path.join(System.tmp_dir!(), "serviceradar")
    File.mkdir_p!(base_dir)
    do_with_secure_temp_path(base_dir, prefix, fun, @retry_attempts)
  end

  defp do_with_secure_temp_path(_base_dir, _prefix, _fun, 0) do
    {:error, :tempfile_allocation_failed}
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp do_with_secure_temp_path(base_dir, prefix, fun, attempts_left) do
    random =
      16
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    temp_dir = Path.join(base_dir, "#{prefix}-#{random}")

    case File.mkdir(temp_dir) do
      :ok ->
        tmp_path = Path.join(temp_dir, "archive.tar.gz")

        try do
          fun.(tmp_path)
        after
          _ = File.rm_rf(temp_dir)
        end

      {:error, :eexist} ->
        do_with_secure_temp_path(base_dir, prefix, fun, attempts_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
