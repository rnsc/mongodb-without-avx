# MongoDB without AVX
# Builds MongoDB 8.x from source with all AVX/AVX2/AVX512 instructions removed,
# for CPUs without AVX support (e.g., Intel Atom, pre-2011 CPUs, some VMs).
# Uses Bazel build system with MongoDB's hermetic toolchain v4.

FROM debian:12 AS build

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

# This Dockerfile only supports MongoDB 8.0.x (Bazel build system, toolchain v4)
RUN echo "${MONGO_VERSION}" | grep -qE '^8\.0\.[0-9]+$' || \
    { echo "ERROR: Only MongoDB 8.0.x is supported (got ${MONGO_VERSION})"; exit 1; }

RUN mkdir /src && \
    curl -o /tmp/mongo.tar.gz -L "https://github.com/mongodb/mongo/archive/refs/tags/r${MONGO_VERSION}.tar.gz" && \
    tar xaf /tmp/mongo.tar.gz --strip-components=1 -C /src && \
    rm /tmp/mongo.tar.gz

WORKDIR /src

# === AVX PATCHES ===
# All patches are applied before the build to remove AVX instructions from the final binary.

# 1. Compiler flags: replace sandybridge (implies AVX) with x86-64-v2 (SSE4.2, no AVX)
RUN sed -i \
        -e 's/-march=sandybridge/-march=x86-64-v2/g' \
        -e 's/-mprefer-vector-width=128/-mno-avx -mno-avx2/g' \
        bazel/toolchains/cc/mongo_linux/mongo_compiler_flags.bzl

# 2. mozjs: remove -mavx2 flags and stub out AVX2 SIMD functions
RUN python3 - << 'PATCHEOF'
import re

path = "src/third_party/mozjs/BUILD.bazel"
with open(path) as f:
    txt = f.read()

txt = txt.replace('] if arch == "x86_64" and os != "windows" else [])', '] if False else [])')
txt = re.sub(r'"//bazel/config:linux_x86_64": \["-mavx2"\],', '"//bazel/config:linux_x86_64": [],', txt)
txt = re.sub(r'"//bazel/config:macos_x86_64": \["-mavx2"\],', '"//bazel/config:macos_x86_64": [],', txt)

with open(path, "w") as f:
    f.write(txt)

# Stub out SIMD_avx2.cpp — the functions are only called after a runtime AVX2 check,
# so returning nullptr is safe on non-AVX hardware.
with open("src/third_party/mozjs/extract/mozglue/misc/SIMD_avx2.cpp", "w") as f:
    f.write("""#include <stddef.h>
#include <stdint.h>
namespace mozilla { namespace SIMD {
const char* memchr8AVX2(const char* p, char v, size_t n) { return nullptr; }
const char16_t* memchr16AVX2(const char16_t* p, char16_t v, size_t n) { return nullptr; }
const uint64_t* memchr64AVX2(const uint64_t* p, uint64_t v, size_t n) { return nullptr; }
}}
""")
PATCHEOF

# 3. CRoaring: disable AVX2/AVX512 intrinsics (uses __attribute__((target("avx2")))
#    which bypasses -mno-avx2, so we must define ROARING_DISABLE_X64)
RUN sed -i 's/mongo_cc_library(/mongo_cc_library(\n    copts = ["-DROARING_DISABLE_X64"],/' \
        src/third_party/croaring/BUILD.bazel

# === BUILD SYSTEM PATCHES ===

# 4. Toolchain: add /src to builtin include dirs (fixes absolute path inclusion error in Docker)
RUN sed -i 's|COMMON_BUILTIN_INCLUDE_DIRECTORIES = \[|COMMON_BUILTIN_INCLUDE_DIRECTORIES = [\n    "/src",|' \
        bazel/toolchains/cc/mongo_linux/mongo_toolchain_flags_v4.bzl

# 5. Enterprise stubs: create empty BUILD files for enterprise packages referenced by community build
RUN python3 - << 'STUBEOF'
import os

stubs = {
    "": ["enterprise_global_hdrs"],
    "docs": ["docs_global_hdrs"],
    "docs/fle": ["fle_global_hdrs"],
    "docs/testing": ["testing_global_hdrs"],
    "src": ["src_global_hdrs"],
    "src/audit": ["audit_commands_idl_gen", "audit_config_idl_gen", "audit_decryptor_options_idl_gen", "audit_event_type_idl_gen", "audit_global_hdrs", "audit_header_options_idl_gen", "audit_options_idl_gen"],
    "src/audit/logger": ["logger_global_hdrs"],
    "src/audit/mongo": ["mongo_global_hdrs"],
    "src/audit/ocsf": ["ocsf_audit_events_idl_gen", "ocsf_global_hdrs"],
    "src/encryptdb": ["decrypt_tool_options_idl_gen", "encryptdb_global_hdrs", "encryption_key_manager_idl_gen", "encryption_options_idl_gen", "keystore_metadata_idl_gen", "log_redact_options_idl_gen"],
    "src/fcbis": ["fcbis_global_hdrs"],
    "src/fips": ["fips_flag_client_idl_gen", "fips_flag_server_idl_gen", "fips_global_hdrs"],
    "src/fle": ["fle_global_hdrs"],
    "src/fle/commands": ["commands_global_hdrs"],
    "src/fle/lib": ["lib_global_hdrs"],
    "src/fle/query_analysis": ["query_analysis_global_hdrs"],
    "src/fle/shell": ["shell_global_hdrs"],
    "src/hot_backups": ["backup_cursor_parameters_idl_gen", "document_source_backup_file_idl_gen", "hot_backups_global_hdrs"],
    "src/inmemory": ["inmemory_global_hdrs", "inmemory_global_options_idl_gen"],
    "src/kerberos": ["kerberos_global_hdrs", "kerberos_tool_options_idl_gen"],
    "src/kmip": ["kmip_global_hdrs", "kmip_options_idl_gen"],
    "src/ldap": ["ldap_global_hdrs", "ldap_options_idl_gen", "ldap_options_mongod_idl_gen", "ldap_parameters_idl_gen", "ldap_runtime_parameters_idl_gen", "ldap_tool_options_idl_gen", "ldap_user_cache_poller_idl_gen"],
    "src/ldap/connections": ["connections_global_hdrs"],
    "src/ldap/name_mapping": ["name_mapping_global_hdrs"],
    "src/live_import": ["collection_properties_idl_gen", "live_import_global_hdrs"],
    "src/live_import/commands": ["commands_global_hdrs", "export_collection_idl_gen", "import_collection_idl_gen", "vote_commit_import_collection_idl_gen"],
    "src/magic_restore": ["magic_restore_global_hdrs", "magic_restore_options_idl_gen", "magic_restore_structs_idl_gen"],
    "src/queryable": ["queryable_global_hdrs"],
    "src/queryable/blockstore": ["blockstore_global_hdrs"],
    "src/queryable/queryable_wt": ["queryable_global_options_idl_gen", "queryable_wt_global_hdrs"],
    "src/sasl": ["auth_delay_idl_gen", "oidc_commands_idl_gen", "oidc_parameters_idl_gen", "sasl_aws_server_options_idl_gen", "sasl_global_hdrs"],
    "src/scripts": ["scripts_global_hdrs"],
    "src/serverless": ["mongoqd_options_idl_gen", "serverless_global_hdrs"],
    "src/streams": ["streams_global_hdrs"],
    "src/streams/commands": ["commands_global_hdrs", "stream_ops_idl_gen"],
    "src/streams/exec": ["checkpoint_data_idl_gen", "common_idl_gen", "config_idl_gen", "exec_global_hdrs", "exec_internal_idl_gen", "stages_idl_gen"],
    "src/streams/exec/checkpoint": ["checkpoint_global_hdrs"],
    "src/streams/exec/tests": ["tests_global_hdrs"],
    "src/streams/management": ["management_global_hdrs"],
    "src/streams/management/tests": ["tests_global_hdrs"],
    "src/streams/tools": ["tools_global_hdrs"],
    "src/streams/util": ["util_global_hdrs"],
    "src/streams/util/tests": ["tests_global_hdrs"],
    "src/util": ["util_global_hdrs"],
    "src/workloads": ["workloads_global_hdrs"],
    "src/workloads/streams": ["streams_global_hdrs"],
}

base = "src/mongo/db/modules/enterprise"
for subdir, targets in stubs.items():
    path = os.path.join(base, subdir) if subdir else base
    os.makedirs(path, exist_ok=True)
    lines = ['package(default_visibility = ["//visibility:public"])']
    lines += [f'filegroup(name = "{t}", srcs = [])' for t in targets]
    with open(os.path.join(path, "BUILD.bazel"), "w") as f:
        f.write("\n".join(lines) + "\n")

print(f"Created {len(stubs)} enterprise stub BUILD files")
STUBEOF

# Install Bazelisk
RUN curl -L -o /usr/local/bin/bazel \
        https://github.com/bazelbuild/bazelisk/releases/download/v1.25.0/bazelisk-linux-amd64 && \
    chmod +x /usr/local/bin/bazel

ARG NUM_JOBS=0

# Build MongoDB using Bazel
# Step 1: Fetch toolchain with --nobuild
# Step 2: Replace toolchain's libstdc++ (contains VEX-encoded AVX instructions) with system shared lib
# Step 3: Full build
RUN export GIT_PYTHON_REFRESH=quiet && \
    if [ "${NUM_JOBS}" -gt 0 ] 2>/dev/null; then \
        RESOLVED_JOBS="${NUM_JOBS}"; \
    else \
        CPUS=$(nproc); \
        RESOLVED_JOBS=$(( CPUS > 1 ? CPUS - 1 : 1 )); \
    fi && \
    export JOBS_ARG="--jobs=${RESOLVED_JOBS}" && \
    echo "=== Fetching toolchain ===" && \
    bazel build --config=opt --config=local \
        --//bazel/config:mongo_toolchain_version=v4 \
        --nobuild //:install-mongod 2>&1 || true && \
    echo "=== Replacing toolchain libstdc++ ===" && \
    for f in $(find /root/.cache/bazel -path '*/mongo_toolchain_v4/stow/gcc-v4/*/libstdc++.a' 2>/dev/null); do \
        dir=$(dirname "$f"); \
        rm -f "$dir/libstdc++.a" "$dir/libstdc++.so"; \
        ln -sf /usr/lib/x86_64-linux-gnu/libstdc++.so.6 "$dir/libstdc++.so"; \
        echo "Patched: $dir"; \
    done && \
    echo "=== Building with ${RESOLVED_JOBS} job(s) ===" && \
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

# Copy binaries and generate AVX report
RUN mkdir -p /binaries && \
    MONGOD=$(find -L bazel-bin -name 'mongod' -not -name '*.params' -not -path '*/_objs/*' 2>/dev/null | head -1) && \
    MONGOS=$(find -L bazel-bin -name 'mongos' -not -name '*.params' -not -path '*/_objs/*' 2>/dev/null | head -1) && \
    echo "mongod: ${MONGOD}" && echo "mongos: ${MONGOS}" && \
    cp -L "${MONGOD}" /binaries/mongod && \
    cp -L "${MONGOS}" /binaries/mongos && \
    echo "=== AVX (ymm) instructions ===" > /avx_report.txt && \
    objdump -d /binaries/mongod | awk '/^[0-9a-f]+ </{f=$0} /%ymm/{print f}' | sort -u >> /avx_report.txt && \
    echo "=== AVX ymm count ===" >> /avx_report.txt && \
    (objdump -d /binaries/mongod | grep -cE '%ymm|,ymm|vbroadcast' >> /avx_report.txt) || true && \
    echo "=== VEX xmm count ===" >> /avx_report.txt && \
    (objdump -d /binaries/mongod | grep -cP '\tv[a-z].*%xmm' >> /avx_report.txt) || true && \
    strip --strip-debug /binaries/mongod /binaries/mongos && \
    cat /avx_report.txt

# === Final image ===
FROM debian:12-slim

ARG MONGOSH_VERSION=2.8.1

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
        libcurl4 \
        libssl3 \
        liblzma5 \
        libstdc++6 \
        ca-certificates \
        curl \
    && curl -fsSL "https://downloads.mongodb.com/compass/mongosh-${MONGOSH_VERSION}-linux-x64.tgz" \
        | tar xz --strip-components=1 -C /usr/local --include='*/bin/*' \
    && apt-get purge -y curl \
    && apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /binaries/mongod /usr/local/bin/
COPY --from=build /binaries/mongos /usr/local/bin/
COPY --from=build /avx_report.txt /avx_report.txt

RUN mkdir -p /data/db /data/configdb && \
    groupadd -r mongodb --gid=999 && \
    useradd -r -g mongodb --uid=999 mongodb && \
    chown -R 999:999 /data && \
    chmod -R 750 /data

VOLUME ["/data/db", "/data/configdb"]
EXPOSE 27017

USER mongodb
ENTRYPOINT ["/usr/local/bin/mongod"]
CMD ["--bind_ip_all"]
