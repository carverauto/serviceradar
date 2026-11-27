defmodule ServiceRadarUI.TranslateErrorTest do
  # The translator is application config, so this case must not run beside
  # another test that reads the same key.
  use ExUnit.Case, async: false

  test "interpolates placeholders when no translator is configured" do
    Application.delete_env(:serviceradar_ui, :error_translator)

    assert ServiceRadarUI.translate_error({"must be at least %{count} characters", count: 3}) ==
             "must be at least 3 characters"

    assert ServiceRadarUI.translate_error("already taken") == "already taken"
  end

  test "calls the configured translator with the original tuple" do
    previous = Application.get_env(:serviceradar_ui, :error_translator)
    Application.put_env(:serviceradar_ui, :error_translator, {__MODULE__, :translate})

    on_exit(fn ->
      if previous do
        Application.put_env(:serviceradar_ui, :error_translator, previous)
      else
        Application.delete_env(:serviceradar_ui, :error_translator)
      end
    end)

    assert ServiceRadarUI.translate_error({"bad %{count}", count: 2}) == "BAD 2"
  end

  def translate({"bad %{count}", opts}), do: "BAD #{opts[:count]}"
end
