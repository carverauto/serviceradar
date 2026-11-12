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
