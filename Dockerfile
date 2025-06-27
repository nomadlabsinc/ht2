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

# Install h2spec - Download pre-built binary for HTTP/2 conformance testing
RUN curl -L https://github.com/summerwind/h2spec/releases/download/v2.6.0/h2spec_linux_amd64.tar.gz -o h2spec.tar.gz && \
    tar -xzf h2spec.tar.gz && \
    mv h2spec /usr/local/bin/ && \
    chmod +x /usr/local/bin/h2spec && \
    rm h2spec.tar.gz

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