defmodule ServiceRadarWebNGWeb.Plugs.UploadGuard do
  @moduledoc """
  Validates inbound multipart file uploads before the controller runs.

  Plug-level checks:

    * Magic-number / content-type signature must match one of the
      configured allow-listed kinds. Mismatch yields HTTP 415.
    * File size must not exceed the configured `:max_bytes`. Oversized
      uploads yield HTTP 413.
    * The original filename is sanitized: control characters
      (`\\x00..\\x1F` plus `\\x7F`) are replaced with `_`, slashes are
      stripped, and the result is truncated to 120 bytes. The plug
      also generates a randomized storage filename of the shape
      `<millis>-<16-byte-base64-url-random><ext>` so controllers can
      use it for on-disk persistence without worrying about collisions
      or path injection.

  After validation, the plug rewrites each guarded upload's
  `Plug.Upload.filename` to the sanitized form and attaches the
  metadata to `conn.assigns.upload_guard` keyed by parameter name:

      %{
        param_name => %{
          original_filename: "scary..//../bad name.png",
          sanitized_filename: "scary______bad_name.png",
          storage_filename: "1715379223456-aQ_KqyAB1eR2Hcr3.png",
          kind: :png,
          byte_size: 41234
        }
      }

  ## Options

    * `:param` — the multipart form field name that carries the upload.
      Required. Pass a list of strings to guard multiple fields.
    * `:max_bytes` — integer, required.
    * `:allowed_kinds` — list of atoms from `#{inspect(__MODULE__)}.kinds()`,
      e.g. `[:png, :jpeg, :zip]`. Required.
    * `:require_magic_match` — default `true`. When `false` the plug
      validates the size + sanitizes the filename but does not enforce
      magic-number checking (use only for non-binary uploads like CSV).
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @control_char_re ~r/[\x00-\x1F\x7F]/
  @max_filename_bytes 120

  @magic %{
    png: [<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>],
    jpeg: [<<0xFF, 0xD8, 0xFF>>],
    gif: [<<"GIF87a">>, <<"GIF89a">>],
    zip: [<<"PK", 0x03, 0x04>>, <<"PK", 0x05, 0x06>>, <<"PK", 0x07, 0x08>>],
    wasm: [<<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>>],
    pdf: [<<"%PDF-">>]
  }

  @doc "List of magic-number kinds the guard knows how to verify."
  def kinds, do: Map.keys(@magic)

  @impl true
  def init(opts) do
    params = opts |> Keyword.fetch!(:param) |> List.wrap()
    max_bytes = Keyword.fetch!(opts, :max_bytes)
    allowed = Keyword.fetch!(opts, :allowed_kinds)
    require_magic = Keyword.get(opts, :require_magic_match, true)

    Enum.each(allowed, fn kind ->
      if !Map.has_key?(@magic, kind) do
        raise ArgumentError,
              "UploadGuard: unknown kind #{inspect(kind)}, expected one of #{inspect(kinds())}"
      end
    end)

    %{
      params: params,
      max_bytes: max_bytes,
      allowed_kinds: allowed,
      require_magic_match: require_magic
    }
  end

  @impl true
  def call(conn, %{params: params} = config) do
    Enum.reduce_while(params, conn, fn param, conn ->
      case Map.get(conn.params || %{}, param) do
        nil ->
          {:cont, conn}

        %Plug.Upload{} = upload ->
          case guard_upload(upload, config) do
            {:ok, metadata, rewritten_upload} ->
              {:cont,
               conn
               |> put_upload_metadata(param, metadata)
               |> put_in_params(param, rewritten_upload)}

            {:error, status, body} ->
              {:halt, halt_with_error(conn, status, body)}
          end

        _other ->
          {:halt, halt_with_error(conn, 400, ~s({"error":"invalid_upload","param":"#{param}"}))}
      end
    end)
  end

  ## Internals

  defp guard_upload(%Plug.Upload{path: path, filename: original} = upload, config) do
    with {:ok, byte_size} <- check_size(path, config.max_bytes),
         {:ok, kind} <- check_magic(path, config),
         {:ok, sanitized} <- sanitize_filename(original) do
      storage = generate_storage_filename(sanitized)

      metadata = %{
        original_filename: original,
        sanitized_filename: sanitized,
        storage_filename: storage,
        kind: kind,
        byte_size: byte_size
      }

      {:ok, metadata, %{upload | filename: sanitized}}
    end
  end

  defp check_size(path, max_bytes) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size <= max_bytes ->
        {:ok, size}

      {:ok, %File.Stat{size: size}} ->
        {:error, 413, ~s({"error":"upload_too_large","byte_size":#{size},"max_bytes":#{max_bytes}})}

      {:error, reason} ->
        Logger.warning("UploadGuard: could not stat #{inspect(path)}: #{inspect(reason)}")
        {:error, 400, ~s({"error":"invalid_upload"})}
    end
  end

  defp check_magic(_path, %{require_magic_match: false}), do: {:ok, :unchecked}

  defp check_magic(path, %{allowed_kinds: allowed}) do
    with {:ok, header} <- read_header(path) do
      detected =
        Enum.find_value(@magic, fn {kind, prefixes} ->
          if kind in allowed and Enum.any?(prefixes, &String.starts_with?(header, &1)),
            do: kind
        end)

      case detected do
        nil ->
          {:error, 415, ~s({"error":"unsupported_media_type","allowed_kinds":#{inspect(allowed)}})}

        kind ->
          {:ok, kind}
      end
    end
  end

  defp read_header(path) do
    case File.open(path, [:read, :binary], fn io -> IO.binread(io, 16) end) do
      {:ok, header} when is_binary(header) ->
        {:ok, header}

      {:ok, _eof} ->
        {:error, 415, ~s({"error":"empty_upload"})}

      {:error, reason} ->
        Logger.warning("UploadGuard: could not read #{inspect(path)}: #{inspect(reason)}")
        {:error, 400, ~s({"error":"invalid_upload"})}
    end
  end

  @doc false
  def sanitize_filename(filename) when is_binary(filename) do
    sanitized =
      filename
      |> then(&Regex.replace(@control_char_re, &1, "_"))
      |> String.replace(["/", "\\"], "_")
      |> String.trim()
      |> truncate(@max_filename_bytes)

    case sanitized do
      "" -> {:ok, "unnamed"}
      other -> {:ok, other}
    end
  end

  def sanitize_filename(_), do: {:ok, "unnamed"}

  defp truncate(string, max) when byte_size(string) <= max, do: string

  defp truncate(string, max) do
    # Keep the extension when truncating.
    ext = Path.extname(string)

    if ext == "" or byte_size(ext) >= max do
      binary_part(string, 0, max)
    else
      stem_budget = max - byte_size(ext)
      binary_part(string, 0, stem_budget) <> ext
    end
  end

  defp generate_storage_filename(sanitized) do
    ext = Path.extname(sanitized)
    millis = System.system_time(:millisecond)
    random = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    "#{millis}-#{random}#{ext}"
  end

  defp put_upload_metadata(conn, param, metadata) do
    existing = Map.get(conn.assigns, :upload_guard, %{})
    assign(conn, :upload_guard, Map.put(existing, param, metadata))
  end

  defp put_in_params(conn, param, upload) do
    new_params = Map.put(conn.params || %{}, param, upload)
    %{conn | params: new_params}
  end

  defp halt_with_error(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
