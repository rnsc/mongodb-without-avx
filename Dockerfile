# MongoDB without AVX
# Based on https://github.com/alanedwardes/mongodb-without-avx
# Updated for MongoDB 8.x with Bazel build system

FROM debian:12 AS build

# Install build dependencies for MongoDB 8.x with Bazel
RUN apt-get update -y && apt-get install -y --no-install-recommends \
        binutils \
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

# Patch mozjs BUILD.bazel to remove hardcoded -mavx2 flags.
RUN python3 - << 'PATCHEOF'
import re

path = "src/third_party/mozjs/BUILD.bazel"
with open(path) as f:
    txt = f.read()

# Remove -mavx2 from PLATFORM_COPTS
txt = txt.replace('] if arch == "x86_64" and os != "windows" else [])', '] if False else [])')

# Replace SIMD_avx2.cpp with a stub
stub = """
#include <stddef.h>
#include <stdint.h>
namespace mozilla {
namespace SIMD {
const char* memchr8AVX2(const char* ptr, char val, size_t len) { return nullptr; }
const char16_t* memchr16AVX2(const char16_t* ptr, char16_t val, size_t len) { return nullptr; }
const uint64_t* memchr64AVX2(const uint64_t* ptr, uint64_t val, size_t len) { return nullptr; }
} // namespace SIMD
} // namespace mozilla
"""
with open("src/third_party/mozjs/extract/mozglue/misc/SIMD_avx2.cpp", "w") as f:
    f.write(stub)

# Remove -mavx2 from the select() block
txt = re.sub(r'"//bazel/config:linux_x86_64": \["-mavx2"\],', '"//bazel/config:linux_x86_64": [],', txt)
txt = re.sub(r'"//bazel/config:macos_x86_64": \["-mavx2"\],', '"//bazel/config:macos_x86_64": [],', txt)

with open(path, "w") as f:
    f.write(txt)

print("mozjs patch applied")
PATCHEOF

# Patch mongo_compiler_flags.bzl to replace sandybridge/AVX with x86-64-v2/no-AVX
RUN sed -i \
        -e 's/-march=sandybridge/-march=x86-64-v2/g' \
        -e 's/-mprefer-vector-width=128/-mno-avx -mno-avx2/g' \
        bazel/toolchains/cc/mongo_linux/mongo_compiler_flags.bzl && \
    echo "Patch applied:" && \
    grep -n "march=\|vector-width\|avx\|x86-64" \
        bazel/toolchains/cc/mongo_linux/mongo_compiler_flags.bzl || true

# Patch CRoaring to disable x64 AVX intrinsics (uses __attribute__((target("avx2"))) which ignores -mno-avx2)
RUN sed -i 's/mongo_cc_library(/mongo_cc_library(\n    copts = ["-DROARING_DISABLE_X64"],/' \
        src/third_party/croaring/BUILD.bazel && \
    echo "CRoaring AVX disabled"

# Patch toolchain to add workspace root to builtin include dirs (fixes absolute path inclusion error)
RUN sed -i 's|COMMON_BUILTIN_INCLUDE_DIRECTORIES = \[|COMMON_BUILTIN_INCLUDE_DIRECTORIES = [\n    "/src",|' \
        bazel/toolchains/cc/mongo_linux/mongo_toolchain_flags_v4.bzl && \
    echo "Toolchain include path patch applied"

# Create stub BUILD files for enterprise packages
RUN mkdir -p src/mongo/db/modules/enterprise \
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
             src/mongo/db/modules/enterprise/src/workloads/streams
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "enterprise_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "docs_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/docs/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "fle_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/docs/fle/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "testing_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/docs/testing/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "src_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "audit_commands_idl_gen", srcs = [])\nfilegroup(name = "audit_config_idl_gen", srcs = [])\nfilegroup(name = "audit_decryptor_options_idl_gen", srcs = [])\nfilegroup(name = "audit_event_type_idl_gen", srcs = [])\nfilegroup(name = "audit_global_hdrs", srcs = [])\nfilegroup(name = "audit_header_options_idl_gen", srcs = [])\nfilegroup(name = "audit_options_idl_gen", srcs = [])\n' > src/mongo/db/modules/enterprise/src/audit/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "logger_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/audit/logger/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "mongo_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/audit/mongo/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "ocsf_audit_events_idl_gen", srcs = [])\nfilegroup(name = "ocsf_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/audit/ocsf/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "decrypt_tool_options_idl_gen", srcs = [])\nfilegroup(name = "encryptdb_global_hdrs", srcs = [])\nfilegroup(name = "encryption_key_manager_idl_gen", srcs = [])\nfilegroup(name = "encryption_options_idl_gen", srcs = [])\nfilegroup(name = "keystore_metadata_idl_gen", srcs = [])\nfilegroup(name = "log_redact_options_idl_gen", srcs = [])\n' > src/mongo/db/modules/enterprise/src/encryptdb/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "fcbis_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/fcbis/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "fips_flag_client_idl_gen", srcs = [])\nfilegroup(name = "fips_flag_server_idl_gen", srcs = [])\nfilegroup(name = "fips_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/fips/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "fle_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/fle/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "commands_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/fle/commands/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "lib_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/fle/lib/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "query_analysis_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/fle/query_analysis/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "shell_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/fle/shell/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "backup_cursor_parameters_idl_gen", srcs = [])\nfilegroup(name = "document_source_backup_file_idl_gen", srcs = [])\nfilegroup(name = "hot_backups_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/hot_backups/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "inmemory_global_hdrs", srcs = [])\nfilegroup(name = "inmemory_global_options_idl_gen", srcs = [])\n' > src/mongo/db/modules/enterprise/src/inmemory/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "kerberos_global_hdrs", srcs = [])\nfilegroup(name = "kerberos_tool_options_idl_gen", srcs = [])\n' > src/mongo/db/modules/enterprise/src/kerberos/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "kmip_global_hdrs", srcs = [])\nfilegroup(name = "kmip_options_idl_gen", srcs = [])\n' > src/mongo/db/modules/enterprise/src/kmip/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "ldap_global_hdrs", srcs = [])\nfilegroup(name = "ldap_options_idl_gen", srcs = [])\nfilegroup(name = "ldap_options_mongod_idl_gen", srcs = [])\nfilegroup(name = "ldap_parameters_idl_gen", srcs = [])\nfilegroup(name = "ldap_runtime_parameters_idl_gen", srcs = [])\nfilegroup(name = "ldap_tool_options_idl_gen", srcs = [])\nfilegroup(name = "ldap_user_cache_poller_idl_gen", srcs = [])\n' > src/mongo/db/modules/enterprise/src/ldap/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "connections_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/ldap/connections/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "name_mapping_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/ldap/name_mapping/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "collection_properties_idl_gen", srcs = [])\nfilegroup(name = "live_import_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/live_import/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "commands_global_hdrs", srcs = [])\nfilegroup(name = "export_collection_idl_gen", srcs = [])\nfilegroup(name = "import_collection_idl_gen", srcs = [])\nfilegroup(name = "vote_commit_import_collection_idl_gen", srcs = [])\n' > src/mongo/db/modules/enterprise/src/live_import/commands/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "magic_restore_global_hdrs", srcs = [])\nfilegroup(name = "magic_restore_options_idl_gen", srcs = [])\nfilegroup(name = "magic_restore_structs_idl_gen", srcs = [])\n' > src/mongo/db/modules/enterprise/src/magic_restore/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "queryable_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/queryable/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "blockstore_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/queryable/blockstore/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "queryable_global_options_idl_gen", srcs = [])\nfilegroup(name = "queryable_wt_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/queryable/queryable_wt/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "auth_delay_idl_gen", srcs = [])\nfilegroup(name = "oidc_commands_idl_gen", srcs = [])\nfilegroup(name = "oidc_parameters_idl_gen", srcs = [])\nfilegroup(name = "sasl_aws_server_options_idl_gen", srcs = [])\nfilegroup(name = "sasl_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/sasl/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "scripts_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/scripts/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "mongoqd_options_idl_gen", srcs = [])\nfilegroup(name = "serverless_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/serverless/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "streams_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/streams/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "commands_global_hdrs", srcs = [])\nfilegroup(name = "stream_ops_idl_gen", srcs = [])\n' > src/mongo/db/modules/enterprise/src/streams/commands/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "checkpoint_data_idl_gen", srcs = [])\nfilegroup(name = "common_idl_gen", srcs = [])\nfilegroup(name = "config_idl_gen", srcs = [])\nfilegroup(name = "exec_global_hdrs", srcs = [])\nfilegroup(name = "exec_internal_idl_gen", srcs = [])\nfilegroup(name = "stages_idl_gen", srcs = [])\n' > src/mongo/db/modules/enterprise/src/streams/exec/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "checkpoint_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/streams/exec/checkpoint/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "tests_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/streams/exec/tests/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "management_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/streams/management/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "tests_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/streams/management/tests/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "tools_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/streams/tools/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "util_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/streams/util/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "tests_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/streams/util/tests/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "util_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/util/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "workloads_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/workloads/BUILD.bazel
RUN printf 'package(default_visibility = ["//visibility:public"])\nfilegroup(name = "streams_global_hdrs", srcs = [])\n' > src/mongo/db/modules/enterprise/src/workloads/streams/BUILD.bazel

# Install Bazelisk
RUN mkdir -p /root/.local/bin && \
    curl -L -o /root/.local/bin/bazel https://github.com/bazelbuild/bazelisk/releases/download/v1.25.0/bazelisk-linux-amd64 && \
    chmod +x /root/.local/bin/bazel

ENV PATH="/root/.local/bin:${PATH}"

# Override at build time with: docker build --build-arg NUM_JOBS=8
ARG NUM_JOBS=0

# Build MongoDB using Bazel (separate RUN so binary discovery can be iterated without rebuilding)
RUN export GIT_PYTHON_REFRESH=quiet && \
    if [ "${NUM_JOBS}" -gt 0 ] 2>/dev/null; then \
        RESOLVED_JOBS="${NUM_JOBS}"; \
    else \
        CPUS=$(nproc); \
        RESOLVED_JOBS=$(( CPUS > 1 ? CPUS - 1 : 1 )); \
    fi && \
    echo "Building with ${RESOLVED_JOBS} job(s) ($(nproc) CPUs available)" && \
    export JOBS_ARG="--jobs=${RESOLVED_JOBS}" && \
    bazel build \
        --config=opt \
        --config=local \
        --//bazel/config:mongo_toolchain_version=v4 \
        --//bazel/config:build_enterprise=False \
        --disable_warnings_as_errors=True \
        --fission=no \
        --copt=-mno-avx \
        --copt=-mno-avx2 \
        --copt=-mno-avx512f \
        --per_file_copt=.*@-mno-avx,-mno-avx2,-mno-avx512f \
        --action_env=SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
        --action_env=SSL_CERT_DIR=/etc/ssl/certs \
        --action_env=REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
        --action_env=CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
        --action_env=LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libstdc++.so.6 \
        --action_env=PYTHONWARNINGS=ignore:UserWarning \
        --define=MONGO_VERSION="${MONGO_VERSION}" \
        --define=GIT_COMMIT_HASH="0000000000000000000000000000000000000000" \
        ${JOBS_ARG} \
        //:install-mongod \
        //:install-mongos

# Find and copy binaries (separate RUN for cache-friendly iteration)
RUN mkdir -p /binaries && \
    echo "=== Exploring bazel output structure ===" && \
    echo "bazel-bin symlink: $(ls -la bazel-bin 2>/dev/null)" && \
    echo "bazel-bin resolved: $(readlink -f bazel-bin 2>/dev/null)" && \
    echo "--- find -L bazel-bin for mongod/mongos ---" && \
    find -L bazel-bin -name 'mongod' -not -name '*.params' -not -path '*/_objs/*' 2>/dev/null && \
    find -L bazel-bin -name 'mongos' -not -name '*.params' -not -path '*/_objs/*' 2>/dev/null && \
    echo "--- find -L bazel-out for mongod/mongos ---" && \
    find -L bazel-out -name 'mongod' -not -name '*.params' -not -path '*/_objs/*' 2>/dev/null && \
    find -L bazel-out -name 'mongos' -not -name '*.params' -not -path '*/_objs/*' 2>/dev/null && \
    echo "--- direct path check ---" && \
    ls -la bazel-bin/src/mongo/db/mongod bazel-bin/src/mongo/s/mongos 2>/dev/null || true && \
    ls -la bazel-bin/src/mongo/db/mongod_with_debug bazel-bin/src/mongo/s/mongos_with_debug 2>/dev/null || true && \
    echo "--- find in bazel cache ---" && \
    find /root/.cache/bazel -maxdepth 8 -name 'mongod' -not -name '*.params' -not -path '*/_objs/*' 2>/dev/null | head -5 && \
    echo "=== Copying binaries ===" && \
    MONGOD=$(find -L bazel-bin -name 'mongod' -not -name '*.params' -not -path '*/_objs/*' 2>/dev/null | head -1) && \
    if [ -z "$MONGOD" ]; then \
        MONGOD=$(find -L bazel-bin -name 'mongod_with_debug' -not -path '*/_objs/*' 2>/dev/null | head -1); \
    fi && \
    if [ -z "$MONGOD" ]; then \
        MONGOD=$(find /root/.cache/bazel -name 'mongod' -not -name '*.params' -not -path '*/_objs/*' 2>/dev/null | head -1); \
    fi && \
    MONGOS=$(find -L bazel-bin -name 'mongos' -not -name '*.params' -not -path '*/_objs/*' 2>/dev/null | head -1) && \
    if [ -z "$MONGOS" ]; then \
        MONGOS=$(find -L bazel-bin -name 'mongos_with_debug' -not -path '*/_objs/*' 2>/dev/null | head -1); \
    fi && \
    if [ -z "$MONGOS" ]; then \
        MONGOS=$(find /root/.cache/bazel -name 'mongos' -not -name '*.params' -not -path '*/_objs/*' 2>/dev/null | head -1); \
    fi && \
    echo "Found mongod: ${MONGOD}" && \
    echo "Found mongos: ${MONGOS}" && \
    cp -L "${MONGOD}" /binaries/mongod && \
    cp -L "${MONGOS}" /binaries/mongos && \
    echo "=== Functions with AVX (ymm) in mongod ===" > /avx_report.txt && \
    objdump -d /binaries/mongod \
        | awk '/^[0-9a-f]+ </{func=$0} /%ymm/{print func}' \
        | sort -u >> /avx_report.txt && \
    echo "=== AVX instruction count ===" >> /avx_report.txt && \
    ( objdump -d /binaries/mongod | grep -cE '%ymm|,ymm|vbroadcast' >> /avx_report.txt ) || true && \
    strip --strip-debug /binaries/mongod && \
    strip --strip-debug /binaries/mongos && \
    cat /avx_report.txt

# Final image - includes avx_report.txt for debugging
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

# Copy MongoDB binaries and debug report
COPY --from=build /binaries/mongod /usr/local/bin/
COPY --from=build /binaries/mongos /usr/local/bin/
COPY --from=build /avx_report.txt /avx_report.txt

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

