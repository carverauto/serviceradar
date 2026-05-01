//go:build tinygo

package main

import "code.carverauto.dev/carverauto/serviceradar-sdk-dashboard/srdashboard"

//export alloc_bytes
func allocBytes(size uint32) uint32 {
	return srdashboard.AllocBytes(size)
}

//export free_bytes
func freeBytes(ptr uint32, size uint32) {
	srdashboard.FreeBytes(ptr, size)
}

var renderModel = []byte(`{
  "kind": "deck_map",
  "fit_bounds": true,
  "max_fit_zoom": 7,
  "view_state": {
    "longitude": -98.0,
    "latitude": 39.0,
    "zoom": 3.0
  },
  "layers": [
    {
      "id": "sites",
      "type": "scatterplot",
      "data_frame": "sites",
      "position": {
        "longitude": "longitude",
        "latitude": "latitude"
      },
      "radius_field": "ap_count",
      "radius_scale": 1.35,
      "radius_min": 7,
      "radius_max": 24,
      "fill_color": [37, 99, 235, 210],
      "line_color": [255, 255, 255, 230],
      "line_width": 1.25,
      "popup": {
        "title_field": "name",
        "fields": [
          {"label": "Site", "field": "site_code"},
          {"label": "Region", "field": "region"},
          {"label": "APs", "field": "ap_count"}
        ]
      }
    },
    {
      "id": "site-labels",
      "type": "text",
      "data_frame": "sites",
      "position": {
        "longitude": "longitude",
        "latitude": "latitude"
      },
      "text_field": "site_code",
      "size": 12,
      "pickable": false,
      "color": [17, 24, 39, 255],
      "background_color": [255, 255, 255, 235],
      "pixel_offset": [0, -18]
    }
  ]
}`)

//export sr_dashboard_init_json
func initJSON(ptr uint32, size uint32) {
	_, _ = ptr, size
	srdashboard.EmitRenderModelJSON(renderModel)
}

func main() {}
