# artifactory-proxy

Helm chart that serves upstream registry hostnames such as `docker.io` from JFrog Artifactory repositories.
Point `docker.io` at it in internal DNS and `docker pull nginx` is served by `artifactory.local`, repository `docker.io`.

```
client ── docker.io ──▶ Route / Ingress ──▶ nginx (unprivileged) ──▶ Artifactory /artifactory/api/docker/docker.io/v2/
```

- **Docker mirrors**: `/v2/` is mapped to an Artifactory Docker repository, with the token realm and redirects rewritten to the virtual host.
- **Generic mirrors**: every path is prefixed, e.g. `pypi.org` to `/artifactory/api/pypi/pypi-remote`.
- **Exposure**: OpenShift Routes (edge, passthrough or reencrypt) or a Kubernetes Ingress, one rule per host.
- **Certificates**: one cert-manager `Certificate` covering every mirror host.
- **Unprivileged nginx**: `nginx-unprivileged`, read-only root filesystem, no fixed UID, runs under OpenShift `restricted-v2`.
- **JFrog nginx mode**: loads the same server blocks into the JFrog chart's bundled nginx with no extra Deployment. See [JFrog nginx mode](#jfrog-nginx-mode).

## Requirements

1. An Artifactory repository per mirror, keyed as in `mirrors[].repository` (e.g. a Docker remote repo `docker.io` pointing at `https://registry-1.docker.io/`).
2. For anonymous pulls: anonymous access enabled, and a permission giving `anonymous` **Read** and **Deploy/Cache** on **ANY REMOTE** (or the named remotes).
   Without it, pulls fail with `Download request for repo:path 'docker.io-cache:...' is forbidden for user: 'anonymous'`.
   The default `ANY` target covers local repositories only.
3. A cert-manager issuer whose CA your clients trust, or an existing TLS secret in `tls.secretName`.
4. On OpenShift: 4.16+ for `externalCertificate` on edge Routes, and `create` on `routes/custom-host` for the installing user.

## Install

```bash
helm install mirror charts/artifactory-proxy -n artifactory-proxy --create-namespace \
  --set artifactory.url=http://artifactory.artifactory.svc:8082 \
  --set tls.certManager.issuerRef.name=my-ca \
  --set route.enabled=true
```

Then point every mirror host at the router or ingress controller in internal DNS, and make clients trust the issuing CA.

What bites:

- Docker, containerd and Podman fetch `docker.io` images from `registry-1.docker.io`. Both names need DNS records; the default `dockerhub` mirror lists both, plus `index.docker.io`.
- Once nodes resolve `docker.io` to the proxy, the proxy's own image pull goes through itself. Pull `nginx.image.repository` from another registry, or pre-cache it, before switching DNS.
- The token realm uses `X-Forwarded-Proto`. If TLS ends somewhere that does not set it, clients are sent to `http://<host>/v2/token`.

## Mirrors

```yaml
artifactory:
  url: https://artifactory.local       # Router, JFrog nginx, or external URL
mirrors:
  - name: dockerhub
    type: docker
    repository: docker.io              # Artifactory repository key
    hosts: [docker.io, registry-1.docker.io, index.docker.io]
  - name: quay
    type: docker
    repository: quay.io
    hosts: [quay.io]
  - name: pypi
    type: generic
    pathPrefix: /artifactory/api/pypi/pypi-remote
    hosts: [pypi.org]
```

`extraConfig` on a mirror is appended inside its `server` block.
Unknown hosts get `404 unknown host` from the standalone nginx.
All options are in [values.yaml](charts/artifactory-proxy/values.yaml).

## Exposure

Enable one of `route` or `ingress`.
With neither, the chart creates only the Service.

OpenShift Routes, one per host:

```yaml
route:
  enabled: true
  termination: edge                  # edge | reencrypt | passthrough
  insecureEdgeTerminationPolicy: Redirect
  externalCertificate: true          # false = router's default certificate
```

Kubernetes Ingress, one rule per host:

```yaml
ingress:
  enabled: true
  className: traefik
  tls: true                          # false = controller provides the certificate
```

| Setting | TLS ends at | Needs |
|---|---|---|
| `route.termination: edge` | Router | OpenShift 4.16+ when `externalCertificate: true` |
| `route.termination: reencrypt` | Router, then nginx | `nginx.tls.enabled=true`, `route.destinationCACertificate` |
| `route.termination: passthrough` | nginx | `nginx.tls.enabled=true` |
| `ingress.enabled: true` | Ingress controller | |

`externalCertificate: true` also creates a Role and RoleBinding letting `route.routerServiceAccount` read the TLS secret.
Invalid combinations fail at install, e.g. `route.termination=passthrough requires nginx.tls.enabled=true`.

## JFrog nginx mode

Set `nginx.enabled=false`, install into the JFrog release's namespace, and add three settings to the JFrog chart's `nginx` values.
[examples/jfrog-nginx-mode.yaml](examples/jfrog-nginx-mode.yaml) is the chart side, [examples/jfrog-nginx-mode.artifactory-values.yaml](examples/jfrog-nginx-mode.artifactory-values.yaml) the JFrog side.

```bash
helm install mirrors charts/artifactory-proxy -n artifactory -f examples/jfrog-nginx-mode.yaml
helm upgrade jcr jfrog/artifactory-jcr -n artifactory -f my-values.yaml -f jfrog-side.yaml
```

JFrog's nginx does not reload when mirrors change.
Bump `nginx.annotations.artifactory-mirrors/revision`, or `kubectl rollout restart deploy/<release>-artifactory-nginx`.

## Checking it works

```bash
curl -si https://registry-1.docker.io/v2/ | grep -i www-authenticate   # realm="https://registry-1.docker.io/v2/token"
skopeo inspect docker://docker.io/library/alpine:3.20                  # Pulled via Artifactory
kubectl logs -n artifactory-proxy -l app.kubernetes.io/instance=mirror # Access log with host per request
```

A realm naming the Artifactory host means the response bypassed the proxy.

## Future

- Push through the virtual host
- Per-mirror Artifactory upstreams
- NetworkPolicy and HPA templates
- CoreDNS snippet for in-cluster resolution

## Files

| Path | Contents |
|---|---|
| [charts/artifactory-proxy](charts/artifactory-proxy) | The chart |
| [examples/](examples) | JFrog nginx mode values for both charts |
| [test/](test) | Values used for the k3s test: JCR backend and Traefik ingress |
