## 1. Investigation

- [ ] 1.1 Reproduce the large-CIDR expansion bug described in GH issue #2146
- [ ] 1.2 Confirm whether network/broadcast filtering is intended to apply before or after the 256-IP cap

## 2. Implementation

- [ ] 2.1 Fix `pkg/mapper/utils.go:collectIPsFromRange` large-range loop to increment the same IP used for stringification
- [ ] 2.2 Fix `pkg/mapper/utils.go:filterNetworkAndBroadcast` to safely handle IPv4 addresses returned in 16-byte form by `net.ParseCIDR`
- [ ] 2.3 Add unit tests for IPv4 CIDR expansion (small range fully expanded; large range capped and returns multiple unique targets)
- [ ] 2.4 Run `gofmt` on touched Go files

## 3. Verification

- [ ] 3.1 Run `go test ./pkg/mapper -run Test.*CIDR` (or equivalent targeted coverage)
- [ ] 3.2 Run `go test ./...` (or `make test`) if the change touches shared logic beyond mapper
