# List recipes.
default:
    @just --list

# Debug build into zig-out/bin/den.
build:
    zig build

# Optimized build (safety checks kept).
release:
    zig build -Doptimize=ReleaseSafe

# Unit tests plus the end-to-end test against the real binary.
test:
    zig build test --summary all

# Build for Linux (e.g. just linux aarch64).
linux arch="x86_64":
    zig build -Doptimize=ReleaseSafe -Dtarget={{arch}}-linux-musl --prefix zig-out/linux-{{arch}}

# Format sources.
fmt:
    zig fmt src build.zig build.zig.zon

# Build, then run den with any arguments, e.g. just run apply -f den.yaml
[positional-arguments]
run *args: build
    ./zig-out/bin/den "$@"

# Remove build outputs (keeps downloaded deps in zig-pkg/).
clean:
    rm -rf zig-out .zig-cache
