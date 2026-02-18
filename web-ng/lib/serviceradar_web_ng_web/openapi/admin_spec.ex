defmodule ServiceRadarWebNGWeb.OpenAPI.AdminSpec do
  @moduledoc """
  OpenAPI 3.0 spec for custom admin JSON endpoints.
  """

  @spec document() :: map()
  def document do
    %{
      "openapi" => "3.0.3",
      "info" => %{
        "title" => "ServiceRadar Admin API",
        "version" => "1.0.0"
      },
      "paths" => %{
        "/api/admin/bmp-settings" => %{
          "get" => %{
            "summary" => "Get BMP settings",
            "description" =>
              "Returns deployment-level BMP ingestion and God-View causal overlay settings.",
            "tags" => ["BMP Settings"],
            "responses" => %{
              "200" => %{
                "description" => "BMP settings",
                "content" => %{
                  "application/json" => %{
                    "schema" => %{"$ref" => "#/components/schemas/BmpSettings"}
                  }
                }
              },
              "403" => %{"description" => "Forbidden"}
            }
          },
          "put" => %{
            "summary" => "Update BMP settings",
            "description" =>
              "Updates one or more BMP settings. Triggers retention policy refresh and runtime cache refresh.",
            "tags" => ["BMP Settings"],
            "requestBody" => %{
              "required" => true,
              "content" => %{
                "application/json" => %{
                  "schema" => %{"$ref" => "#/components/schemas/BmpSettingsUpdate"}
                }
              }
            },
            "responses" => %{
              "200" => %{
                "description" => "Updated BMP settings",
                "content" => %{
                  "application/json" => %{
                    "schema" => %{"$ref" => "#/components/schemas/BmpSettings"}
                  }
                }
              },
              "400" => %{"description" => "Invalid request payload"},
              "403" => %{"description" => "Forbidden"},
              "422" => %{"description" => "Validation error"}
            }
          }
        }
      },
      "components" => %{
        "schemas" => %{
          "BmpSettings" => bmp_settings_schema(),
          "BmpSettingsUpdate" => bmp_settings_update_schema()
        }
      }
    }
  end

  defp bmp_settings_schema do
    %{
      "type" => "object",
      "required" => [
        "bmp_routing_retention_days",
        "bmp_ocsf_min_severity",
        "god_view_causal_overlay_window_seconds",
        "god_view_causal_overlay_max_events",
        "god_view_routing_causal_severity_threshold"
      ],
      "properties" => setting_properties()
    }
  end

  defp bmp_settings_update_schema do
    %{
      "type" => "object",
      "properties" => setting_properties(),
      "additionalProperties" => false
    }
  end

  defp setting_properties do
    %{
      "bmp_routing_retention_days" => %{
        "type" => "integer",
        "minimum" => 1,
        "maximum" => 30,
        "description" => "Retention in days for raw BMP routing events."
      },
      "bmp_ocsf_min_severity" => %{
        "type" => "integer",
        "minimum" => 0,
        "maximum" => 6,
        "description" => "Minimum BMP severity promoted into OCSF events."
      },
      "god_view_causal_overlay_window_seconds" => %{
        "type" => "integer",
        "minimum" => 30,
        "maximum" => 3600,
        "description" => "God-View causal overlay lookback window in seconds."
      },
      "god_view_causal_overlay_max_events" => %{
        "type" => "integer",
        "minimum" => 32,
        "maximum" => 10_000,
        "description" => "Max number of causal events merged for God-View overlays."
      },
      "god_view_routing_causal_severity_threshold" => %{
        "type" => "integer",
        "minimum" => 0,
        "maximum" => 6,
        "description" => "Minimum routing event severity included in overlay merges."
      }
    }
  end
end
