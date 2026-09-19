# syntax=docker/dockerfile:1

# Dev image: agent-box + a JVM/Python toolchain for agent-assisted builds.
# SDKMAN was considered and rejected: it is per-user (writes to $HOME, which
# the base entrypoint may re-own), depends on a live version catalog (not
# reproducible), and its runtime version-switching has no container use case.
# Instead, toolchains are pinned, checksum-verified tarballs installed
# system-wide — same philosophy as the base image.

# Bump to match the base image tag you built/pulled.
ARG BASE_IMAGE=agent-box:latest
FROM ${BASE_IMAGE}

# The base image's runtime user is named after its agent (`opencode` in
# opencode/opencode.Dockerfile, `omp` in omp/omp.Dockerfile), and Docker resolves
# `USER <name>` against the image's /etc/passwd at container start — a name the
# base image does not define yields an image that builds but cannot run. There
# is no safe default: it must match whichever BASE_IMAGE was actually passed,
# so BASE_USER is mandatory (enforced below) and must always be supplied
# alongside BASE_IMAGE, e.g.
#   --build-arg BASE_IMAGE=agent-box-opencode:<x.y.z> --build-arg BASE_USER=opencode
#   --build-arg BASE_IMAGE=agent-box-omp:<x.y.z> --build-arg BASE_USER=omp
# (both variants use uid 10001 and HOME=/home/agent-box, so nothing else in
# this file is base-variant specific).
ARG BASE_USER
RUN if [ -z "${BASE_USER}" ]; then \
      echo "BASE_USER build-arg is required (e.g. --build-arg BASE_USER=opencode or omp)" >&2; \
      exit 1; \
    fi

USER root

# Local-only escape hatch for TLS-intercepting corporate proxies, identical to
# the base image: appends a caller-supplied CA bundle before any network call.
# Never written to an image layer; builds without --secret are unaffected.
RUN --mount=type=secret,id=external_ca,required=false \
    if [ -s /run/secrets/external_ca ]; then \
      cat /run/secrets/external_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi

# --- Python 3.13 (native Wolfi package) ---
ARG PYTHON_VERSION=3.13
RUN apk add --no-cache \
    python-${PYTHON_VERSION} \
    py${PYTHON_VERSION}-pip

# --- Java 25 (GraalVM Community Edition, checksum-verified) ---
# GraalVM CE is not in Wolfi. Oracle publishes tarballs via GitHub releases:
# github.com/graalvm/graalvm-ce-builds/releases. Each release asset ships a
# sibling *.sha256 file; verify against the value captured when bumping:
# curl -fsSL https://github.com/graalvm/graalvm-ce-builds/releases/download/jdk-25.0.2/graalvm-community-jdk-25.0.2_linux-x64_bin.tar.gz.sha256
ARG GRAALVM_VERSION=25.0.2
ARG GRAALVM_SHA256_AMD64=e0be791c8fda4d03b6b0a0cb824fef3149736170057b3a515252b44419606af0
ARG GRAALVM_SHA256_ARM64=b4580d9f223d0a4b3a1757e58b18ff4c1db950e67e105fc5cb741457d2384a71
RUN arch="$(uname -m)" && \
    case "$arch" in \
      x86_64)  jdk_arch=x64; sha="$GRAALVM_SHA256_AMD64" ;; \
      aarch64) jdk_arch=aarch64; sha="$GRAALVM_SHA256_ARM64" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac && \
    if [ -z "$sha" ]; then echo "no GraalVM SHA256 pinned for $arch; set GRAALVM_SHA256_* for your arch" >&2; exit 1; fi && \
    curl -fsSL -o /tmp/graalvm.tar.gz \
      "https://github.com/graalvm/graalvm-ce-builds/releases/download/jdk-${GRAALVM_VERSION}/graalvm-community-jdk-${GRAALVM_VERSION}_linux-${jdk_arch}_bin.tar.gz" && \
    echo "${sha}  /tmp/graalvm.tar.gz" | sha256sum -c - && \
    mkdir -p /usr/lib/jvm/graalvm-25 && \
    tar -xzf /tmp/graalvm.tar.gz -C /usr/lib/jvm/graalvm-25 --strip-components=1 && \
    rm /tmp/graalvm.tar.gz

ENV JAVA_HOME=/usr/lib/jvm/graalvm-25 \
    PATH="/usr/lib/jvm/graalvm-25/bin:${PATH}"

# The JDK ships its own trust store (a copy of cacerts under
# $JAVA_HOME/lib/security), separate from /etc/ssl/certs/ca-certificates.crt.
# Appending the proxy CA above makes curl/apk trust it, but NOT java/mvnd —
# without this second import, HTTPS calls made by the JVM (e.g. mvnd
# resolving dependencies) still fail with "PKIX path building failed".
# Default JDK keystore password ("changeit") is a public constant, not a secret.
RUN --mount=type=secret,id=external_ca,required=false \
    if [ -s /run/secrets/external_ca ]; then \
      keytool -importcert -noprompt -trustcacerts \
        -alias external-ca -file /run/secrets/external_ca \
        -keystore "$JAVA_HOME/lib/security/cacerts" -storepass changeit; \
    fi

# --- Maven Daemon (mvnd) 1.0.x stable, checksum-verified ---
# Not packaged in Wolfi. Installed from archive.apache.org (the archive host
# keeps old releases, so pinned builds stay reproducible). mvnd bundles Maven;
# its daemon needs a JDK, provided by GraalVM above.
ARG MVND_VERSION=1.0.6
ARG MVND_SHA256_AMD64=88fd474fd3f21b33ec1e6a75950f6abbe493d63a5e2b429475f5230b3ee6cb24
ARG MVND_SHA256_ARM64=e1d8071e172740ecd6a9c380938de69aafc7622218818c56e4d526cc761723c0
RUN arch="$(uname -m)" && \
    case "$arch" in \
      x86_64)  mvnd_arch=amd64; sha="$MVND_SHA256_AMD64" ;; \
      aarch64) mvnd_arch=aarch64; sha="$MVND_SHA256_ARM64" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/mvnd.tar.gz \
      "https://archive.apache.org/dist/maven/mvnd/${MVND_VERSION}/maven-mvnd-${MVND_VERSION}-linux-${mvnd_arch}.tar.gz" && \
    echo "${sha}  /tmp/mvnd.tar.gz" | sha256sum -c - && \
    mkdir -p /opt/mvnd && \
    tar -xzf /tmp/mvnd.tar.gz -C /opt/mvnd --strip-components=1 && \
    rm /tmp/mvnd.tar.gz

ENV PATH="/opt/mvnd/bin:${PATH}"

USER opencode
