# Capability: Edge Sites

Edge Sites enable customers to deploy NATS leaf servers in their edge networks, providing local message buffering, WAN resilience, and simplified network topology for collector deployments.

## ADDED Requirements

### Requirement: EdgeSite Resource Management

The platform SHALL allow tenant administrators to create and manage edge site resources representing deployment locations in their network.

#### Scenario: Create Edge Site

**Given** a tenant administrator is authenticated
**When** they create an edge site with name "NYC Office" and slug "nyc-office"
**Then** an EdgeSite resource is created with status "pending"
**And** a NatsLeafServer resource is created for the site
**And** the leaf provisioning worker is triggered

#### Scenario: Edge Site Slug Uniqueness

**Given** tenant "acme" has an edge site with slug "nyc-office"
**When** they attempt to create another edge site with slug "nyc-office"
**Then** the creation fails with a uniqueness error

#### Scenario: List Tenant Edge Sites

**Given** tenant "acme" has edge sites "nyc-office" and "chicago-dc"
**When** a tenant administrator lists edge sites
**Then** they see both sites with their current status
**And** they do not see edge sites from other tenants

### Requirement: NATS Leaf Server Provisioning

The platform SHALL automatically provision NATS leaf server configuration and certificates when an edge site is created.

#### Scenario: Generate Leaf Certificates

**Given** an edge site is created for tenant "acme" with slug "nyc-office"
**When** the provision leaf worker runs
**Then** a leaf certificate is generated with CN "leaf.nyc-office.acme.serviceradar"
**And** the certificate is signed by the tenant's CA
**And** the private key is stored encrypted via AshCloak
**And** the NatsLeafServer status changes to "provisioned"

#### Scenario: Generate NATS Leaf Configuration

**Given** a NatsLeafServer is provisioned for edge site "nyc-office"
**When** configuration is generated
**Then** the config includes the SaaS upstream URL
**And** the config includes mTLS settings for the leaf connection
**And** the config includes JetStream with domain "edge"
**And** the config includes tenant NATS credentials

### Requirement: Edge Site Bundle Download

The platform SHALL allow tenant administrators to download a configuration bundle containing everything needed to deploy the NATS leaf server.

#### Scenario: Download Edge Site Bundle

**Given** edge site "nyc-office" is provisioned
**When** the administrator downloads the configuration bundle
**Then** they receive a tarball containing:
  - nats/nats-leaf.conf
  - nats/certs/nats-server.pem (server cert for local clients)
  - nats/certs/nats-server-key.pem
  - nats/certs/nats-leaf.pem (leaf cert for upstream)
  - nats/certs/nats-leaf-key.pem
  - nats/certs/ca-chain.pem
  - creds/tenant.creds
  - setup.sh
  - README.md

#### Scenario: Regenerate Configuration

**Given** edge site "nyc-office" has been deployed
**When** the administrator requests configuration regeneration
**Then** new certificates are generated
**And** the config checksum is updated
**And** a new bundle can be downloaded

### Requirement: Site-Aware Collector Configuration

Collectors MUST be associable with an edge site, which SHALL determine their NATS connection URL.

#### Scenario: Create Collector for Edge Site

**Given** edge site "nyc-office" exists with nats_leaf_url "nats://10.0.1.50:4222"
**When** a collector package is created with edge_site_id set to the site
**Then** the generated collector config uses "nats://10.0.1.50:4222" as the NATS URL

#### Scenario: Create Collector Without Edge Site

**Given** no edge site is specified
**When** a collector package is created with edge_site_id as nil
**Then** the generated collector config uses the SaaS NATS URL

#### Scenario: List Collectors by Edge Site

**Given** edge site "nyc-office" has collectors "flowgger-1" and "trapd-1"
**When** viewing the edge site detail page
**Then** both collectors are shown as assigned to the site

### Requirement: Edge Site Health Monitoring

The platform SHALL monitor NATS leaf connection status and MUST display health information to administrators.

#### Scenario: Leaf Connection Detected

**Given** edge site "nyc-office" has a deployed NATS leaf
**When** the leaf successfully connects to the SaaS hub
**Then** the NatsLeafServer status changes to "connected"
**And** the EdgeSite last_seen_at is updated
**And** the UI shows the site as online

#### Scenario: Leaf Disconnection Detected

**Given** edge site "nyc-office" was connected
**When** the leaf loses connection to the SaaS hub
**Then** the NatsLeafServer status changes to "disconnected"
**And** the UI shows the site as offline
**And** (optional) an alert is triggered after prolonged disconnect

### Requirement: Edge Sites UI

The platform SHALL provide a web interface for tenant administrators to manage edge sites.

#### Scenario: Edge Sites List Page

**Given** a tenant administrator navigates to /admin/edge-sites
**Then** they see a list of their edge sites
**And** each site shows name, status, and last seen time
**And** there is an "Add Edge Site" button

#### Scenario: Add Edge Site Wizard

**Given** a tenant administrator clicks "Add Edge Site"
**When** they complete the wizard
**Then** Step 1 collects site name and slug
**And** Step 2 offers deployment method choices (Docker/package/manual)
**And** Step 3 provides the configuration bundle download
**And** Step 4 allows connectivity verification (optional)

#### Scenario: Edge Site Detail Page

**Given** a tenant administrator views edge site "nyc-office"
**Then** they see the site name, status, and NATS leaf URL
**And** they see the NATS leaf server connection status
**And** they see collectors assigned to this site
**And** they can download the configuration bundle
**And** they can regenerate the configuration
**And** they see certificate expiration warnings if applicable

## Related Capabilities

- `collector-packages` - Collectors may be assigned to edge sites
- `tenant-ca` - Leaf certificates are signed by tenant CA
- `nats-tenant-isolation` - Leaf uses tenant NATS account credentials
