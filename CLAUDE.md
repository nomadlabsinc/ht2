# Claude Operating Instructions for Crystal Development

Adhere to these principles to ensure a high-quality, performant, and maintainable Crystal app:

1.  **Idiomatic Crystal:**
    *   Follow Crystal's [Coding Style Guide](https://crystal-lang.org/reference/1.16/conventions/coding_style.html) rigorously (e.g., `snake_case` for methods/variables, `PascalCase` for classes/modules, `SCREAMING_SNAKE_CASE` for constants).
    *   Leverage Crystal's concurrency primitives (`Channel`, `Fiber`, `Mutex`) appropriately.
    *   Prioritize type safety; use explicit type annotations where beneficial for clarity or performance, especially in performance-critical paths or public APIs.
    *   Employ `raise` for exceptional conditions and `begin...rescue` for robust error handling.

2.  **Performance Focus:**
    *   Consult Crystal's [Performance Guide](https://crystal-lang.org/reference/1.16/guides/performance.html).
    *   Minimize allocations, especially in hot loops (e.g., frame parsing/serialization, HPACK operations). Reuse buffers where possible.
    *   Optimize byte manipulation: use `IO#read_bytes` and `IO#write_bytes` efficiently. Avoid unnecessary `String` conversions in binary protocols.
    *   Profile frequently using `crystal build --release --no-debug` and tools like `perf` to identify bottlenecks.
    *   Be mindful of fiber context switching overhead; ensure fibers are used strategically for concurrency, not for trivial tasks.
    *   Connection pooling (as noted in development tasks) is a critical performance optimization to minimize TLS handshake and connection overhead.

3.  **HTTP/2 Protocol Performance Optimizations (CRITICAL):**
    *   **Use hash-based lookups instead of linear search** - Replace O(n) operations with O(1) hash lookups, especially in HPACK table operations
    *   **Implement connection health validation** - Check stream capacity and connection state before reusing connections to prevent unnecessary new connections
    *   **Use buffer pooling for frame operations** - Reuse byte buffers to reduce GC pressure during frame serialization/deserialization
    *   **Cache protocol support per host** - Store HTTP/2 vs HTTP/1.1 support information to avoid redundant negotiation attempts
    *   **Optimize fiber usage** - Minimize fiber creation overhead, consider shared fiber pools for high-frequency operations
    *   **Implement adaptive buffer sizing** - Size buffers based on expected data patterns rather than fixed large allocations

4.  **Test-Driven Development (TDD):**
    *   Write tests *before* or concurrently with implementation.
    *   Ensure high unit test coverage for all components.
    *   Develop robust integration tests against real and mock servers.
    *   **Always run tests inside Docker to guarantee deterministic environments.**

5.  **Observability & Debugging:**
    *   Integrate Crystal's `Log` module for structured logging. Define log levels (e.g., `DEBUG`, `INFO`, `WARN`, `ERROR`) and allow configuration via environment variables (e.g., `LOG_LEVEL`).
    *   Utilize `crystal run --runtime-trace` (refer to [Runtime Tracing](https://crystal-lang.org/reference/1.16/guides/runtime_tracing.html)) for debugging concurrency issues.
    *   `tshark` or `Wireshark` are invaluable for inspecting raw TLS and HTTP/2 traffic.

6.  **Security Considerations:**
    *   Ensure proper certificate validation (trust store, SNI). Consider options for custom CA certificates or certificate pinning if required by the application's security posture.
    *   Protect against common HTTP/2 denial-of-service vectors (e.g., `SETTINGS` flood, `PRIORITY` flood, oversized frames).

## 🚨 CRITICAL: Code Quality and Formatting Standards

### Pre-Commit Checklist (MANDATORY)
Before ANY commit, Claude MUST:
1. **Run `crystal tool format`** - Format all Crystal code
2. **Run `crystal tool format --check`** - Verify formatting is correct
3. **Verify trailing newlines** - All files must end with a newline (POSIX compliance)
4. **Check trailing whitespace** - No trailing whitespace allowed
5. **Run `crystal spec`** - Ensure all tests pass

## 📋 Crystal Code Standards

### File Formatting Requirements
- **MUST run `crystal tool format`** before every commit
- **MUST have trailing newlines** on all files for POSIX compliance
- **NO trailing whitespace** - Remove all trailing spaces/tabs
- **Line endings**: Unix-style LF
- **Indentation**: Crystal standard (2 spaces)
- **Maximum line length**: 120 characters

### Type System Requirements
- **ALWAYS prefer explicit types over implicit types**
- **Use type annotations** for all method parameters and return values
- **Use type aliases** to simplify complex method signatures
- **Define clear type aliases** for commonly used complex types

```crystal
# ✅ GOOD: Explicit types with type alias
alias UserData = Hash(String, String | Int32 | Nil)

def process_user(data : UserData) : User
  # implementation
end

# ❌ BAD: Implicit types
def process_user(data)
  # implementation
end
```

### Method Design Guidelines
- **Target 5 lines or less** for most methods
- **Maximum 10 lines** for complex methods (rare exceptions allowed)
- **Extract helper methods** to maintain small method sizes
- **Single Responsibility Principle** - Each method does one thing

```crystal
# ✅ GOOD: Short, focused methods
def calculate_total(items : Array(Item)) : Float64
  validate_items(items)
  sum_prices(items) + calculate_tax(items)
end

private def validate_items(items : Array(Item)) : Nil
  raise ArgumentError.new("Empty items") if items.empty?
end

private def sum_prices(items : Array(Item)) : Float64
  items.sum(&.price)
end
```

### Class Design Guidelines
- **Target 100 lines or less** per class
- **Use modules** to separate concerns
- **Extract service objects** for complex operations
- **Prefer composition over inheritance**

### Ordering Conventions

#### Method Arguments
- **ALWAYS alphabetize arguments** when possible
- **Exception**: Logical grouping takes precedence (e.g., x, y, z coordinates)

```crystal
# ✅ GOOD: Alphabetized arguments
def create_user(
  email : String,
  name : String,
  password : String,
  role : String
) : User
  # implementation
end

# ❌ BAD: Random argument order
def create_user(
  name : String,
  password : String,
  email : String,
  role : String
) : User
  # implementation
end
```

#### Hash and Named Arguments
- **ALWAYS alphabetize hash keys**
- **ALWAYS alphabetize named arguments**

```crystal
# ✅ GOOD: Alphabetized hash keys
config = {
  api_key: "secret",
  host: "localhost",
  port: 3000,
  timeout: 30
}

# ✅ GOOD: Alphabetized named arguments
Client.new(
  api_key: key,
  base_url: url,
  timeout: 30,
  verify_ssl: true
)
```

#### Imports and Requires
- **Alphabetize within logical groups**
- **Group by**: stdlib, shards, local files

```crystal
# ✅ GOOD: Organized and alphabetized imports
# Standard library
require "http"
require "json"
require "uri"

# External shards
require "kemal"
require "pg"

# Local files
require "./config"
require "./models/*"
require "./services/*"
```

[... rest of the existing content remains the same ...]

- **Alphabetize arguments, `require` ordering, and constants in methods and classes wherever possible. Use explicit types for all crystal code.**
```