# Dependencies Directory

This directory contains external dependencies for zig_llms.

## Lua 5.4.6

To set up Lua for the project, run:

```bash
./scripts/setup_lua.sh
```

This will download and extract Lua 5.4.6 source code into `deps/lua-5.4.6/`.

The Lua source is integrated directly into the build process via `build.zig`.

## Building with Lua

After setting up Lua, you can build the project with Lua support:

```bash
# Build with Lua enabled (default)
zig build

# Build without Lua
zig build -Denable-lua=false

# Build with release optimizations
zig build -Doptimize=ReleaseFast
```

## Note

The actual dependency source code is not committed to the repository. 
Run the setup scripts to download the required dependencies.