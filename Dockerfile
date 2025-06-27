# Multi-stage build for HT2 development and CI testing
# This matches the CI environment exactly

# Build stage
FROM robnomad/crystal:dev-hoard as builder

WORKDIR /app

# Install dependencies
RUN apk add --no-cache \
    curl \
    git \
    make

# Copy shard files first for better caching
COPY shard.yml shard.lock ./
RUN shards install

# Copy the rest of the application
COPY . .

# Format check
RUN crystal tool format --check

# Verify the build works
RUN crystal build --release src/ht2.cr

# Runtime stage for testing
FROM robnomad/crystal:dev-hoard as test

WORKDIR /app

# Install runtime dependencies and test tools
RUN apk add --no-cache \
    curl \
    git \
    make \
    python3 \
    py3-pip \
    nodejs \
    npm

# Install Python httpx library with HTTP/2 support
RUN pip3 install --break-system-packages "httpx[http2]"

# Install Go for building h2spec
RUN apk add --no-cache go

# Build h2spec from source for ARM64 compatibility
RUN git clone https://github.com/summerwind/h2spec.git /tmp/h2spec && \
    cd /tmp/h2spec && \
    git checkout v2.6.0 && \
    go build -o /usr/local/bin/h2spec cmd/h2spec/h2spec.go && \
    chmod +x /usr/local/bin/h2spec && \
    rm -rf /tmp/h2spec

# Verify installations
RUN python3 -c "import httpx; print('httpx installed')" && \
    h2spec --version && \
    node --version

# Copy application files
COPY --from=builder /app /app

# Install ameba for linting
RUN git clone https://github.com/crystal-ameba/ameba.git /tmp/ameba && \
    cd /tmp/ameba && \
    make && \
    make install && \
    rm -rf /tmp/ameba

# Set default command to run tests
CMD ["crystal", "spec"]