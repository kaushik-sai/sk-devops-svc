# sk-svc image: PowerShell 7 + Pode on a small, patched Alpine base.
#
# Why not mcr.microsoft.com/powershell? That repository stopped at 7.5 on Alpine 3.20.
# Microsoft's .NET "runtime-deps" image is kept patched, is small, and already has a
# non-root user. PowerShell's own self-contained tarball runs on top of it.

ARG BASE_IMAGE=mcr.microsoft.com/dotnet/runtime-deps:10.0.9-alpine3.24

# ---- Stage 1: download PowerShell and the Pode module ----
FROM ${BASE_IMAGE} AS build

ARG PWSH_VERSION=7.6.7
# SHA-256 from the release's hashes.sha256 file. The build fails if the download does not match.
ARG PWSH_SHA256=d74a1b7e1d1fbf150ae6f29e083953ce07fc833fe9d66218d54940a8638249c6
ARG PODE_VERSION=2.14.1

# curl is only needed here; it does not reach the final image.
RUN apk add --no-cache curl \
    && curl -fsSL -o /tmp/pwsh.tar.gz \
       "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-musl-x64.tar.gz" \
    && echo "${PWSH_SHA256}  /tmp/pwsh.tar.gz" | sha256sum -c - \
    && mkdir -p /opt/microsoft/powershell \
    && tar -xzf /tmp/pwsh.tar.gz -C /opt/microsoft/powershell \
    && chmod +x /opt/microsoft/powershell/pwsh \
    && rm /tmp/pwsh.tar.gz

# Pinned Pode version, saved into the all-users module folder that pwsh searches by default.
# Save-PSResource (PSResourceGet) ships with pwsh 7.4+; the older Save-Module does not load on this base.
RUN mkdir -p /usr/local/share/powershell/Modules \
    && /opt/microsoft/powershell/pwsh -NoLogo -NoProfile -Command \
    "Save-PSResource -Name Pode -Version ${PODE_VERSION} -Path /usr/local/share/powershell/Modules -Repository PSGallery -TrustRepository -ErrorAction Stop" \
    # Pode ships one library folder per .NET version and loads the one matching the runtime.
    # pwsh 7.6 runs on .NET 10, so only Libs/net10.0 is ever used. The others are dead weight,
    # and the netstandard2.0 one carries an old System.Security.Cryptography.Pkcs that Trivy flags.
    && find /usr/local/share/powershell/Modules/Pode/${PODE_VERSION}/Libs -mindepth 1 -maxdepth 1 -type d ! -name net10.0 -exec rm -rf {} +

# ---- Stage 2: runtime ----
FROM ${BASE_IMAGE}

# The commit SHA this image was built from. Becomes an env var (read by /version) and a label.
# DB_PASSWORD_FILE is set by the runtime (Compose or Container Apps), not baked into the image.
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.title="sk-svc" \
      org.opencontainers.image.revision="${GIT_SHA}"

ENV GIT_SHA=${GIT_SHA} \
    PORT=8080 \
    FAIL_RATE=0 \
    POWERSHELL_TELEMETRY_OPTOUT=1 \
    NO_COLOR=1 \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false

# apk upgrade: pick up Alpine security fixes released after the base image was built.
# icu-libs: Pode loads culture-specific message files, which needs ICU. The base image runs .NET
# in "invariant globalization" mode without ICU, so we add it and switch that mode off (above).
RUN apk upgrade --no-cache \
    && apk add --no-cache icu-libs

COPY --from=build /opt/microsoft/powershell /opt/microsoft/powershell
COPY --from=build /usr/local/share/powershell/Modules /usr/local/share/powershell/Modules
# Owned by root and read-only for the app user: the service cannot change its own code.
COPY app/ /app/

# APP_UID (1654) is the non-root "app" user that the .NET base image provides.
USER $APP_UID

EXPOSE 8080

# busybox wget is already in Alpine, so the health check needs no extra package.
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["/opt/microsoft/powershell/pwsh", "-NoLogo", "-NoProfile", "-File", "/app/server.ps1"]
