{{/* The operator owns this state outside application rollback and media backups. */}}
{{- define "serviceradar.nvrRecoveryEnv" -}}
{{- if .Values.nvr.enabled }}
- name: SERVICERADAR_NVR_RECOVERY_GENERATION
  valueFrom:
    configMapKeyRef:
      name: {{ .Values.nvr.recovery.existingConfigMap | quote }}
      key: generation
- name: SERVICERADAR_NVR_RECOVERY_STATE_FILE
  value: /etc/serviceradar/nvr-recovery/state.json
{{- end }}
{{- end }}

{{- define "serviceradar.nvrRecoveryMount" -}}
{{- if .Values.nvr.enabled }}
- name: recovery
  mountPath: /etc/serviceradar/nvr-recovery
  readOnly: true
{{- end }}
{{- end }}

{{- define "serviceradar.nvrRecoveryVolume" -}}
{{- if .Values.nvr.enabled }}
- name: recovery
  configMap:
    name: {{ .Values.nvr.recovery.existingConfigMap | quote }}
    optional: false
{{- end }}
{{- end }}

{{- define "serviceradar.validateNvrIngest" -}}
{{- $nvr := default (dict) .Values.nvr -}}
{{- $ingest := default (dict) $nvr.ingest -}}
{{- if and $nvr.enabled $ingest.enabled -}}
{{- $port := int (default 8443 $ingest.port) -}}
{{- if or (lt $port 1) (gt $port 65535) (eq $port 8095) -}}
{{- fail "nvr.ingest.port must be in 1..65535 and distinct from the health port (8095)" -}}
{{- end -}}
{{- $_ := required "nvr.ingest.configSecretName is required when nvr.ingest.enabled" $ingest.configSecretName -}}
{{- $_ := required "nvr.ingest.tokenSecretName is required when nvr.ingest.enabled" $ingest.tokenSecretName -}}
{{- $serverTLS := required "nvr.ingest.tlsSecretName is required when nvr.ingest.enabled" $ingest.tlsSecretName -}}
{{- $client := default (dict) $ingest.client -}}
{{- $_ := required "nvr.ingest.client.configSecretName is required when nvr.ingest.enabled" $client.configSecretName -}}
{{- $_ := required "nvr.ingest.client.tokenSecretName is required when nvr.ingest.enabled" $client.tokenSecretName -}}
{{- $clientTLS := required "nvr.ingest.client.tlsSecretName is required when nvr.ingest.enabled" $client.tlsSecretName -}}
{{- if eq $serverTLS $clientTLS -}}
{{- fail "nvr.ingest server and client TLS Secrets must be distinct" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "serviceradar.nvrClientEnv" -}}
{{- $nvr := default (dict) .Values.nvr -}}
{{- $ingest := default (dict) $nvr.ingest -}}
{{- if and $nvr.enabled $ingest.enabled }}
{{- $client := default (dict) $ingest.client }}
- name: SERVICERADAR_NVR_CLIENT_CONFIG_FILE
  value: /etc/serviceradar/nvr-client/config/config.json
- name: SERVICERADAR_NVR_CLIENT_TOKEN_FILE
  value: /etc/serviceradar/nvr-client/auth/ingest-token
{{- if $client.cameraRecordingEnabled }}
- name: SERVICERADAR_CAMERA_RECORDING_ENABLED
  value: "true"
{{- end }}
{{- end }}
{{- end }}

{{- define "serviceradar.nvrClientMounts" -}}
{{- $nvr := default (dict) .Values.nvr -}}
{{- $ingest := default (dict) $nvr.ingest -}}
{{- if and $nvr.enabled $ingest.enabled }}
- name: nvr-client-config
  mountPath: /etc/serviceradar/nvr-client/config
  readOnly: true
- name: nvr-client-auth
  mountPath: /etc/serviceradar/nvr-client/auth
  readOnly: true
- name: nvr-client-tls
  mountPath: /etc/serviceradar/nvr-client/tls
  readOnly: true
{{- end }}
{{- end }}

{{- define "serviceradar.nvrClientVolumes" -}}
{{- $nvr := default (dict) .Values.nvr -}}
{{- $ingest := default (dict) $nvr.ingest -}}
{{- if and $nvr.enabled $ingest.enabled }}
{{- $client := default (dict) $ingest.client }}
- name: nvr-client-config
  secret:
    secretName: {{ $client.configSecretName | quote }}
    defaultMode: 0440
    items:
      - {key: config.json, path: config.json}
- name: nvr-client-auth
  secret:
    secretName: {{ $client.tokenSecretName | quote }}
    defaultMode: 0440
    items:
      - {key: ingest-token, path: ingest-token}
- name: nvr-client-tls
  secret:
    secretName: {{ $client.tlsSecretName | quote }}
    defaultMode: 0440
    items:
      - {key: tls.crt, path: tls.crt}
      - {key: tls.key, path: tls.key}
      - {key: ca.crt, path: ca.crt}
{{- end }}
{{- end }}
