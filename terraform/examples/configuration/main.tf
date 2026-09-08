terraform {
  required_version = ">= 1.11.0"
  required_providers {
    serviceradar = {
      source = "carverauto/serviceradar"
    }
  }
}

# Supply SERVICERADAR_ENDPOINT and SERVICERADAR_API_KEY securely.
provider "serviceradar" {}

variable "awx_sync_token" {
  type      = string
  sensitive = true
  ephemeral = true
}

variable "agent_id" {
  type        = string
  description = "Exact enrolled edge agent UUID, selected by the operator."
}

variable "execution_credential_id" {
  type        = string
  description = "Existing unified credential for the reviewed execution principal."
}

resource "serviceradar_network_credential_secret" "awx_sync" {
  idempotency_key     = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
  name                = "Example AWX inventory reader"
  credential_provider = "awx"
  auth_method         = "bearer_token"
  values_version      = 1
  values_wo = {
    api_token = var.awx_sync_token
  }
}

data "serviceradar_network_credential_secret" "execution" {
  id = var.execution_credential_id
}

resource "serviceradar_ansible_controller" "example" {
  idempotency_key                 = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
  name                            = "Example AWX controller"
  base_url                        = "https://awx.example.com"
  agent_id                        = var.agent_id
  sync_credential_secret_id        = serviceradar_network_credential_secret.awx_sync.id
  execution_credential_secret_id   = data.serviceradar_network_credential_secret.execution.id
  inventory_sync_interval_seconds = 600
  catalog_sync_interval_seconds   = 600
  enabled                         = true
}

resource "serviceradar_ansible_repository" "example" {
  idempotency_key       = "cccccccc-dddd-4eee-8fff-aaaaaaaaaaaa"
  name                  = "Example playbooks"
  git_url               = "https://git.example.com/automation/playbooks.git"
  git_ref               = "main"
  sync_interval_seconds = 600
}

output "controller_id" {
  value = serviceradar_ansible_controller.example.id
}

output "repository_sync_status" {
  value = serviceradar_ansible_repository.example.last_sync_status
}
