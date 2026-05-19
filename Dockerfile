# Build stage
FROM --platform=$BUILDPLATFORM alpine:3.19 AS builder

ARG TARGETPLATFORM
ARG BUILDPLATFORM

# Install Zig
ARG ZIG_VERSION=0.16.0
RUN apk add --no-cache curl tar xz bash

# Download Zig based on target platform
# Zig naming: zig-linux-<arch>-musl-<version>.tar.xz
RUN case "$TARGETPLATFORM" in \
    "linux/amd64") ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-musl-${ZIG_VERSION}.tar.xz" ;; \
    "linux/arm64") ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-linux-aarch64-musl-${ZIG_VERSION}.tar.xz" ;; \
    *) echo "Unsupported platform: $TARGETPLATFORM"; exit 1 ;; \
    esac && \
    curl -fsSL "$ZIG_URL" -o zig.tar.xz && \
    tar -xf zig.tar.xz && \
    mv zig-linux-*-musl-${ZIG_VERSION} /opt/zig && \
    rm zig.tar.xz

ENV PATH="/opt/zig:${PATH}"

WORKDIR /build
COPY . .

# Build release binaries
RUN zig build -Doptimize=ReleaseSafe

# Runtime stage
FROM alpine:3.19

RUN apk add --no-cache libgcc libc6-compat

COPY --from=builder /build/zig-out/bin/zust-analyze /usr/local/bin/zust-analyze
COPY --from=builder /build/zig-out/bin/zust-transpile /usr/local/bin/zust-transpile

# Create non-root user
RUN adduser -D -s /bin/sh zust
USER zust
WORKDIR /workspace

ENTRYPOINT ["zust-analyze"]
CMD ["--help"]
