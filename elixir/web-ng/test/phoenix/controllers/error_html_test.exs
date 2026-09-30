defmodule ServiceRadarWebNGWeb.ErrorHTMLTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.Template, only: [render_to_string: 4]

  @moduletag :web_ng_shared_fixture_db

  # Bring render_to_string/4 for testing custom views
  test "renders 404.html" do
    assert render_to_string(ServiceRadarWebNGWeb.ErrorHTML, "404", "html", []) == "Not Found"
  end

  test "renders 500.html" do
    assert render_to_string(ServiceRadarWebNGWeb.ErrorHTML, "500", "html", []) ==
             "Internal Server Error"
  end
end
