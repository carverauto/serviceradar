# ServiceRadar Network Mapper

## UBNT

This mapper is designed to work with UBNT (Ubiquiti Networks) devices, specifically for integrating with their UniFi network controllers. It allows you to manage and monitor multiple UniFi controllers by providing their API details.

**Configuration Example**:

```json
{
  "unifi_apis": [
    {
      "name": "Main Controller",
      "base_url": "https://192.168.1.1/proxy/network/integration/v1",
      "api_key": "NYlYuZSN591uSBBGLL8t4GM8j5436cxd"
    },
    {
      "name": "Secondary Controller",
      "base_url": "https://192.168.2.1/proxy/network/integration/v1",
      "api_key": "ABcDeFgHiJkLmNoPqRsTuVwXyZ123456"
    }
  ]
}
```