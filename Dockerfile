# MongoDB without AVX
# Based on https://github.com/alanedwardes/mongodb-without-avx
# Updated for MongoDB 8.x with Bazel build system

FROM debian:12 AS build

# Install build dependencies for MongoDB 8.x with Bazel
RUN apt-get update -y && apt-get install -y --no-install-recommends \
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

# Create stub BUILD files for every enterprise sub-package referenced by
# src/BUILD.bazel:core_headers_library_with_debug. These paths exist in the
# enterprise repo but not in the community tarball. The list was extracted
# directly from src/BUILD.bazel in MongoDB 8.0.19.
RUN set -e; \
    STUB='# Stub BUILD file for community build'; \
    for d in \
        src/mongo/db/modules/enterprise \
        src/mongo/db/modules/enterprise/docs \
        src/mongo/db/modules/enterprise/docs/fle \
        src/mongo/db/modules/enterprise/docs/testing \
        src/mongo/db/modules/enterprise/src \
        src/mongo/db/modules/enterprise/src/audit \
        src/mongo/db/modules/enterprise/src/audit/logger \
        src/mongo/db/modules/enterprise/src/audit/mongo \
        src/mongo/db/modules/enterprise/src/audit/ocsf \
        src/mongo/db/modules/enterprise/src/encryptdb \
        src/mongo/db/modules/enterprise/src/fcbis \
        src/mongo/db/modules/enterprise/src/fips \
        src/mongo/db/modules/enterprise/src/fle \
        src/mongo/db/modules/enterprise/src/fle/commands \
        src/mongo/db/modules/enterprise/src/fle/lib \
        src/mongo/db/modules/enterprise/src/fle/query_analysis \
        src/mongo/db/modules/enterprise/src/fle/shell \
        src/mongo/db/modules/enterprise/src/hot_backups \
        src/mongo/db/modules/enterprise/src/inmemory \
        src/mongo/db/modules/enterprise/src/kerberos \
        src/mongo/db/modules/enterprise/src/kmip \
        src/mongo/db/modules/enterprise/src/ldap \
        src/mongo/db/modules/enterprise/src/ldap/connections \
        src/mongo/db/modules/enterprise/src/ldap/name_mapping \
        src/mongo/db/modules/enterprise/src/live_import \
        src/mongo/db/modules/enterprise/src/live_import/commands \
        src/mongo/db/modules/enterprise/src/magic_restore \
        src/mongo/db/modules/enterprise/src/queryable \
        src/mongo/db/modules/enterprise/src/queryable/blockstore \
        src/mongo/db/modules/enterprise/src/queryable/queryable_wt \
        src/mongo/db/modules/enterprise/src/sasl \
        src/mongo/db/modules/enterprise/src/scripts \
        src/mongo/db/modules/enterprise/src/serverless \
        src/mongo/db/modules/enterprise/src/streams \
        src/mongo/db/modules/enterprise/src/streams/commands \
        src/mongo/db/modules/enterprise/src/streams/exec \
        src/mongo/db/modules/enterprise/src/streams/exec/checkpoint \
        src/mongo/db/modules/enterprise/src/streams/exec/tests \
        src/mongo/db/modules/enterprise/src/streams/management \
        src/mongo/db/modules/enterprise/src/streams/management/tests \
        src/mongo/db/modules/enterprise/src/streams/tools \
        src/mongo/db/modules/enterprise/src/streams/util \
        src/mongo/db/modules/enterprise/src/streams/util/tests \
        src/mongo/db/modules/enterprise/src/util \
        src/mongo/db/modules/enterprise/src/workloads \
        src/mongo/db/modules/enterprise/src/workloads/streams \
    ; do \
        mkdir -p "${d}"; \
        printf '%s\n' "${STUB}" > "${d}/BUILD.bazel"; \
    done

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
