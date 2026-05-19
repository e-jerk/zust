# Build stage
FROM --platform=$BUILDPLATFORM alpine:3.19 AS builder

ARG TARGETPLATFORM
ARG BUILDPLATFORM

# Install Zig
ARG ZIG_VERSION=0.16.0
RUN apk add --no-cache curl tar xz bash

# Download Zig based on target platform
RUN case "$TARGETPLATFORM" in \
    "linux/amd64") ZIG_ARCH="x86_64-linux-musl" ;; \
    "linux/arm64") ZIG_ARCH="aarch64-linux-musl" ;; \
    *) echo "Unsupported platform: $TARGETPLATFORM"; exit 1 ;; \
    esac && \
    curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz" -o zig.tar.xz && \
    tar -xf zig.tar.xz && \
    mv "zig-${ZIG_ARCH}-${ZIG_VERSION}" /opt/zig && \
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
