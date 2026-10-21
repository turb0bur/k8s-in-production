{{- define "rbac.studentNames" -}}
{{- range $i := untilStep 1 (int (add1 (int .Values.studentCount))) 1 }}
{{ printf "%s%02d" $.Values.studentPrefix $i }}
{{- end }}
{{- end }}

{{- define "rbac.rolebinding" -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ .user }}-{{ .role }}
  namespace: {{ .namespace }}
subjects:
  - kind: User
    name: {{ .user }}
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: {{ .role }}
  apiGroup: rbac.authorization.k8s.io
{{- end }}
