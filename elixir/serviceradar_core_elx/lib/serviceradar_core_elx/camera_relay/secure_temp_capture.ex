defmodule ServiceRadarCoreElx.CameraRelay.SecureTempCapture do
  @moduledoc false

  @retry_attempts 5

  @spec base_dir() :: String.t()
  def base_dir do
    Path.join(System.tmp_dir!(), "serviceradar_core_elx/camera_relay")
  end

  @spec allocate_path!(String.t(), String.t()) :: String.t()
  def allocate_path!(prefix, extension \\ ".h264") when is_binary(prefix) and is_binary(extension) do
    case allocate_path(prefix, extension) do
      {:ok, path} -> path
      {:error, reason} -> raise "failed to allocate secure temp capture path: #{inspect(reason)}"
    end
  end

  @spec allocate_path(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def allocate_path(prefix, extension \\ ".h264") when is_binary(prefix) and is_binary(extension) do
    File.mkdir_p!(base_dir())
    do_allocate_path(String.trim(prefix), normalize_extension(extension), @retry_attempts)
  end

  @spec with_payload_file(String.t(), binary(), String.t(), (String.t() -> result)) :: result when result: var
  def with_payload_file(prefix, payload, extension \\ ".h264", fun)
      when is_binary(prefix) and is_binary(payload) and is_binary(extension) and is_function(fun, 1) do
    path = allocate_path!(prefix, extension)

    try do
      write_payload!(path, payload)
      fun.(path)
    after
      cleanup_path(path)
    end
  end

  @spec cleanup_path(String.t() | nil) :: :ok
  def cleanup_path(nil), do: :ok

  def cleanup_path(path) when is_binary(path) do
    _ = File.rm(path)

    if managed_path?(path) do
      _ = File.rm_rf(Path.dirname(path))
    end

    :ok
  end

  defp do_allocate_path(_prefix, _extension, 0), do: {:error, :tempfile_allocation_failed}

  defp do_allocate_path(prefix, extension, attempts_left) do
    random =
      16
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    temp_dir = Path.join(base_dir(), "#{prefix}-#{random}")

    case File.mkdir(temp_dir) do
      :ok ->
        {:ok, Path.join(temp_dir, "capture#{extension}")}

      {:error, :eexist} ->
        do_allocate_path(prefix, extension, attempts_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_payload!(path, payload) do
    {:ok, io_device} = File.open(path, [:write, :binary, :exclusive])

    try do
      IO.binwrite(io_device, payload)
    after
      File.close(io_device)
    end
  end

  defp normalize_extension("." <> _rest = extension), do: extension
  defp normalize_extension(extension), do: "." <> extension

  defp managed_path?(path) do
    expanded_path = Path.expand(path)
    expanded_base = Path.expand(base_dir())
    expanded_path == expanded_base or String.starts_with?(expanded_path, expanded_base <> "/")
  end
end
