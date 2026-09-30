package main

import (
	"net/http"
	"testing"
)

func accountFixture() string {
	return envelope(`{"accountNumber":"` + testAccountNumber + `","regionCode":"US","accountName":"Example Fleet","activeSuspensions":[]}`)
}

func terminalsPage(pageIndex int, last bool, rows string) string {
	lastText := "false"
	if last {
		lastText = "true"
	}
	return envelope(`{"pageIndex":` + itoa(pageIndex) + `,"limit":100,"isLastPage":` + lastText + `,"totalCount":2,"results":[` + rows + `]}`)
}

func itoa(n int) string {
	return map[int]string{0: "0", 1: "1", 2: "2"}[n]
}

const terminalRowA = `{"userTerminalId":"` + testTerminalA + `","nickname":"Unit A","kitSerialNumber":"KITTEST0000001",` +
	`"dishSerialNumber":"DISHTEST0000001","serviceLineNumber":"` + testServiceLine + `",` +
	`"l2VpnCircuits":[{"circuitIds":["circuit-test-1","circuit-test-2"]}],` +
	`"routers":[{"routerId":"` + testRouterA + `","nickname":"Router A","userTerminalId":"` + testTerminalA + `","configId":null,"hardwareVersion":"v4"}]}`

const terminalRowB = `{"userTerminalId":"` + testTerminalB + `","nickname":null,"kitSerialNumber":"000000","dishSerialNumber":"",` +
	`"serviceLineNumber":null,"l2VpnCircuits":[],"routers":[]}`

const serviceLinesPage = `{"pageIndex":0,"limit":100,"isLastPage":true,"totalCount":1,"results":[` +
	`{"serviceLineNumber":"` + testServiceLine + `","nickname":"Line 1","productReferenceId":"example-product","active":true,"publicIp":false}]}`

func TestCollectInventoryWalksPagesAndDeduplicates(t *testing.T) {
	fake := newFakeHTTP(t)
	fake.on(http.MethodGet, "/account", 200, accountFixture())
	fake.on(http.MethodGet, "/user-terminals?page=0", 200, terminalsPage(0, false, terminalRowA))
	// Upstream page ordering has repeated rows across pages; the repeat of A
	// must not produce a second terminal.
	fake.on(http.MethodGet, "/user-terminals?page=1", 200, terminalsPage(1, true, terminalRowA+","+terminalRowB))
	fake.on(http.MethodGet, "/service-lines?page=0", 200, envelope(serviceLinesPage))

	snap, err := collectInventory(newAPIClient(fake, mustConfig(t, `{}`)))
	if err != nil {
		t.Fatalf("collectInventory: %v", err)
	}
	if !snap.Complete {
		t.Fatalf("snapshot incomplete: %v", snap.Errors)
	}
	if got := len(snap.Terminals); got != 2 {
		t.Fatalf("terminals = %d, want 2", got)
	}
	if snap.DuplicateRows != 1 {
		t.Fatalf("duplicate rows = %d, want 1", snap.DuplicateRows)
	}
	a := snap.Terminals[0]
	if a.ID != testTerminalA || a.KitSerial != "KITTEST0000001" || len(a.Routers) != 1 {
		t.Fatalf("terminal A parsed wrong: %+v", a)
	}
	if len(a.L2VPNCircuitIDs) != 2 {
		t.Fatalf("circuit ids = %v, want both redundant-group members", a.L2VPNCircuitIDs)
	}
	// Terminal B carries a placeholder kit serial and a blank dish serial;
	// neither may survive as an identifier.
	b := snap.Terminals[1]
	if b.KitSerial != "" || b.DishSerial != "" {
		t.Fatalf("placeholder serials kept: %+v", b)
	}
	if snap.ServiceLines[testServiceLine].Product != "example-product" {
		t.Fatalf("service line not indexed: %+v", snap.ServiceLines)
	}
}

func TestCollectInventoryPartialFailureIsIncomplete(t *testing.T) {
	fake := newFakeHTTP(t)
	fake.on(http.MethodGet, "/account", 200, accountFixture())
	fake.on(http.MethodGet, "/user-terminals?page=0", 200, terminalsPage(0, false, terminalRowA))
	fake.on(http.MethodGet, "/user-terminals?page=1", 503, "upstream unavailable")
	fake.on(http.MethodGet, "/service-lines?page=0", 200, envelope(serviceLinesPage))

	snap, err := collectInventory(newAPIClient(fake, mustConfig(t, `{}`)))
	if err != nil {
		t.Fatalf("collectInventory: %v", err)
	}
	if snap.Complete {
		t.Fatal("a failed page must leave the snapshot incomplete")
	}
	if len(snap.Terminals) != 1 {
		t.Fatalf("rows read before the failure must be kept, got %d", len(snap.Terminals))
	}
	if len(snap.Errors) != 1 || snap.Errors[0] != "starlink_upstream_error" {
		t.Fatalf("errors = %v", snap.Errors)
	}
}

func TestCollectInventoryRequiresAccountNumber(t *testing.T) {
	fake := newFakeHTTP(t)
	fake.on(http.MethodGet, "/account", 200, envelope(`{"accountNumber":"","regionCode":"US"}`))

	if _, err := collectInventory(newAPIClient(fake, mustConfig(t, `{}`))); errorCode(err) != "starlink_account_unidentified" {
		t.Fatalf("err = %v, want starlink_account_unidentified", err)
	}
}

func TestAPIClientStopsAtRequestBudget(t *testing.T) {
	fake := newFakeHTTP(t)
	fake.on(http.MethodGet, "/account", 200, accountFixture())

	client := newAPIClient(fake, mustConfig(t, `{"max_requests_per_run":1}`))
	if _, err := client.call(http.MethodGet, "/account", nil, nil, 0); err != nil {
		t.Fatalf("first call: %v", err)
	}
	if _, err := client.call(http.MethodGet, "/account", nil, nil, 0); errorCode(err) != "starlink_request_budget_exhausted" {
		t.Fatalf("second call err = %v", err)
	}
	if len(fake.requests) != 1 {
		t.Fatalf("requests sent = %d, want 1", len(fake.requests))
	}
}

func TestAPIClientRejectedEnvelope(t *testing.T) {
	fake := newFakeHTTP(t)
	fake.on(http.MethodGet, "/account", 200,
		`{"errors":[{"memberNames":["x"],"errorMessage":"bad"}],"isValid":false,"content":null}`)

	_, err := newAPIClient(fake, mustConfig(t, `{}`)).call(http.MethodGet, "/account", nil, nil, 0)
	if errorCode(err) != "starlink_request_rejected" {
		t.Fatalf("err = %v", err)
	}
}

func mustConfig(t *testing.T, raw string) Config {
	t.Helper()
	cfg, err := parseConfig([]byte(raw))
	if err != nil {
		t.Fatalf("parseConfig(%s): %v", raw, err)
	}
	return cfg
}
