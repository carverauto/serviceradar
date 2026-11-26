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

{{- /* The playback read listener (D5): its own port, pin and read-purpose token,
web-ng as its only client. Distinct from every ingest input so a playback
credential can neither record nor archive. */ -}}
{{- define "serviceradar.validateNvrRead" -}}
{{- $nvr := default (dict) .Values.nvr -}}
{{- $read := default (dict) $nvr.read -}}
{{- if and $nvr.enabled $read.enabled -}}
{{- $ingest := default (dict) $nvr.ingest -}}
{{- $ingestClient := default (dict) $ingest.client -}}
{{- $port := int (default 8444 $read.port) -}}
{{- if or (lt $port 1) (gt $port 65535) (eq $port 8095) (and $ingest.enabled (eq $port (int (default 8443 $ingest.port)))) -}}
{{- fail "nvr.read.port must be in 1..65535 and distinct from the health (8095) and ingest ports" -}}
{{- end -}}
{{- $slots := int (default 8 $read.playbackReadSlots) -}}
{{- if or (lt $slots 1) (gt $slots 64) -}}
{{- fail "nvr.read.playbackReadSlots must be from 1 through 64" -}}
{{- end -}}
{{- $_ := required "nvr.read.configSecretName is required when nvr.read.enabled" $read.configSecretName -}}
{{- $token := required "nvr.read.tokenSecretName is required when nvr.read.enabled" $read.tokenSecretName -}}
{{- $serverTLS := required "nvr.read.tlsSecretName is required when nvr.read.enabled" $read.tlsSecretName -}}
{{- $client := default (dict) $read.client -}}
{{- $_ := required "nvr.read.client.configSecretName is required when nvr.read.enabled" $client.configSecretName -}}
{{- $clientToken := required "nvr.read.client.tokenSecretName is required when nvr.read.enabled" $client.tokenSecretName -}}
{{- $clientTLS := required "nvr.read.client.tlsSecretName is required when nvr.read.enabled" $client.tlsSecretName -}}
{{- if eq $serverTLS $clientTLS -}}
{{- fail "nvr.read server and client TLS Secrets must be distinct" -}}
{{- end -}}
{{- $ingestTokens := list $ingest.tokenSecretName $ingestClient.tokenSecretName -}}
{{- if or (has $token $ingestTokens) (has $clientToken $ingestTokens) -}}
{{- fail "nvr.read must use a read token Secret distinct from the ingest token" -}}
{{- end -}}
{{- if has $clientTLS (list $ingest.tlsSecretName $ingestClient.tlsSecretName) -}}
{{- fail "nvr.read.client.tlsSecretName must be distinct from the ingest TLS Secrets" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- /* The dedicated analysis-read listener for the Vantage addon's media worker: its
own port (default 8445), client certificate pin, bearer token, and read pool,
completely isolated from both core ingest (8443) and web-ng playback (8444). */ -}}
{{- define "serviceradar.validateNvrAnalysisRead" -}}
{{- $nvr := default (dict) .Values.nvr -}}
{{- $analysis := default (dict) $nvr.analysisRead -}}
{{- if and $nvr.enabled $analysis.enabled -}}
{{- $ingest := default (dict) $nvr.ingest -}}
{{- $ingestClient := default (dict) $ingest.client -}}
{{- $read := default (dict) $nvr.read -}}
{{- $readClient := default (dict) $read.client -}}
{{- $port := int (default 8445 $analysis.port) -}}
{{- if or (lt $port 1) (gt $port 65535) (eq $port 8095) (and $ingest.enabled (eq $port (int (default 8443 $ingest.port)))) (and $read.enabled (eq $port (int (default 8444 $read.port)))) -}}
{{- fail "nvr.analysisRead.port must be in 1..65535 and distinct from the health (8095), ingest, and playback read ports" -}}
{{- end -}}
{{- $slots := int (default 4 $analysis.analysisReadSlots) -}}
{{- if or (lt $slots 1) (gt $slots 64) -}}
{{- fail "nvr.analysisRead.analysisReadSlots must be from 1 through 64" -}}
{{- end -}}
{{- $_ := required "nvr.analysisRead.configSecretName is required when nvr.analysisRead.enabled" $analysis.configSecretName -}}
{{- $token := required "nvr.analysisRead.tokenSecretName is required when nvr.analysisRead.enabled" $analysis.tokenSecretName -}}
{{- $serverTLS := required "nvr.analysisRead.tlsSecretName is required when nvr.analysisRead.enabled" $analysis.tlsSecretName -}}
{{- $client := default (dict) $analysis.client -}}
{{- $clientToken := required "nvr.analysisRead.client.tokenSecretName is required when nvr.analysisRead.enabled" $client.tokenSecretName -}}
{{- $clientTLS := required "nvr.analysisRead.client.tlsSecretName is required when nvr.analysisRead.enabled" $client.tlsSecretName -}}
{{- if eq $serverTLS $clientTLS -}}
{{- fail "nvr.analysisRead server and client TLS Secrets must be distinct" -}}
{{- end -}}
{{- $otherTokens := list $ingest.tokenSecretName $ingestClient.tokenSecretName $read.tokenSecretName $readClient.tokenSecretName -}}
{{- if or (has $token $otherTokens) (has $clientToken $otherTokens) -}}
{{- fail "nvr.analysisRead must use an analysis-read token Secret distinct from the ingest and playback read tokens" -}}
{{- end -}}
{{- $otherTLS := list $ingest.tlsSecretName $ingestClient.tlsSecretName $read.tlsSecretName $readClient.tlsSecretName -}}
{{- if has $clientTLS $otherTLS -}}
{{- fail "nvr.analysisRead.client.tlsSecretName must be distinct from the ingest and playback read TLS Secrets" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "serviceradar.nvrReadClientEnv" -}}
{{- $nvr := default (dict) .Values.nvr -}}
{{- $read := default (dict) $nvr.read -}}
{{- if and $nvr.enabled $read.enabled }}
- name: SERVICERADAR_NVR_READ_CLIENT_CONFIG_FILE
  value: /etc/serviceradar/nvr-read-client/config/config.json
- name: SERVICERADAR_NVR_READ_CLIENT_TOKEN_FILE
  value: /etc/serviceradar/nvr-read-client/auth/read-token
{{- end }}
{{- end }}

{{- define "serviceradar.nvrReadClientMounts" -}}
{{- $nvr := default (dict) .Values.nvr -}}
{{- $read := default (dict) $nvr.read -}}
{{- if and $nvr.enabled $read.enabled }}
- name: nvr-read-client-config
  mountPath: /etc/serviceradar/nvr-read-client/config
  readOnly: true
- name: nvr-read-client-auth
  mountPath: /etc/serviceradar/nvr-read-client/auth
  readOnly: true
- name: nvr-read-client-tls
  mountPath: /etc/serviceradar/nvr-read-client/tls
  readOnly: true
{{- end }}
{{- end }}

{{- define "serviceradar.nvrReadClientVolumes" -}}
{{- $nvr := default (dict) .Values.nvr -}}
{{- $read := default (dict) $nvr.read -}}
{{- if and $nvr.enabled $read.enabled }}
{{- $client := default (dict) $read.client }}
- name: nvr-read-client-config
  secret:
    secretName: {{ $client.configSecretName | quote }}
    defaultMode: 0440
    items:
      - {key: config.json, path: config.json}
- name: nvr-read-client-auth
  secret:
    secretName: {{ $client.tokenSecretName | quote }}
    defaultMode: 0440
    items:
      - {key: read-token, path: read-token}
- name: nvr-read-client-tls
  secret:
    secretName: {{ $client.tlsSecretName | quote }}
    defaultMode: 0440
    items:
      - {key: tls.crt, path: tls.crt}
      - {key: tls.key, path: tls.key}
      - {key: ca.crt, path: ca.crt}
{{- end }}
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
