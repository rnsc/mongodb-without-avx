# MongoDB without AVX
# Based on https://github.com/alanedwardes/mongodb-without-avx
# Updated for MongoDB 8.x with Bazel build system

FROM debian:12 AS build

# Install build dependencies for MongoDB 8.x with Bazel
RUN apt-get update -y && apt-get install --no-install-recommends -y \
        build-essential \
        ca-certificates \
        libcurl4-openssl-dev \
        liblzma-dev \
        libssl-dev \
        python-dev-is-python3 \
        python3-pip \
        python3-venv \
        lld \
        curl \
        git \
        pkg-config \
        openjdk-17-jdk \
    && rm -rf /var/lib/apt/lists/*

ARG MONGO_VERSION=8.0.19

# Download MongoDB source
RUN mkdir /src && \
    curl -o /tmp/mongo.tar.gz -L "https://github.com/mongodb/mongo/archive/refs/tags/r${MONGO_VERSION}.tar.gz" && \
    tar xaf /tmp/mongo.tar.gz --strip-components=1 -C /src && \
    rm /tmp/mongo.tar.gz

WORKDIR /src

# Create stub enterprise directory structure to satisfy build dependencies.
#
# src/BUILD.bazel references enterprise sub-packages (docs, queryable, etc.) even when
# --//bazel/config:build_enterprise=False is set. The set of referenced paths changes
# across patch releases, so instead of a fixed list we:
#   1. Parse src/BUILD.bazel to find every enterprise sub-path it mentions, and
#      stub each one automatically.
#   2. Also stub a known fixed set as a safety net for paths not caught by grep.
RUN set -e; \
    ENTERPRISE_ROOT="src/mongo/db/modules/enterprise"; \
    STUB='# Stub BUILD file for community build'; \
    \
    # Auto-discover every enterprise sub-path mentioned in src/BUILD.bazel
    grep -oE 'src/mongo/db/modules/enterprise/[^"'\'' >]+' src/BUILD.bazel \
        | sed 's|/[^/]*$||' \
        | sort -u \
        | while IFS= read -r subpath; do \
            rel="${subpath#src/mongo/db/modules/enterprise/}"; \
            fullpath="${ENTERPRISE_ROOT}/${rel}"; \
            mkdir -p "${fullpath}"; \
            printf '%s\n' "${STUB}" > "${fullpath}/BUILD.bazel"; \
          done; \
    \
    # Fixed safety-net stubs (covers top-level + known subdirs across 8.x releases)
    for d in \
        "${ENTERPRISE_ROOT}" \
        "${ENTERPRISE_ROOT}/src" \
        "${ENTERPRISE_ROOT}/src/workloads" \
        "${ENTERPRISE_ROOT}/src/workloads/streams" \
        "${ENTERPRISE_ROOT}/docs" \
        "${ENTERPRISE_ROOT}/src/queryable" \
        "${ENTERPRISE_ROOT}/distsrc" \
    ; do \
        mkdir -p "${d}"; \
        printf '%s\n' "${STUB}" > "${d}/BUILD.bazel"; \
    done; \
    \
    echo "Stubbed enterprise directories:"; \
    find "${ENTERPRISE_ROOT}" -name BUILD.bazel | sort

# Install Bazelisk directly (handles correct Bazel version automatically)
# This avoids needing MongoDB's install_bazel.py which has additional Python dependencies
RUN mkdir -p /root/.local/bin && \
    curl -L -o /root/.local/bin/bazel https://github.com/bazelbuild/bazelisk/releases/download/v1.25.0/bazelisk-linux-amd64 && \
    chmod +x /root/.local/bin/bazel

ENV PATH="/root/.local/bin:${PATH}"

# Apply the no-AVX patch to disable sandybridge/AVX optimizations
# The patch modifies bazel/toolchains/cc/mongo_linux/mongo_linux_cc_toolchain_config.bzl
# to use -march=x86-64-v2 instead of -march=sandybridge
# x86-64-v2 supports SSE4.2 and POPCNT but NOT AVX (compatible with pre-2011 CPUs)
RUN sed -i 's/-march=sandybridge", "-mtune=generic", "-mprefer-vector-width=128/-march=x86-64-v2", "-mtune=generic/g' \
    bazel/toolchains/cc/mongo_linux/mongo_linux_cc_toolchain_config.bzl && \
    echo "Patch applied. Checking file contents:" && \
    grep -n "march=" bazel/toolchains/cc/mongo_linux/mongo_linux_cc_toolchain_config.bzl || true

ARG NUM_JOBS=

# Build MongoDB using Bazel
# --config=local disables remote execution (required for building outside MongoDB's infra)
# --//bazel/config:build_enterprise=False explicitly disables enterprise modules
# --action_env flags pass the host CA bundle into sandboxed actions so pip/curl
#   can verify TLS certificates when fetching Python wheels from PyPI
RUN export GIT_PYTHON_REFRESH=quiet && \
    if [ -n "${NUM_JOBS}" ] && [ "${NUM_JOBS}" -gt 0 ]; then \
        export JOBS_ARG="--jobs=${NUM_JOBS}"; \
    fi && \
    bazel build \
        --config=local \
        --//bazel/config:build_enterprise=False \
        --disable_warnings_as_errors=True \
        --action_env=SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
        --action_env=SSL_CERT_DIR=/etc/ssl/certs \
        --action_env=REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
        --action_env=CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
        ${JOBS_ARG} \
        //:install-mongod \
        //:install-mongos

# Strip and prepare binaries
RUN strip --strip-debug bazel-bin/install/bin/mongod && \
    strip --strip-debug bazel-bin/install/bin/mongos && \
    ls -la bazel-bin/install/bin/

# Final image
FROM debian:12-slim

# Install runtime dependencies
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
        libcurl4 \
        libssl3 \
        liblzma5 \
        ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Copy MongoDB binaries
COPY --from=build /src/bazel-bin/install/bin/mongod /usr/local/bin/
COPY --from=build /src/bazel-bin/install/bin/mongos /usr/local/bin/

# Create data directory with proper permissions
RUN mkdir -p /data/db /data/configdb && \
    chmod -R 750 /data && \
    chown -R 999:999 /data

# Create mongodb user
RUN groupadd -r mongodb --gid=999 && \
    useradd -r -g mongodb --uid=999 mongodb

# Set volume for data persistence
VOLUME ["/data/db", "/data/configdb"]

# Expose MongoDB default port
EXPOSE 27017

USER mongodb

ENTRYPOINT ["/usr/local/bin/mongod"]
CMD ["--bind_ip_all"]
