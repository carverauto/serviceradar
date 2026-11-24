defmodule ServiceRadar.Camera.VisualCaptionClient do
  @moduledoc """
  OpenAI-compatible `/v1/chat/completions` multi-frame vision client for Smart
  camera clip action captioning.

  Supports both:
  - Cluster-internal HTTP VLM servers (e.g. in-cluster `llama-server` serving
    `Qwen2.5-VL-7B-Instruct` at `SERVICERADAR_CAMERA_VLM_URL`) via bounded `Req.post/2`
    with `retry: false` and `redirect: false`.
  - External HTTPS OpenAI-compatible VLM endpoints via `ServiceRadar.HTTP.EgressClient.request_json/4`
    with proxy, TLS trust anchors, and no-redirect protections.
  """

  alias ServiceRadar.HTTP.EgressClient

  require Logger

  @default_vlm_url "http://serviceradar-vlm-server:8080/v1/chat/completions"
  @default_vlm_model "qwen2.5-vl-7b-instruct"
  @default_prompt_version "v1"
  @default_timeout_ms 60_000
  @min_timeout_ms 1_000
  @max_timeout_ms 120_000
  @max_frames 6
  @max_tokens 240
  @max_caption_bytes 4_096
  @max_action_tags 12
  @max_tag_length 48

  @system_prompt """
  You analyze short security camera video clips given a chronological sequence of keyframes.
  Describe strictly what is visibly happening across the frames in 1 to 2 concise factual sentences, focusing on people, animals, vehicles, packages, and physical actions or movements.
  Return ONLY valid JSON matching: {"caption": "<1-2 concise factual sentences>", "action_tags": ["<lowercase action or activity tag>", ...]}.
  Include at most 12 short lowercase action_tags. Do not speculate beyond what is visible.
  """

  @user_prompt """
  These keyframes are sampled chronologically from a single security camera event clip.
  Describe the activity directly and return ONLY JSON with "caption" and "action_tags". /no_think
  """

  @doc """
  Returns `true` when `SERVICERADAR_CAMERA_VLM_ENABLED` is `"true"`.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    System.get_env("SERVICERADAR_CAMERA_VLM_ENABLED") == "true"
  end

  @doc "Resolves and normalizes the configured VLM `/v1/chat/completions` endpoint URL."
  @spec vlm_url(keyword()) :: String.t()
  def vlm_url(opts \\ []) when is_list(opts) do
    raw =
      opts[:url] ||
        non_empty_env("SERVICERADAR_CAMERA_VLM_URL") ||
        @default_vlm_url

    normalize_vlm_url(raw)
  end

  @doc "Resolves the configured VLM model identifier."
  @spec vlm_model_id(keyword()) :: String.t()
  def vlm_model_id(opts \\ []) when is_list(opts) do
    opts[:model_id] ||
      non_empty_env("SERVICERADAR_CAMERA_VLM_MODEL") ||
      @default_vlm_model
  end

  @doc "Resolves the active caption prompt version."
  @spec prompt_version(keyword()) :: String.t()
  def prompt_version(opts \\ []) when is_list(opts) do
    opts[:prompt_version] ||
      non_empty_env("SERVICERADAR_CAMERA_VLM_PROMPT_VERSION") ||
      @default_prompt_version
  end

  @doc "Resolves the bounded VLM HTTP request timeout in milliseconds."
  @spec timeout_ms(keyword()) :: pos_integer()
  def timeout_ms(opts \\ []) when is_list(opts) do
    raw =
      case Keyword.get(opts, :timeout_ms) do
        val when is_integer(val) -> val
        _ -> parse_env_int("SERVICERADAR_CAMERA_VLM_TIMEOUT_MS") || @default_timeout_ms
      end

    raw |> max(@min_timeout_ms) |> min(@max_timeout_ms)
  end

  @doc """
  Uniformly selects up to `max_count` items from a chronological list while
  preserving first and last endpoints when possible.
  """
  @spec uniform_sample(list(), pos_integer()) :: list()
  def uniform_sample(items, max_count \\ @max_frames)

  def uniform_sample(items, max_count)
      when is_list(items) and is_integer(max_count) and max_count >= 1 do
    total = length(items)

    cond do
      total <= max_count ->
        items

      max_count == 1 ->
        [Enum.at(items, div(total, 2))]

      true ->
        Enum.map(0..(max_count - 1), fn idx ->
          pos = round(idx * (total - 1) / (max_count - 1))
          Enum.at(items, pos)
        end)
    end
  end

  @doc """
  Sends 1..6 JPEG keyframe binaries to the configured OpenAI-compatible VLM
  endpoint and returns a normalized `{:ok, %{caption_text, action_tags, vlm_model_id, prompt_version}}`.
  """
  @spec caption_frames([binary()], keyword()) :: {:ok, map()} | {:error, term()}
  def caption_frames(frames, opts \\ [])

  def caption_frames(frames, opts) when is_list(frames) and is_list(opts) do
    valid_jpegs =
      frames
      |> Enum.filter(&(is_binary(&1) and byte_size(&1) > 0))
      |> uniform_sample(Keyword.get(opts, :max_frames, @max_frames))

    if valid_jpegs == [] do
      {:error, :no_frames}
    else
      url = vlm_url(opts)
      model_id = vlm_model_id(opts)
      p_version = prompt_version(opts)
      timeout = timeout_ms(opts)
      payload = build_chat_payload(valid_jpegs, model_id)
      headers = build_headers(opts)

      with {:ok, response_body} <- send_request(url, payload, headers, timeout, opts),
           {:ok, parsed} <- parse_completion_response(response_body) do
        {:ok,
         %{
           caption_text: parsed.caption_text,
           action_tags: parsed.action_tags,
           vlm_model_id: model_id,
           prompt_version: p_version
         }}
      end
    end
  end

  def caption_frames(_, _), do: {:error, :invalid_frames}

  @doc """
  Parses an OpenAI-compatible `/v1/chat/completions` JSON response (decoded map
  or raw JSON binary) into normalized `%{caption_text: String.t(), action_tags: [String.t()]}`.
  """
  @spec parse_completion_response(map() | binary()) ::
          {:ok, %{caption_text: String.t(), action_tags: [String.t()]}} | {:error, term()}
  def parse_completion_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> parse_completion_response(map)
      _ -> {:error, :invalid_vlm_response}
    end
  end

  def parse_completion_response(%{"choices" => [%{"message" => %{"content" => content}} | _]})
      when is_binary(content) do
    parse_structured_content(content)
  end

  def parse_completion_response(%{"choices" => [%{"message" => %{"content" => parts}} | _]})
      when is_list(parts) do
    text =
      Enum.map_join(parts, "\n", fn
        %{"text" => t} when is_binary(t) -> t
        t when is_binary(t) -> t
        _ -> ""
      end)

    parse_structured_content(text)
  end

  def parse_completion_response(_), do: {:error, :invalid_vlm_response}

  defp parse_structured_content(raw_content) when is_binary(raw_content) do
    without_closed_think = strip_think_blocks(raw_content)

    if unclosed_think_block?(without_closed_think) do
      {:error, :truncated_thinking_response}
    else
      cleaned = strip_code_fences(without_closed_think)

      case decode_json_object(cleaned) do
        {:ok, %{} = obj} ->
          raw_caption = Map.get(obj, "caption") || Map.get(obj, "caption_text")
          raw_tags = Map.get(obj, "action_tags") || Map.get(obj, "tags") || []
          normalize_caption_payload(raw_caption, raw_tags)

        _ ->
          normalize_caption_payload(cleaned, [])
      end
    end
  end

  defp decode_json_object(text) do
    case Jason.decode(text) do
      {:ok, %{} = obj} ->
        {:ok, obj}

      _ ->
        decode_embedded_json_object(text, [~r/\{.*?\}/s, ~r/\{.*\}/s])
    end
  end

  defp decode_embedded_json_object(_text, []), do: :error

  defp decode_embedded_json_object(text, [pattern | rest]) do
    case Regex.run(pattern, text) do
      [json_slice] ->
        case Jason.decode(json_slice) do
          {:ok, %{} = obj} -> {:ok, obj}
          _ -> decode_embedded_json_object(text, rest)
        end

      _ ->
        decode_embedded_json_object(text, rest)
    end
  end

  defp normalize_caption_payload(raw_caption, raw_tags) when is_binary(raw_caption) do
    caption =
      raw_caption
      |> String.trim()
      |> String.replace(~r/\s+/u, " ")
      |> truncate_bytes(@max_caption_bytes)

    if caption == "" do
      {:error, :empty_caption}
    else
      tags =
        raw_tags
        |> List.wrap()
        |> Enum.filter(&is_binary/1)
        |> Enum.map(fn tag ->
          tag
          |> String.trim()
          |> String.downcase()
          |> String.replace(~r/\s+/u, " ")
          |> String.slice(0, @max_tag_length)
        end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.take(@max_action_tags)

      {:ok, %{caption_text: caption, action_tags: tags}}
    end
  end

  defp normalize_caption_payload(_, _), do: {:error, :empty_caption}

  defp strip_think_blocks(text) do
    text
    |> String.replace(~r/<think>.*?<\/think>/isu, "")
    |> String.trim()
  end

  defp unclosed_think_block?(text) do
    Regex.match?(~r/<think>/iu, text)
  end

  defp strip_code_fences(text) do
    trimmed = String.trim(text)

    trimmed
    |> String.replace(~r/\A```(?:[a-zA-Z0-9_-]+)?\s*/i, "")
    |> String.replace(~r/\s*```\z/, "")
    |> String.trim()
  end

  defp normalize_vlm_url(url) when is_binary(url) do
    trimmed = url |> String.trim() |> String.trim_trailing("/")

    cond do
      trimmed == "" -> @default_vlm_url
      String.ends_with?(trimmed, "/chat/completions") -> trimmed
      String.ends_with?(trimmed, "/v1") -> trimmed <> "/chat/completions"
      true -> trimmed <> "/v1/chat/completions"
    end
  end

  defp normalize_vlm_url(_), do: @default_vlm_url

  defp truncate_bytes(str, max_bytes) when byte_size(str) <= max_bytes, do: str

  defp truncate_bytes(str, max_bytes) do
    str
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn g, {acc, size} ->
      g_size = byte_size(g)

      if size + g_size <= max_bytes do
        {:cont, {acc <> g, size + g_size}}
      else
        {:halt, {acc, size}}
      end
    end)
    |> elem(0)
    |> String.trim()
  end

  defp build_chat_payload(jpegs, model_id) do
    image_parts =
      Enum.map(jpegs, fn jpeg ->
        %{
          "type" => "image_url",
          "image_url" => %{
            "url" => "data:image/jpeg;base64," <> Base.encode64(jpeg)
          }
        }
      end)

    %{
      "model" => model_id,
      "temperature" => 0.1,
      "max_tokens" => @max_tokens,
      "enable_thinking" => false,
      "chat_template_kwargs" => %{"enable_thinking" => false},
      "response_format" => %{"type" => "json_object"},
      "messages" => [
        %{"role" => "system", "content" => String.trim(@system_prompt)},
        %{
          "role" => "user",
          "content" => [%{"type" => "text", "text" => String.trim(@user_prompt)} | image_parts]
        }
      ]
    }
  end

  defp build_headers(opts) do
    base = [{"accept", "application/json"}, {"content-type", "application/json"}]

    case Keyword.get(opts, :api_key) do
      key when is_binary(key) and key != "" ->
        [{"authorization", "Bearer #{key}"} | base]

      _ ->
        base
    end
  end

  defp send_request(url, payload, headers, timeout, opts) do
    case Keyword.get(opts, :http_client) do
      fun when is_function(fun, 4) ->
        normalize_http_result(fun.(url, payload, headers, timeout))

      _ ->
        case URI.parse(url) do
          %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
            url
            |> then(
              &EgressClient.request_json(:post, &1, payload,
                headers: headers,
                receive_timeout: timeout,
                redirect: false
              )
            )
            |> normalize_http_result()

          %URI{scheme: "http", host: host} when is_binary(host) and host != "" ->
            url
            |> Req.post(
              json: payload,
              headers: headers,
              receive_timeout: timeout,
              connect_options: [timeout: min(timeout, 10_000)],
              retry: false,
              redirect: false
            )
            |> normalize_http_result()

          _ ->
            {:error, :invalid_vlm_url}
        end
    end
  end

  defp normalize_http_result({:ok, %{status: status, body: body}}) when status in 200..299 do
    {:ok, body}
  end

  defp normalize_http_result({:ok, %{status: status}}) do
    {:error, {:vlm_http_error, status}}
  end

  defp normalize_http_result({:error, reason}), do: {:error, reason}
  defp normalize_http_result(other), do: {:error, {:unexpected_vlm_result, other}}

  defp non_empty_env(name) do
    case System.get_env(name) do
      val when is_binary(val) ->
        trimmed = String.trim(val)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp parse_env_int(name) do
    case non_empty_env(name) do
      nil ->
        nil

      str ->
        case Integer.parse(str) do
          {n, ""} -> n
          _ -> nil
        end
    end
  end
end
