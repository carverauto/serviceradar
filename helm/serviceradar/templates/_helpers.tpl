{{- define "serviceradar.fullname" -}}
{{- printf "serviceradar" -}}
{{- end -}}

{{- define "serviceradar.imagePullSecrets" -}}
{{- if .Values.image.registryPullSecret }}
imagePullSecrets:
  - name: {{ .Values.image.registryPullSecret | quote }}
{{- end }}
{{- end -}}

{{- define "serviceradar.configSyncEnv" -}}
{{- $cfg := merge (dict "enabled" true "seed" true "watch" false "kvKey" "" "role" "" "extraArgs" "" "extraEnv" (dict)) (default (dict) .cfg) -}}
- name: CONFIG_SYNC_ENABLED
  value: "{{ ternary "true" "false" $cfg.enabled }}"
- name: CONFIG_SYNC_SEED
  value: "{{ ternary "true" "false" $cfg.seed }}"
- name: CONFIG_SYNC_WATCH
  value: "{{ ternary "true" "false" $cfg.watch }}"
{{- if $cfg.kvKey }}
- name: CONFIG_KV_KEY
  value: {{ $cfg.kvKey | quote }}
{{- end }}
{{- if $cfg.role }}
- name: CONFIG_SYNC_ROLE
  value: {{ $cfg.role | quote }}
{{- end }}
{{- if $cfg.extraArgs }}
- name: CONFIG_SYNC_EXTRA_ARGS
  value: {{ $cfg.extraArgs | quote }}
{{- end }}
{{- if $cfg.extraEnv }}
{{- range $name, $value := $cfg.extraEnv }}
- name: {{ $name }}
  value: {{ $value | quote }}
{{- end }}
{{- end }}
{{- end -}}
