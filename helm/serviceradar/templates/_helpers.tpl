{{- define "serviceradar.fullname" -}}
{{- printf "serviceradar" -}}
{{- end -}}

{{- define "serviceradar.imagePullSecrets" -}}
{{- if .Values.image.registryPullSecret }}
imagePullSecrets:
  - name: {{ .Values.image.registryPullSecret | quote }}
{{- end }}
{{- end -}}
