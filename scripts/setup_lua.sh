#!/bin/bash
# ABOUTME: Script to download and set up Lua 5.4.6 for zig_llms
# ABOUTME: Downloads Lua source code and prepares it for integration

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration
LUA_VERSION="5.4.6"
LUA_URL="https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz"
DEPS_DIR="deps"
LUA_DIR="${DEPS_DIR}/lua-${LUA_VERSION}"

echo -e "${GREEN}Setting up Lua ${LUA_VERSION} for zig_llms${NC}"

# Create deps directory if it doesn't exist
if [ ! -d "${DEPS_DIR}" ]; then
    echo -e "${YELLOW}Creating deps directory...${NC}"
    mkdir -p "${DEPS_DIR}"
fi

# Check if Lua is already downloaded
if [ -d "${LUA_DIR}" ]; then
    echo -e "${YELLOW}Lua ${LUA_VERSION} already exists in ${LUA_DIR}${NC}"
    echo -e "${GREEN}To re-download, remove the directory first: rm -rf ${LUA_DIR}${NC}"
    exit 0
fi

# Download Lua
echo -e "${YELLOW}Downloading Lua ${LUA_VERSION}...${NC}"
cd "${DEPS_DIR}"
curl -L -O "${LUA_URL}" || wget "${LUA_URL}"

# Extract Lua
echo -e "${YELLOW}Extracting Lua ${LUA_VERSION}...${NC}"
tar -xzf "lua-${LUA_VERSION}.tar.gz"

# Clean up tarball
rm "lua-${LUA_VERSION}.tar.gz"

# Apply any necessary patches for Zig integration
cd "lua-${LUA_VERSION}"

# Create a minimal lua.h wrapper for easier Zig integration
cat > src/lua_zig.h << 'EOF'
#ifndef LUA_ZIG_H
#define LUA_ZIG_H

// This header provides a cleaner interface for Zig integration
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

// Helper macros for common operations
#define LUA_ZIG_VERSION "Lua 5.4.6 for zig_llms"

#endif // LUA_ZIG_H
EOF

cd ../..

echo -e "${GREEN}✓ Lua ${LUA_VERSION} successfully set up in ${LUA_DIR}${NC}"
echo -e "${GREEN}✓ You can now build zig_llms with Lua support${NC}"
echo -e "${YELLOW}Build with: zig build -Denable-lua=true${NC}"