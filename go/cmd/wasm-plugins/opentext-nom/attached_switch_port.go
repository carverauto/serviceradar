package main

import (
	"context"
	"encoding/json"
	"net/url"
	"strings"
	"unicode"
)

const (
	nnmAttachedSwitchPortPath = "/nnmi/api/disco/v1/attachedSwitchPort"
	nnmCollectionAccept       = "application/vnd.hpe.nmc.collection+hal+json"
	nnmEntityAccept           = "application/vnd.hpe.nmc.entity+hal+json"
	maxL2Endpoints            = 5000
)

func (c *Collector) collectAttachedSwitchPorts(ctx context.Context, cfg Config) []InventoryDevice {
	if strings.TrimSpace(cfg.NNMURL) == "" || len(cfg.L2Endpoints) == 0 {
		return nil
	}

	seen := make(map[string]struct{})
	devices := make([]InventoryDevice, 0, len(cfg.L2Endpoints))
	limit := len(cfg.L2Endpoints)
	if limit > maxL2Endpoints {
		limit = maxL2Endpoints
	}

	for _, endpoint := range cfg.L2Endpoints[:limit] {
		device, ok := c.lookupAttachedSwitchPort(ctx, cfg, endpoint)
		if !ok || device.SourceObjectID == "" {
			continue
		}
		if _, exists := seen[device.SourceObjectID]; exists {
			continue
		}
		seen[device.SourceObjectID] = struct{}{}
		devices = append(devices, device)
	}
	return devices
}

func (c *Collector) lookupAttachedSwitchPort(ctx context.Context, cfg Config, endpoint L2Endpoint) (InventoryDevice, bool) {
	query := url.Values{}
	mac := normalizeLookupMAC(endpoint.MAC)
	ip := strings.TrimSpace(endpoint.IP)
	if mac != "" {
		query.Set("mac", mac)
	} else if ip != "" {
		query.Set("ipAddress", ip)
	} else {
		return InventoryDevice{}, false
	}

	collectionURL, err := joinHTTPSOriginPath(cfg.NNMURL, nnmAttachedSwitchPortPath)
	if err != nil {
		return InventoryDevice{}, false
	}
	collectionURL += "?" + query.Encode()

	response, err := c.doWithRetry(ctx, cfg, HTTPRequest{
		Method: "GET",
		URL:    collectionURL,
		Headers: map[string]string{
			"Accept": nnmCollectionAccept,
		},
		TimeoutMS: cfg.RequestTimeoutSeconds * 1000,
	})
	if err != nil || response.Status != 200 {
		return InventoryDevice{}, false
	}

	href := firstCollectionHref(response.Body)
	if href == "" {
		return InventoryDevice{}, false
	}

	entity, ok := c.getNNMEntity(ctx, cfg, href)
	if !ok {
		return InventoryDevice{}, false
	}

	port := halLinkTitle(entity, "interface")
	vlanTitle := halLinkTitle(entity, "vlan")
	switchHostname := ""
	ifName := port
	ifAlias := ""
	if interfaceHref := halLinkHref(entity, "interface"); interfaceHref != "" {
		if iface, ifaceOK := c.getNNMEntity(ctx, cfg, interfaceHref); ifaceOK {
			switchHostname = halLinkTitle(iface, "hostedOn")
			if value := stringValue(iface, "ifName"); value != "" {
				ifName = value
			}
			ifAlias = stringValue(iface, "ifAlias")
		}
	}
	if switchHostname == "" || ifName == "" {
		return InventoryDevice{}, false
	}

	objectID := strings.ToLower(firstNonEmpty(mac, ip))
	vlanID := vlanIDFromTitle(vlanTitle)
	facts := map[string]any{
		"switch_port_attachment": map[string]any{
			"switch_hostname": switchHostname,
			"port":            ifName,
			"if_alias":        ifAlias,
			"vlan_id":         vlanID,
			"vlan_name":       vlanTitle,
			"raw":             switchHostname + ":" + ifName,
		},
	}
	if vlanID != "" {
		facts["vlan_uid"] = vlanID
	}

	metadata := map[string]any{
		"instance_id":                cfg.InstanceID,
		"facts":                      facts,
		"opentext_nom_access_switch": switchHostname + ":" + ifName,
		"source_metadata": map[string]any{
			"pass": "attached_switch_port",
		},
	}
	if vlanTitle != "" {
		metadata["opentext_nom_vlan"] = vlanTitle
	}

	return InventoryDevice{
		IntegrationID:  "opentext-nom:v1:" + cfg.InstanceID + ":l2:" + objectID,
		SourceObjectID: objectID,
		IP:             ip,
		MAC:            endpoint.MAC,
		Metadata:       metadata,
	}, true
}

func (c *Collector) getNNMEntity(ctx context.Context, cfg Config, href string) (map[string]any, bool) {
	response, err := c.doWithRetry(ctx, cfg, HTTPRequest{
		Method: "GET",
		URL:    href,
		Headers: map[string]string{
			"Accept": nnmEntityAccept,
		},
		TimeoutMS: cfg.RequestTimeoutSeconds * 1000,
	})
	if err != nil || response.Status != 200 {
		return nil, false
	}
	var entity map[string]any
	if err := json.Unmarshal(response.Body, &entity); err != nil {
		return nil, false
	}
	return entity, true
}

func firstCollectionHref(body []byte) string {
	var payload map[string]any
	if err := json.Unmarshal(body, &payload); err != nil {
		return ""
	}
	items, _ := payload["items"].([]any)
	if len(items) == 0 {
		if embedded, ok := payload["_embedded"].(map[string]any); ok {
			items, _ = embedded["item"].([]any)
			if len(items) == 0 {
				items, _ = embedded["items"].([]any)
			}
		}
	}
	if len(items) == 0 {
		return ""
	}
	item, _ := items[0].(map[string]any)
	if href := halSelfHref(item); href != "" {
		return href
	}
	return ""
}

func halSelfHref(value map[string]any) string {
	links, _ := value["_links"].(map[string]any)
	self, _ := links["self"].(map[string]any)
	href, _ := self["href"].(string)
	return strings.TrimSpace(href)
}

func halLinkTitle(value map[string]any, rel string) string {
	links, _ := value["_links"].(map[string]any)
	link, _ := links[rel].(map[string]any)
	title, _ := link["title"].(string)
	return strings.TrimSpace(title)
}

func halLinkHref(value map[string]any, rel string) string {
	links, _ := value["_links"].(map[string]any)
	link, _ := links[rel].(map[string]any)
	href, _ := link["href"].(string)
	return strings.TrimSpace(href)
}

func stringValue(value map[string]any, key string) string {
	raw, _ := value[key].(string)
	return strings.TrimSpace(raw)
}

func normalizeLookupMAC(value string) string {
	var builder strings.Builder
	for _, r := range strings.TrimSpace(value) {
		if unicode.Is(unicode.ASCII_Hex_Digit, r) {
			builder.WriteRune(unicode.ToUpper(r))
		}
	}
	if builder.Len() != 12 {
		return ""
	}
	return builder.String()
}

func vlanIDFromTitle(title string) string {
	title = strings.TrimSpace(title)
	if title == "" {
		return ""
	}
	for _, r := range title {
		if r < '0' || r > '9' {
			return ""
		}
	}
	return title
}
