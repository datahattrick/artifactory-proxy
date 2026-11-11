{{- define "ap.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "ap.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "ap.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ap.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "ap.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "ap.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "ap.tlsSecret" -}}
{{- default (printf "%s-tls" (include "ap.fullname" .)) .Values.tls.secretName }}
{{- end }}

{{/* Identifier safe for nginx variable / upstream names. */}}
{{- define "ap.ident" -}}
{{- include "ap.fullname" . | replace "-" "_" | replace "." "_" }}
{{- end }}

{{/* All mirror hosts, de-duplicated. */}}
{{- define "ap.hosts" -}}
{{- $hosts := list }}
{{- range .Values.mirrors }}{{ range .hosts }}{{ $hosts = append $hosts . }}{{ end }}{{ end }}
{{- toJson ($hosts | uniq) }}
{{- end }}

{{/* Service that routes/ingresses send traffic to. */}}
{{- define "ap.backendName" -}}
{{- if .Values.nginx.enabled }}{{ include "ap.fullname" . }}{{ else }}{{ required "externalService.name is required when nginx.enabled=false" .Values.externalService.name }}{{ end }}
{{- end }}

{{/* Plain-HTTP service port on the backend. */}}
{{- define "ap.backendHttpPort" -}}
{{- if .Values.nginx.enabled }}80{{ else }}{{ .Values.externalService.port }}{{ end }}
{{- end }}

{{- define "ap.validate" -}}
{{- if not .Values.mirrors }}{{ fail "at least one entry in .Values.mirrors is required" }}{{ end }}
{{- $names := dict }}
{{- range .Values.mirrors }}
{{- if not .name }}{{ fail "every mirror needs a name" }}{{ end }}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" .name) }}{{ fail (printf "mirror name %q must be a DNS label" .name) }}{{ end }}
{{- if hasKey $names .name }}{{ fail (printf "duplicate mirror name %q" .name) }}{{ end }}
{{- $_ := set $names .name true }}
{{- if not .hosts }}{{ fail (printf "mirror %q has no hosts" .name) }}{{ end }}
{{- $type := default "docker" .type }}
{{- if not (has $type (list "docker" "generic")) }}{{ fail (printf "mirror %q: type must be docker or generic" .name) }}{{ end }}
{{- if and (eq $type "docker") (not .repository) }}{{ fail (printf "mirror %q: repository is required for type docker" .name) }}{{ end }}
{{- end }}
{{- if .Values.exposure }}{{ fail "exposure.* was replaced in chart 0.2.0: use route.enabled / ingress.enabled and their settings (see values.yaml)" }}{{ end }}
{{- if and .Values.route.enabled .Values.ingress.enabled }}{{ fail "enable only one of route.enabled or ingress.enabled" }}{{ end }}
{{- if .Values.route.enabled }}
{{- $r := .Values.route }}
{{- if not (has $r.termination (list "edge" "reencrypt" "passthrough")) }}{{ fail (printf "route.termination must be edge, reencrypt or passthrough, got %q" $r.termination) }}{{ end }}
{{- if not (has $r.insecureEdgeTerminationPolicy (list "Redirect" "None" "Allow")) }}{{ fail (printf "route.insecureEdgeTerminationPolicy must be Redirect, None or Allow, got %q" $r.insecureEdgeTerminationPolicy) }}{{ end }}
{{- if and (eq $r.termination "passthrough") (eq $r.insecureEdgeTerminationPolicy "Allow") }}{{ fail "route.insecureEdgeTerminationPolicy=Allow is invalid with route.termination=passthrough; use Redirect or None" }}{{ end }}
{{- if ne $r.termination "edge" }}
{{- if not .Values.nginx.enabled }}{{ fail (printf "route.termination=%s needs this chart's nginx (nginx.enabled=true); JFrog nginx mode supports edge only" $r.termination) }}{{ end }}
{{- if not .Values.nginx.tls.enabled }}{{ fail (printf "route.termination=%s requires nginx.tls.enabled=true" $r.termination) }}{{ end }}
{{- end }}
{{- if and $r.destinationCACertificate (ne $r.termination "reencrypt") }}{{ fail "route.destinationCACertificate only applies to route.termination=reencrypt" }}{{ end }}
{{- end }}
{{- if and .Values.tls.certManager.enabled (not .Values.tls.certManager.issuerRef.name) }}
{{- fail "tls.certManager.issuerRef.name is required (or set tls.certManager.enabled=false and provide tls.secretName)" }}
{{- end }}
{{- end }}
