{{/* Names and labels ------------------------------------------------------- */}}

{{- define "libarrie.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "libarrie.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "libarrie.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "libarrie.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "libarrie.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "libarrie.secretName" -}}
{{- default (printf "%s-secrets" (include "libarrie.fullname" .)) .Values.secrets.existingSecret -}}
{{- end -}}

{{- define "libarrie.apiImage" -}}
{{- printf "%s:%s" .Values.image.api.repository (default .Chart.AppVersion .Values.image.api.tag) -}}
{{- end -}}

{{- define "libarrie.workerImage" -}}
{{- printf "%s:%s" .Values.image.worker.repository (default .Chart.AppVersion .Values.image.worker.tag) -}}
{{- end -}}

{{- define "libarrie.host" -}}
{{- default (regexReplaceAll "^https://([^/:]+).*$" .Values.origin "${1}") .Values.ingress.host -}}
{{- end -}}

{{/* Validation: every production setting, with a message naming what's missing. */}}
{{- define "libarrie.validate" -}}
{{- $v := .Values -}}
{{- $origin := required "origin is required: the app's public HTTPS origin, such as https://notes.example.com" $v.origin -}}
{{- if not (regexMatch "^https://[^/]+$" $origin) -}}
{{- fail "origin must be an https:// origin with no path or trailing slash, such as https://notes.example.com" -}}
{{- end -}}
{{- if not (has $v.mode (list "selfhost" "hosted")) -}}
{{- fail "mode must be selfhost or hosted" -}}
{{- end -}}
{{- $_ := required "oidc.issuer is required: your identity provider's issuer" $v.oidc.issuer -}}
{{- $_ := required "oidc.jwksUrl is required: your identity provider's JWKS URL" $v.oidc.jwksUrl -}}
{{- $_ := required "oidc.clientId is required: the web client's ID" $v.oidc.clientId -}}
{{- $_ := required "storage.endpoint is required: the S3 API endpoint" $v.storage.endpoint -}}
{{- $_ := required "storage.publicEndpoint is required: the S3 endpoint browsers and apps use" $v.storage.publicEndpoint -}}
{{- $_ := required "storage.bucket is required" $v.storage.bucket -}}
{{- if not $v.secrets.existingSecret -}}
{{- $_ := required "secrets.databaseUrl is required (or set secrets.existingSecret)" $v.secrets.databaseUrl -}}
{{- $key := required "secrets.secretKeyBase is required (or set secrets.existingSecret)" $v.secrets.secretKeyBase -}}
{{- if lt (len $key) 64 -}}
{{- fail "secrets.secretKeyBase must be at least 64 characters" -}}
{{- end -}}
{{- $_ := required "secrets.identityHashKeys is required, such as k1:<random> (or set secrets.existingSecret)" $v.secrets.identityHashKeys -}}
{{- $_ := required "secrets.s3AccessKeyId is required (or set secrets.existingSecret)" $v.secrets.s3AccessKeyId -}}
{{- $_ := required "secrets.s3SecretAccessKey is required (or set secrets.existingSecret)" $v.secrets.s3SecretAccessKey -}}
{{- $_ := required "secrets.mistralApiKey is required (or set secrets.existingSecret)" $v.secrets.mistralApiKey -}}
{{- $_ := required "secrets.voyageApiKey is required (or set secrets.existingSecret)" $v.secrets.voyageApiKey -}}
{{- end -}}
{{- range $name, $_ := merge (dict) $v.config $v.secrets.extra -}}
{{- if eq $name "DEV_ISSUER_SECRET" -}}
{{- fail "DEV_ISSUER_SECRET enables the development sign-in, which lets anyone sign in as anyone; it is never allowed in this chart" -}}
{{- end -}}
{{- end -}}
{{- if and $v.worker.autoscaling.enabled (not (.Capabilities.APIVersions.Has "keda.sh/v1alpha1/ScaledObject")) -}}
{{- fail "worker.autoscaling needs KEDA (https://keda.sh) installed in the cluster" -}}
{{- end -}}
{{- end -}}

{{/* Configuration ----------------------------------------------------------- */}}

{{/* A value as an environment variable. Helm reads YAML numbers as floats,
so whole numbers are written without an exponent (5000000, not 5e+06). */}}
{{- define "libarrie.scalar" -}}
{{- if and (kindIs "float64" .) (eq (float64 (int64 .)) .) -}}
{{- int64 . -}}
{{- else -}}
{{- toString . -}}
{{- end -}}
{{- end -}}

{{/* Non-secret settings, by environment-variable name; empty ones are left out. */}}
{{- define "libarrie.configData" -}}
{{- $v := .Values -}}
{{- $c := dict
  "LIBARRIE_MODE" $v.mode
  "PORT" "8080"
  "INTERNAL_PORT" $v.internalApi.port
  "WEB_ORIGIN" $v.origin
  "LIBARRIE_OWNER" $v.owner
  "OIDC_ISSUER" $v.oidc.issuer
  "OIDC_JWKS_URL" $v.oidc.jwksUrl
  "OIDC_CLIENT_ID" $v.oidc.clientId
  "OIDC_AUDIENCE" $v.oidc.audience
  "OIDC_NATIVE_CLIENT_ID" $v.oidc.nativeClientId
  "OIDC_NATIVE_REDIRECT_URI" $v.oidc.nativeRedirectUri
  "OIDC_AUTHORIZATION_ENDPOINT" $v.oidc.authorizationEndpoint
  "OIDC_TOKEN_ENDPOINT" $v.oidc.tokenEndpoint
  "MCP_OAUTH_AUDIENCE" $v.mcp.oauthAudience
  "MCP_OAUTH_SCOPES" $v.mcp.oauthScopes
  "S3_ENDPOINT" $v.storage.endpoint
  "S3_PUBLIC_ENDPOINT" $v.storage.publicEndpoint
  "S3_REGION" $v.storage.region
  "S3_BUCKET" $v.storage.bucket
  "S3_UPLOAD_INTEGRITY" $v.storage.uploadIntegrity
  "JOURNAL_S3_ENDPOINT" $v.journal.endpoint
  "JOURNAL_S3_REGION" $v.journal.region
  "JOURNAL_S3_BUCKET" $v.journal.bucket
  "OCR_PROVIDER" "mistral"
  "MISTRAL_OCR_MODEL" $v.providers.mistral.model
  "MISTRAL_TERMS_RECORD" $v.providers.mistral.termsRecord
  "EMBEDDING_PROVIDER" "voyage"
  "VOYAGE_MODEL" $v.providers.voyage.model
  "VOYAGE_TERMS_RECORD" $v.providers.voyage.termsRecord
  "SPEND_ACCOUNT_DAILY_MICROS" $v.spend.accountDailyMicros
  "SPEND_DEPLOYMENT_DAILY_MICROS" $v.spend.deploymentDailyMicros
  "DEFAULT_STORED_PAGES" $v.limits.storedPages
  "DEFAULT_NOTEBOOKS" $v.limits.notebooks
  "DEFAULT_LIFETIME_PROCESSING" $v.limits.lifetimeProcessing
  "DECODER_SANDBOX" $v.decoder.sandbox
  "LIFECYCLE_SUBSCRIBER_URL" $v.lifecycleSubscriber.url
-}}
{{- range $name, $value := merge (dict) $v.config $c }}
{{- $text := include "libarrie.scalar" $value }}
{{- if ne $text "" }}
{{ $name }}: {{ $text | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/* Secret settings, base64-encoded; empty ones are left out. */}}
{{- define "libarrie.secretData" -}}
{{- $s := .Values.secrets -}}
{{- $d := dict
  "DATABASE_URL" $s.databaseUrl
  "SECRET_KEY_BASE" $s.secretKeyBase
  "IDENTITY_HASH_KEYS" $s.identityHashKeys
  "S3_ACCESS_KEY_ID" $s.s3AccessKeyId
  "S3_SECRET_ACCESS_KEY" $s.s3SecretAccessKey
  "MISTRAL_API_KEY" $s.mistralApiKey
  "VOYAGE_API_KEY" $s.voyageApiKey
  "OIDC_CLIENT_SECRET" $s.oidcClientSecret
  "JOURNAL_S3_ACCESS_KEY_ID" $s.journalS3AccessKeyId
  "JOURNAL_S3_SECRET_ACCESS_KEY" $s.journalS3SecretAccessKey
  "INTERNAL_API_TOKEN" $s.internalApiToken
  "LIFECYCLE_SUBSCRIBER_TOKEN" $s.lifecycleSubscriberToken
-}}
{{- range $name, $value := merge (dict) $s.extra $d }}
{{- $text := include "libarrie.scalar" $value }}
{{- if ne $text "" }}
{{ $name }}: {{ $text | b64enc | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/* Pods ---------------------------------------------------------------------- */}}

{{/* Restart pods when their configuration changes. */}}
{{- define "libarrie.configChecksum" -}}
checksum/config: {{ include "libarrie.configData" . | sha256sum }}
{{- if not .Values.secrets.existingSecret }}
checksum/secrets: {{ include "libarrie.secretData" . | sha256sum }}
{{- end }}
{{- end -}}

{{- define "libarrie.envFrom" -}}
envFrom:
  - configMapRef:
      name: {{ include "libarrie.fullname" . }}-config
  - secretRef:
      name: {{ include "libarrie.secretName" . }}
{{- end -}}

{{/* The parts of a pod spec every Libarrie pod shares. */}}
{{- define "libarrie.podCommon" -}}
serviceAccountName: {{ include "libarrie.serviceAccountName" . }}
automountServiceAccountToken: false
securityContext:
  {{- toYaml .Values.podSecurityContext | nindent 2 }}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}
