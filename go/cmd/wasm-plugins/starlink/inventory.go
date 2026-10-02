package main

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"sort"
	"strconv"
	"strings"

	"github.com/tidwall/gjson"
)

type account struct {
	Number      string
	RegionCode  string
	Name        string
	Suspensions []string
}

type serviceLine struct {
	Number       string
	Nickname     string
	Product      string
	Active       bool
	PublicIP     bool
	DataPoolID   string
	StartDate    string
	EndDate      string
	AviationIATA string
	AviationICAO string
	TailNumber   string
	SeatCount    int
}

type terminal struct {
	ID              string // normalized vendor terminal ID
	Nickname        string
	KitSerial       string
	DishSerial      string
	ServiceLine     string
	L2VPNCircuitIDs []string
	Routers         []router
}

type router struct {
	ID              string // normalized vendor router ID
	Nickname        string
	TerminalID      string
	ConfigID        string
	HardwareVersion string
	LastBonded      string
}

// inventorySnapshot is one account's inventory. Complete is true only when
// every listing was read to its last page; an incomplete snapshot must never
// cause a device to be treated as gone.
type inventorySnapshot struct {
	Account       account
	Terminals     []terminal
	ServiceLines  map[string]serviceLine
	Complete      bool
	Pages         int
	InvalidRows   int
	DuplicateRows int
	Errors        []string
}

func collectInventory(c *apiClient) (*inventorySnapshot, error) {
	content, err := c.call(http.MethodGet, "/account", nil, nil, 0)
	if err != nil {
		return nil, err
	}
	acct := account{
		Number:     trimmed(content, "accountNumber"),
		RegionCode: trimmed(content, "regionCode"),
		Name:       trimmed(content, "accountName"),
	}
	for _, s := range content.Get("activeSuspensions").Array() {
		if v := strings.TrimSpace(s.String()); v != "" {
			acct.Suspensions = append(acct.Suspensions, v)
		}
	}
	if acct.Number == "" {
		// Without the account number there is no stable source instance, and
		// a snapshot keyed to nothing could retire another account's devices.
		return nil, &apiError{code: "starlink_account_unidentified"}
	}

	snap := &inventorySnapshot{
		Account:      acct,
		ServiceLines: map[string]serviceLine{},
		Complete:     true,
		Pages:        1,
	}

	seen := map[string]bool{}
	pages, err := c.listPages("/user-terminals", nil, func(row gjson.Result) {
		t, ok := parseTerminal(row)
		if !ok {
			snap.InvalidRows++
			return
		}
		// Page ordering has been inconsistent upstream; de-duplicate by ID.
		if seen[t.ID] {
			snap.DuplicateRows++
			return
		}
		seen[t.ID] = true
		snap.Terminals = append(snap.Terminals, t)
	})
	snap.Pages += pages
	if err != nil {
		snap.Complete = false
		snap.Errors = append(snap.Errors, errorCode(err))
	}

	pages, err = c.listPages("/service-lines", nil, func(row gjson.Result) {
		sl := parseServiceLine(row)
		if sl.Number == "" {
			snap.InvalidRows++
			return
		}
		snap.ServiceLines[sl.Number] = sl
	})
	snap.Pages += pages
	if err != nil {
		// Service lines only decorate devices, but a device emitted without
		// its service-line metadata would read as "no service line", so the
		// snapshot is not presented as complete.
		snap.Complete = false
		snap.Errors = append(snap.Errors, errorCode(err))
	}

	sort.Slice(snap.Terminals, func(i, j int) bool { return snap.Terminals[i].ID < snap.Terminals[j].ID })
	return snap, nil
}

func parseTerminal(row gjson.Result) (terminal, bool) {
	t := terminal{
		ID:          normalizeTerminalID(row.Get("userTerminalId").String()),
		Nickname:    trimmed(row, "nickname"),
		KitSerial:   normalizeSerial(row.Get("kitSerialNumber").String()),
		DishSerial:  normalizeSerial(row.Get("dishSerialNumber").String()),
		ServiceLine: trimmed(row, "serviceLineNumber"),
	}
	if t.ID == "" {
		return terminal{}, false
	}
	for _, circuit := range row.Get("l2VpnCircuits").Array() {
		ids := circuit.Get("circuitIds").Array()
		if len(ids) == 0 {
			// circuitId is deprecated upstream but still the only field on
			// older responses.
			ids = []gjson.Result{circuit.Get("circuitId")}
		}
		for _, id := range ids {
			if v := strings.TrimSpace(id.String()); v != "" {
				t.L2VPNCircuitIDs = append(t.L2VPNCircuitIDs, v)
			}
		}
	}
	for _, r := range row.Get("routers").Array() {
		parsed := router{
			ID:              normalizeRouterID(r.Get("routerId").String()),
			Nickname:        trimmed(r, "nickname"),
			TerminalID:      normalizeTerminalID(r.Get("userTerminalId").String()),
			ConfigID:        trimmed(r, "configId"),
			HardwareVersion: trimmed(r, "hardwareVersion"),
			LastBonded:      trimmed(r, "lastBonded"),
		}
		if parsed.ID == "" {
			continue
		}
		if parsed.TerminalID == "" {
			parsed.TerminalID = t.ID
		}
		t.Routers = append(t.Routers, parsed)
	}
	return t, true
}

func parseServiceLine(row gjson.Result) serviceLine {
	return serviceLine{
		Number:       trimmed(row, "serviceLineNumber"),
		Nickname:     trimmed(row, "nickname"),
		Product:      trimmed(row, "productReferenceId"),
		Active:       row.Get("active").Bool(),
		PublicIP:     row.Get("publicIp").Bool(),
		DataPoolID:   trimmed(row, "dataPoolId"),
		StartDate:    trimmed(row, "startDate"),
		EndDate:      trimmed(row, "endDate"),
		AviationIATA: trimmed(row, "iataCode"),
		AviationICAO: trimmed(row, "icaoCode"),
		TailNumber:   trimmed(row, "tailNumber"),
		SeatCount:    int(row.Get("seatCount").Int()),
	}
}

// contentHash is a stable digest of the snapshot's device content, used as
// the discovery reference hash so unchanged inventories are cheap to ingest.
func (s *inventorySnapshot) contentHash() string {
	h := sha256.New()
	for _, t := range s.Terminals {
		sl := s.ServiceLines[t.ServiceLine]
		parts := []string{
			t.ID, t.Nickname, t.KitSerial, t.DishSerial, t.ServiceLine,
			sl.Product, strconv.FormatBool(sl.Active), strings.Join(t.L2VPNCircuitIDs, ","),
		}
		for _, r := range t.Routers {
			parts = append(parts, r.ID, r.Nickname, r.ConfigID, r.HardwareVersion)
		}
		h.Write([]byte(strings.Join(parts, "\x1f")))
		h.Write([]byte{'\x1e'})
	}
	return hex.EncodeToString(h.Sum(nil))
}
