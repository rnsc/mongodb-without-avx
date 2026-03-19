# MongoDB without AVX

Docker image that builds **MongoDB 8.0.x** from source with all AVX/AVX2/AVX512
instructions removed, so it runs on CPUs without AVX support (e.g., Intel Atom,
pre-2011 CPUs, some virtualized environments).

## Quick Start

```bash
# Pull the pre-built image
docker pull rnsc/mongo-wo-avx:8.0.19

# Run
docker run -d -p 27017:27017 --name mongodb rnsc/mongo-wo-avx:8.0.19
```

## What's Included

- **mongod** — database server
- **mongos** — shard router
- **mongosh** — MongoDB shell (prebuilt binary)

## Building from Source

```bash
# Default build (auto-detects CPU count)
docker build -t mongo-wo-avx:8.0.19 .

# With explicit parallelism
docker build --build-arg NUM_JOBS=11 -t mongo-wo-avx:8.0.19 .

# Different 8.0.x patch version
docker build --build-arg MONGO_VERSION=8.0.18 -t mongo-wo-avx:8.0.18 .
```

> **Note:** Only MongoDB 8.0.x versions are supported. The Dockerfile will fail
> if a non-8.0.x version is specified. Building takes ~90 minutes on a 6-core
> CPU with 24GB RAM.

### Build Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `MONGO_VERSION` | `8.0.19` | MongoDB version (must be 8.0.x) |
| `NUM_JOBS` | `0` (auto) | Parallel build jobs (0 = total CPUs - 1) |
| `MONGOSH_VERSION` | `2.8.1` | mongosh version to bundle |

## How It Works

MongoDB 8.0.x uses the Bazel build system with a hermetic clang toolchain.
Several sources of AVX instructions are patched out:

1. **Compiler flags** — `-march=sandybridge` (implies AVX) replaced with `-march=x86-64-v2`
2. **mozjs (SpiderMonkey)** — AVX2 SIMD functions stubbed out
3. **CRoaring (bitmap library)** — `ROARING_DISABLE_X64` disables function-level AVX attributes
4. **Toolchain libstdc++** — the bundled static library contains VEX-encoded instructions; replaced with system `libstdc++.so.6`

The final binary has **zero AVX and zero VEX-encoded instructions**.

## Verifying No AVX

Each image includes an AVX report:

```bash
docker run --rm --entrypoint cat rnsc/mongo-wo-avx:8.0.19 /avx_report.txt
```

## Tested Hardware

- Intel Atom C3538 (Goldmont) — no AVX support
- Build host: AMD Ryzen 5 9600X (Zen 5)

## Version Compatibility

This Dockerfile only supports **MongoDB 8.0.x** (which uses Bazel). Earlier
versions (pre-8.0.13) used SCons and require different patches. For MongoDB 7.x
and below, see [GermanAizek/mongodb-without-avx](https://github.com/GermanAizek/mongodb-without-avx)
or [rallyrabbit/mongodb-without-avx-requirements](https://github.com/rallyrabbit/mongodb-without-avx-requirements).

## Runtime Configuration

- Base image: `debian:12-slim`
- Default port: `27017`
- Data volume: `/data/db`
- Config volume: `/data/configdb`
- Runs as user `mongodb` (uid/gid 999)

## License

MongoDB is licensed under the [Server Side Public License (SSPL)](https://www.mongodb.com/licensing/server-side-public-license).
This repository only contains build instructions (Dockerfile), not MongoDB source code.
