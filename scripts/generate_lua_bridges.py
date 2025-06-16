#!/usr/bin/env python3
"""
Generate Lua C function bridge implementations for all remaining API bridges.
This script creates standardized bridge files for the zig_llms Lua integration.
"""

import os
from typing import Dict, List, Tuple

# Bridge configurations: name -> (functions, constants, imports)
BRIDGE_CONFIGS = {
    "provider": {
        "functions": [
            ("chat", "zigllms.provider.chat(messages, options?) -> response"),
            ("configure", "zigllms.provider.configure(provider_id, config) -> success"),
            ("list", "zigllms.provider.list() -> provider_list"),
            ("get", "zigllms.provider.get(provider_id) -> provider_info"),
            ("create", "zigllms.provider.create(config) -> provider_id"),
            ("destroy", "zigllms.provider.destroy(provider_id) -> success"),
            ("stream", "zigllms.provider.stream(messages, callback, options?) -> stream_id"),
            ("get_models", "zigllms.provider.get_models(provider_id) -> model_list"),
        ],
        "constants": [
            ("Type", ["OPENAI", "ANTHROPIC", "COHERE", "LOCAL"]),
            ("Status", ["ACTIVE", "INACTIVE", "ERROR", "INITIALIZING"]),
        ],
        "import_name": "provider",
        "description": "LLM provider access and configuration",
    },
    "event": {
        "functions": [
            ("emit", "zigllms.event.emit(event_name, data) -> success"),
            ("subscribe", "zigllms.event.subscribe(event_name, callback) -> subscription_id"),
            ("unsubscribe", "zigllms.event.unsubscribe(subscription_id) -> success"),
            ("list_subscriptions", "zigllms.event.list_subscriptions() -> subscription_list"),
            ("filter", "zigllms.event.filter(pattern, callback) -> filter_id"),
            ("record", "zigllms.event.record(event_name, duration?) -> recorder_id"),
            ("replay", "zigllms.event.replay(recorder_id, options?) -> success"),
            ("clear", "zigllms.event.clear(event_name?) -> success"),
        ],
        "constants": [
            ("Type", ["SYSTEM", "USER", "AGENT", "TOOL", "WORKFLOW"]),
            ("Priority", ["LOW", "NORMAL", "HIGH", "CRITICAL"]),
        ],
        "import_name": "event",
        "description": "Event emission and subscription",
    },
    "test": {
        "functions": [
            ("create_scenario", "zigllms.test.create_scenario(definition) -> scenario_id"),
            ("run_scenario", "zigllms.test.run_scenario(scenario_id, options?) -> result"),
            ("assert_equals", "zigllms.test.assert_equals(actual, expected, message?) -> success"),
            ("assert_contains", "zigllms.test.assert_contains(haystack, needle, message?) -> success"),
            ("create_mock", "zigllms.test.create_mock(definition) -> mock_id"),
            ("setup_fixture", "zigllms.test.setup_fixture(fixture_data) -> fixture_id"),
            ("run_suite", "zigllms.test.run_suite(suite_definition) -> suite_result"),
            ("get_coverage", "zigllms.test.get_coverage() -> coverage_report"),
        ],
        "constants": [
            ("AssertType", ["EQUALS", "CONTAINS", "MATCHES", "THROWS"]),
            ("MockType", ["FUNCTION", "OBJECT", "SERVICE"]),
        ],
        "import_name": "test",
        "description": "Testing and mocking framework",
    },
    "schema": {
        "functions": [
            ("validate", "zigllms.schema.validate(data, schema) -> validation_result"),
            ("generate", "zigllms.schema.generate(example_data) -> schema"),
            ("coerce", "zigllms.schema.coerce(data, schema) -> coerced_data"),
            ("extract", "zigllms.schema.extract(data, schema) -> extracted_data"),
            ("merge", "zigllms.schema.merge(schema1, schema2) -> merged_schema"),
            ("create", "zigllms.schema.create(definition) -> schema"),
            ("compile", "zigllms.schema.compile(schema_source) -> compiled_schema"),
            ("get_info", "zigllms.schema.get_info(schema) -> schema_info"),
        ],
        "constants": [
            ("Type", ["OBJECT", "ARRAY", "STRING", "NUMBER", "BOOLEAN", "NULL"]),
            ("Format", ["EMAIL", "URI", "DATE", "UUID"]),
        ],
        "import_name": "schema",
        "description": "JSON schema validation and generation",
    },
    "memory": {
        "functions": [
            ("store", "zigllms.memory.store(key, value, options?) -> success"),
            ("retrieve", "zigllms.memory.retrieve(key) -> value"),
            ("delete", "zigllms.memory.delete(key) -> success"),
            ("list_keys", "zigllms.memory.list_keys(pattern?) -> key_list"),
            ("clear", "zigllms.memory.clear() -> success"),
            ("get_stats", "zigllms.memory.get_stats() -> memory_stats"),
            ("persist", "zigllms.memory.persist(path) -> success"),
            ("load", "zigllms.memory.load(path) -> success"),
        ],
        "constants": [
            ("Type", ["SHORT_TERM", "LONG_TERM", "PERSISTENT"]),
            ("Scope", ["GLOBAL", "AGENT", "SESSION"]),
        ],
        "import_name": "memory",
        "description": "Memory management and conversation history",
    },
    "hook": {
        "functions": [
            ("register", "zigllms.hook.register(hook_name, callback, priority?) -> hook_id"),
            ("unregister", "zigllms.hook.unregister(hook_id) -> success"),
            ("execute", "zigllms.hook.execute(hook_name, data) -> hook_results"),
            ("list", "zigllms.hook.list(hook_name?) -> hook_list"),
            ("enable", "zigllms.hook.enable(hook_id) -> success"),
            ("disable", "zigllms.hook.disable(hook_id) -> success"),
            ("get_info", "zigllms.hook.get_info(hook_id) -> hook_info"),
            ("compose", "zigllms.hook.compose(hook_ids, composition_type) -> composed_hook_id"),
        ],
        "constants": [
            ("Type", ["PRE", "POST", "AROUND", "ERROR"]),
            ("Priority", ["HIGHEST", "HIGH", "NORMAL", "LOW", "LOWEST"]),
        ],
        "import_name": "hook",
        "description": "Lifecycle hooks and middleware",
    },
    "output": {
        "functions": [
            ("parse", "zigllms.output.parse(data, format?) -> parsed_data"),
            ("format", "zigllms.output.format(data, target_format) -> formatted_data"),
            ("detect_format", "zigllms.output.detect_format(data) -> format_info"),
            ("validate_format", "zigllms.output.validate_format(data, format) -> validation_result"),
            ("extract_json", "zigllms.output.extract_json(text) -> json_data"),
            ("extract_markdown", "zigllms.output.extract_markdown(text) -> markdown_data"),
            ("recover", "zigllms.output.recover(malformed_data, format) -> recovered_data"),
            ("get_schema", "zigllms.output.get_schema(format) -> format_schema"),
        ],
        "constants": [
            ("Format", ["JSON", "YAML", "XML", "MARKDOWN", "PLAIN"]),
            ("Recovery", ["STRICT", "LENIENT", "BEST_EFFORT"]),
        ],
        "import_name": "output",
        "description": "Output parsing and format detection",
    },
}

def generate_bridge_file(bridge_name: str, config: Dict) -> str:
    """Generate a complete Lua bridge file for the given bridge configuration."""
    
    functions = config["functions"]
    constants = config.get("constants", [])
    import_name = config["import_name"]
    description = config["description"]
    
    # Generate function definitions
    function_defs = []
    function_impls = []
    
    for i, (func_name, func_doc) in enumerate(functions):
        lua_func_name = f"lua{bridge_name.title()}{func_name.title().replace('_', '')}"
        function_defs.append(f'        .{{ .name = "{func_name}", .func = {lua_func_name} }},')
        
        # Generate function implementation
        func_impl = f'''
/// {func_doc}
export fn {lua_func_name}(L: ?*lua.c.lua_State) c_int {{
    const context = LuaAPIBridge.getScriptContext(L) orelse {{
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    }};
    
    // Convert arguments from Lua to ScriptValue
    const arg_count = lua.c.lua_gettop(L);
    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {{
        for (args.items) |*arg| {{
            arg.deinit(context.allocator);
        }}
        args.deinit();
    }};
    
    for (0..@intCast(arg_count)) |i| {{
        const arg_value = LuaValueConverter.pullScriptValue(context.allocator, L, @intCast(i + 1)) catch |err| {{
            return LuaAPIBridge.handleBridgeError(L, err);
        }};
        try args.append(arg_value);
    }}
    
    // Call the bridge function
    const result = {bridge_name.title()}Bridge.{func_name.replace('_', '')}(context, args.items) catch |err| {{
        return LuaAPIBridge.handleBridgeError(L, err);
    }};
    defer result.deinit(context.allocator);
    
    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {{
        return LuaAPIBridge.handleBridgeError(L, err);
    }};
    
    return 1;
}}'''
        function_impls.append(func_impl)
    
    # Generate constants
    constants_code = []
    for const_name, const_values in constants:
        const_block = f'''
    // {const_name} constants
    lua.c.lua_newtable(L);
    '''
        for value in const_values:
            const_block += f'''
    lua.c.lua_pushstring(L, "{value.lower()}");
    lua.c.lua_setfield(L, -2, "{value}");'''
        
        const_block += f'''
    
    lua.c.lua_setfield(L, -2, "{const_name}");'''
        constants_code.append(const_block)
    
    # Generate the complete file
    file_content = f'''// ABOUTME: Lua C function wrappers for {bridge_name.title()} Bridge API
// ABOUTME: Provides Lua access to {description}

const std = @import("std");
const lua = @import("../../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const ScriptValue = @import("../../value_bridge.zig").ScriptValue;
const ScriptContext = @import("../../context.zig").ScriptContext;
const LuaValueConverter = @import("../lua_value_converter.zig");
const LuaAPIBridge = @import("../lua_api_bridge.zig");

// Import the actual {bridge_name} bridge implementation
const {bridge_name.title()}Bridge = @import("../../api_bridges/{bridge_name}_bridge.zig").{bridge_name.title()}Bridge;

// Import zig_llms {bridge_name} API
const {import_name} = @import("../../../{import_name}.zig");

/// Number of functions in this bridge
pub const FUNCTION_COUNT = {len(functions)};

/// {bridge_name.title()} bridge errors specific to Lua integration
pub const Lua{bridge_name.title()}Error = error{{
    Invalid{bridge_name.title()},
    {bridge_name.title()}NotFound,
    InvalidDefinition,
    ExecutionFailed,
}} || LuaAPIBridge.LuaAPIBridgeError;

/// Register all {bridge_name} bridge functions with Lua
pub fn register(wrapper: *LuaWrapper, context: *ScriptContext) LuaAPIBridge.LuaAPIBridgeError!void {{
    LuaAPIBridge.setScriptContext(wrapper.state, context);
    LuaAPIBridge.presizeStack(wrapper, FUNCTION_COUNT + 5);
    
    const functions = [_]struct {{ name: []const u8, func: lua.c.lua_CFunction }} {{
{chr(10).join(function_defs)}
    }};
    
    for (functions) |func| {{
        lua.c.lua_pushcfunction(wrapper.state, func.func);
        lua.c.lua_setfield(wrapper.state, -2, func.name.ptr);
    }}
    
    addConstants(wrapper.state);
    std.log.debug("Registered {{}} {bridge_name} bridge functions", .{{functions.len}});
}}

pub fn cleanup() void {{
    std.log.debug("Cleaning up {bridge_name} bridge resources");
}}

fn addConstants(L: ?*lua.c.lua_State) void {{{chr(10).join(constants_code)}
}}

// Lua C Function Implementations
{chr(10).join(function_impls)}'''

    return file_content

def main():
    """Generate all remaining Lua bridge files."""
    base_dir = "/Users/spuri/projects/lexlapax/zig_llms/src/scripting/engines/lua_bridges"
    
    for bridge_name, config in BRIDGE_CONFIGS.items():
        file_path = f"{base_dir}/{bridge_name}_bridge.zig"
        content = generate_bridge_file(bridge_name, config)
        
        with open(file_path, 'w') as f:
            f.write(content)
        
        print(f"Generated {file_path}")

if __name__ == "__main__":
    main()