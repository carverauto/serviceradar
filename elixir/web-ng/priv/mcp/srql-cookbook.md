# SRQL cookbook (for MCP agents)

Copy-paste recipes. Replace hostnames, IPs, uids, and time windows. Grammar:
`serviceradar://srql/grammar`. Entity fields: `get_srql_catalog` with `entity`.

There is no cross-field `OR`. Do not write `(src_ip:x OR dst_ip:x)`.

## Devices

```
in:devices sort:last_seen:desc limit:25
in:devices first_seen:last_30d sort:first_seen:desc limit:200
in:devices hostname:%edge%
in:devices ip:10.20.0.0/16
in:devices vendor_name:Cisco sort:hostname:asc
in:devices vendor_name:"Axis Communications"
in:devices is_available:false sort:last_seen:desc
in:devices discovery_sources:(armis)
in:devices metadata.integration_type:armis metadata.query_label:managed
in:devices stats:count() as total by type
in:devices stats:count() as total by vendor_name sort:total:desc
in:devices stats:count() as total by tags.gate limit:100
```

`time:` on devices still means last-seen. Newly added devices use `first_seen:`.

## Events and logs

```
in:events time:last_24h sort:time:desc limit:50
in:events time:last_24h severity_id:>3 sort:time:desc
in:events device_id:<device-uid> time:last_7d sort:time:desc
in:events message:%authentication% time:last_24h
in:logs service_name:serviceradar-core severity_text:error time:last_1h
in:logs severity_text:(error,warn) time:last_6h sort:timestamp:desc
in:logs body:%timeout% time:last_24h
in:logs trace_id:<trace-id> sort:timestamp:asc
in:logs time:last_24h stats:count() as total by severity_text
```

## NetFlow

```
in:flows time:last_1h stats:sum(bytes_total) as bytes by src_ip sort:bytes:desc limit:10
in:flows ip:8.8.8.8 time:last_24h sort:bytes_total:desc
in:flows cidr:203.0.113.0/24 time:last_24h stats:sum(bytes_total) as bytes by app
in:flows dst_ip:8.8.8.8 time:last_24h sort:bytes_total:desc
in:flows bytes_total:>10000000 time:last_1h sort:bytes_total:desc
in:flows dst_port:(443,8443) time:last_1h
in:flows time:last_24h port:22 sort:time:desc limit:50
in:flows src_cidr:10.0.0.0/8 time:last_1h sort:bytes_total:desc
in:flows tag:site:austin time:last_1h
in:flows time:last_1h stats:sum(bytes_total) as bytes by app sort:bytes:desc
in:flows time:last_6h bucket:5m agg:sum value_field:bytes_total
```

`ip:` / `port:` / `cidr:` / `tag:` match **either** endpoint. Directional forms
are `src_*` / `dst_*`. `port:22` is “SSH either direction”.

## Attributed flows and public endpoints

```
in:public_endpoints port:22 limit:50
in:public_endpoints ip:23.138.124.7
in:public_endpoints exposure_class:Gateway sort:ip:asc limit:50
in:attributed_flows time:last_24h ip:23.138.124.7 sort:time:desc limit:50
in:attributed_flows time:last_24h service_name:forgejo-http sort:time:desc limit:50
in:attributed_flows time:last_24h port:22 sort:time:desc limit:50
in:attributed_flows time:last_1h process:gitea sort:time:desc limit:50
```

`in:attributed_flows port:22` can be empty while `in:flows port:22` is busy —
that means netflow saw SSH but process join did not. Not a broken `port:`.

## Composite checks

```
in:composite_results stats:count() as n by check,verdict
in:composite_results check:pci-isolation stats:count() as n by verdict
in:composite_results check:pci-isolation stats:"count() as n by input_key, input_value, input_stale"
```

Only `count()` is supported on composite_results. Do not group on `hostname`.

## BGP (BMP)

```
in:bmp_events time:last_24h sort:time:desc limit:50
in:bmp_events router_ip:10.42.68.85 time:last_24h sort:time:desc
in:bmp_events peer_ip:10.42.68.1 time:last_7d
in:bmp_events peer_asn:64512 time:last_24h
in:bmp_events prefix:%203.0.113.0% time:last_7d sort:time:desc
```

## Metrics and alerts

```
in:devices is_available:false time:last_15m
in:cpu_metrics time:last_15m usage_percent:>90 sort:usage_percent:desc
in:disk_metrics time:last_30m usage_percent:>85 sort:usage_percent:desc
in:memory_metrics time:last_15m usage_percent:>90
in:logs severity_text:error time:last_5m stats:count() as errors
in:events severity_id:>3 time:last_5m stats:count() as critical_events
in:services available:false time:last_10m
in:interfaces device_ip:10.0.0.5 latest:true
in:interfaces oper_status:down latest:true
in:gateways is_healthy:false
in:snmp_metrics device_id:<device-uid> time:last_1h sort:timestamp:desc
in:alerts status:open sort:triggered_at:desc
in:otel_metrics is_slow:true time:last_1h sort:timestamp:desc
in:traces status_code:2 time:last_1h sort:timestamp:desc
```

## Placeholders

Replace `<device-uid>`, `<trace-id>`, `<name>` with real values from a previous
`execute_srql` or `get_device` result. Do not leave the angle brackets in the query.
