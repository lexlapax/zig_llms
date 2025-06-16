// ABOUTME: Demonstrates automatic Zig struct serialization to Lua tables with bidirectional conversion
// ABOUTME: Shows reflection-based serialization, field mapping, type validation, and complex nested structures

const std = @import("std");
const zig_llms = @import("zig_llms");

const lua = @import("zig_llms").bindings.lua.lua;
const ScriptValue = @import("zig_llms").scripting.value_bridge.ScriptValue;
const StructSerialization = @import("zig_llms").scripting.engines.lua_struct_serialization;
const StructSerializer = StructSerialization.StructSerializer;
const SerializationOptions = StructSerialization.SerializationOptions;
const FieldNameTransform = StructSerialization.FieldNameTransform;
const StructSerializationUtils = StructSerialization.StructSerializationUtils;

// Example structs for demonstration
const PersonInfo = struct {
    first_name: []const u8,
    last_name: []const u8,
    age: u32,
    email: ?[]const u8 = null,
    is_active: bool = true,
    _internal_id: u64 = 0, // Private field
};

const Address = struct {
    street: []const u8,
    city: []const u8,
    postal_code: []const u8,
    country: []const u8 = "Unknown",
};

const ContactMethod = enum {
    email,
    phone,
    mail,
    in_person,
};

const Preferences = struct {
    theme: []const u8,
    language: []const u8,
    notifications_enabled: bool,
    contact_method: ContactMethod,
    tags: [3][]const u8,
};

const CompleteProfile = struct {
    person: PersonInfo,
    address: Address,
    preferences: ?Preferences = null,
    creation_date: i64,
    metadata: struct {
        version: u32,
        last_updated: i64,
        access_count: u32,
    },
};

// Union example
const DataValue = union(enum) {
    integer: i64,
    floating: f64,
    text: []const u8,
    boolean: bool,
    array: []i32,
};

const DataContainer = struct {
    id: u32,
    name: []const u8,
    value: DataValue,
    optional_value: ?DataValue = null,
};

pub fn main() !void {
    if (!lua.lua_enabled) {
        std.debug.print("Lua support is not enabled. Build with -Denable-lua=true\n", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Lua Struct Serialization Demo ===\n\n", .{});

    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Test 1: Basic struct serialization
    std.debug.print("1. Basic struct serialization:\n", .{});

    const person = PersonInfo{
        .first_name = "John",
        .last_name = "Doe",
        .age = 30,
        .email = "john.doe@example.com",
        .is_active = true,
        ._internal_id = 12345,
    };

    var basic_options = SerializationOptions{
        .include_private_fields = false,
        .field_name_transform = .none,
    };

    try StructSerializer.structToLuaTable(wrapper, PersonInfo, person, basic_options, allocator);

    // Verify the serialized table
    std.debug.print("  Serialized PersonInfo to Lua table:\n", .{});

    // Check each field
    const fields = [_]struct { name: []const u8, lua_type: c_int }{
        .{ .name = "first_name", .lua_type = lua.c.LUA_TSTRING },
        .{ .name = "last_name", .lua_type = lua.c.LUA_TSTRING },
        .{ .name = "age", .lua_type = lua.c.LUA_TNUMBER },
        .{ .name = "email", .lua_type = lua.c.LUA_TSTRING },
        .{ .name = "is_active", .lua_type = lua.c.LUA_TBOOLEAN },
    };

    for (fields) |field| {
        lua.c.lua_getfield(wrapper.state, -1, field.name.ptr);
        const actual_type = lua.c.lua_type(wrapper.state, -1);

        if (actual_type == field.lua_type) {
            switch (actual_type) {
                lua.c.LUA_TSTRING => {
                    const str_val = lua.c.lua_tostring(wrapper.state, -1);
                    std.debug.print("    {s}: \"{s}\"\n", .{ field.name, str_val });
                },
                lua.c.LUA_TNUMBER => {
                    const num_val = lua.c.lua_tonumber(wrapper.state, -1);
                    std.debug.print("    {s}: {d}\n", .{ field.name, num_val });
                },
                lua.c.LUA_TBOOLEAN => {
                    const bool_val = lua.c.lua_toboolean(wrapper.state, -1) != 0;
                    std.debug.print("    {s}: {}\n", .{ field.name, bool_val });
                },
                else => {},
            }
        }
        lua.c.lua_pop(wrapper.state, 1);
    }

    // Check that private field was excluded
    lua.c.lua_getfield(wrapper.state, -1, "_internal_id");
    const private_field_exists = !lua.c.lua_isnil(wrapper.state, -1);
    lua.c.lua_pop(wrapper.state, 1);
    std.debug.print("    Private field '_internal_id' included: {}\n", .{private_field_exists});

    lua.c.lua_pop(wrapper.state, 1); // Remove table

    // Test 2: Struct deserialization
    std.debug.print("\n2. Struct deserialization:\n", .{});

    // Create a Lua table manually
    lua.c.lua_newtable(wrapper.state);
    lua.c.lua_pushliteral(wrapper.state, "Jane");
    lua.c.lua_setfield(wrapper.state, -2, "first_name");
    lua.c.lua_pushliteral(wrapper.state, "Smith");
    lua.c.lua_setfield(wrapper.state, -2, "last_name");
    lua.c.lua_pushinteger(wrapper.state, 28);
    lua.c.lua_setfield(wrapper.state, -2, "age");
    lua.c.lua_pushnil(wrapper.state); // email is nil
    lua.c.lua_setfield(wrapper.state, -2, "email");
    lua.c.lua_pushboolean(wrapper.state, 0);
    lua.c.lua_setfield(wrapper.state, -2, "is_active");

    const deserialized_person = try StructSerializer.luaTableToStruct(wrapper, PersonInfo, -1, basic_options, allocator);
    defer if (deserialized_person.email) |email| allocator.free(email);
    defer allocator.free(deserialized_person.first_name);
    defer allocator.free(deserialized_person.last_name);

    std.debug.print("  Deserialized PersonInfo from Lua table:\n", .{});
    std.debug.print("    Name: {s} {s}\n", .{ deserialized_person.first_name, deserialized_person.last_name });
    std.debug.print("    Age: {}\n", .{deserialized_person.age});
    std.debug.print("    Email: {?s}\n", .{deserialized_person.email});
    std.debug.print("    Active: {}\n", .{deserialized_person.is_active});

    lua.c.lua_pop(wrapper.state, 1); // Remove table

    // Test 3: Complex nested struct serialization
    std.debug.print("\n3. Complex nested struct serialization:\n", .{});

    const complex_profile = CompleteProfile{
        .person = PersonInfo{
            .first_name = "Alice",
            .last_name = "Johnson",
            .age = 35,
            .email = "alice.johnson@company.com",
            .is_active = true,
            ._internal_id = 54321,
        },
        .address = Address{
            .street = "123 Main St",
            .city = "Springfield",
            .postal_code = "12345",
            .country = "USA",
        },
        .preferences = Preferences{
            .theme = "dark",
            .language = "en",
            .notifications_enabled = true,
            .contact_method = .email,
            .tags = [_][]const u8{ "premium", "developer", "beta-tester" },
        },
        .creation_date = std.time.timestamp(),
        .metadata = .{
            .version = 2,
            .last_updated = std.time.timestamp(),
            .access_count = 42,
        },
    };

    var nested_options = SerializationOptions{
        .include_private_fields = false,
        .max_depth = 5,
        .field_name_transform = .none,
    };

    try StructSerializer.structToLuaTable(wrapper, CompleteProfile, complex_profile, nested_options, allocator);

    std.debug.print("  Serialized CompleteProfile (nested structure):\n", .{});

    // Check nested person data
    lua.c.lua_getfield(wrapper.state, -1, "person");
    if (lua.c.lua_istable(wrapper.state, -1)) {
        lua.c.lua_getfield(wrapper.state, -1, "first_name");
        const name = lua.c.lua_tostring(wrapper.state, -1);
        std.debug.print("    Person name: {s}\n", .{name});
        lua.c.lua_pop(wrapper.state, 1);
    }
    lua.c.lua_pop(wrapper.state, 1);

    // Check nested address data
    lua.c.lua_getfield(wrapper.state, -1, "address");
    if (lua.c.lua_istable(wrapper.state, -1)) {
        lua.c.lua_getfield(wrapper.state, -1, "city");
        const city = lua.c.lua_tostring(wrapper.state, -1);
        std.debug.print("    Address city: {s}\n", .{city});
        lua.c.lua_pop(wrapper.state, 1);
    }
    lua.c.lua_pop(wrapper.state, 1);

    // Check metadata
    lua.c.lua_getfield(wrapper.state, -1, "metadata");
    if (lua.c.lua_istable(wrapper.state, -1)) {
        lua.c.lua_getfield(wrapper.state, -1, "version");
        const version = lua.c.lua_tointeger(wrapper.state, -1);
        std.debug.print("    Metadata version: {}\n", .{version});
        lua.c.lua_pop(wrapper.state, 1);
    }
    lua.c.lua_pop(wrapper.state, 1);

    lua.c.lua_pop(wrapper.state, 1); // Remove main table

    // Test 4: Field name transformation
    std.debug.print("\n4. Field name transformation:\n", .{});

    var transform_options = SerializationOptions{
        .field_name_transform = .snake_to_camel,
    };

    try StructSerializer.structToLuaTable(wrapper, PersonInfo, person, transform_options, allocator);

    std.debug.print("  Snake_case to camelCase transformation:\n", .{});

    const transformed_fields = [_][]const u8{ "firstName", "lastName", "isActive" };
    for (transformed_fields) |field_name| {
        lua.c.lua_getfield(wrapper.state, -1, field_name.ptr);
        const field_exists = !lua.c.lua_isnil(wrapper.state, -1);
        std.debug.print("    Field '{s}' exists: {}\n", .{ field_name, field_exists });
        lua.c.lua_pop(wrapper.state, 1);
    }

    lua.c.lua_pop(wrapper.state, 1); // Remove table

    // Test 5: Union serialization
    std.debug.print("\n5. Union serialization:\n", .{});

    const data_containers = [_]DataContainer{
        DataContainer{
            .id = 1,
            .name = "Integer Data",
            .value = DataValue{ .integer = 42 },
        },
        DataContainer{
            .id = 2,
            .name = "Float Data",
            .value = DataValue{ .floating = 3.14159 },
        },
        DataContainer{
            .id = 3,
            .name = "Text Data",
            .value = DataValue{ .text = "Hello, World!" },
        },
        DataContainer{
            .id = 4,
            .name = "Boolean Data",
            .value = DataValue{ .boolean = true },
        },
    };

    for (data_containers, 0..) |container, i| {
        try StructSerializer.structToLuaTable(wrapper, DataContainer, container, basic_options, allocator);

        std.debug.print("  Container {}: {s}\n", .{ i + 1, container.name });

        // Check the union value
        lua.c.lua_getfield(wrapper.state, -1, "value");
        if (lua.c.lua_istable(wrapper.state, -1)) {
            lua.c.lua_getfield(wrapper.state, -1, "tag");
            const tag = lua.c.lua_tostring(wrapper.state, -1);
            std.debug.print("    Union tag: {s}\n", .{tag});
            lua.c.lua_pop(wrapper.state, 1);

            lua.c.lua_getfield(wrapper.state, -1, "value");
            const value_type = lua.c.lua_type(wrapper.state, -1);
            switch (value_type) {
                lua.c.LUA_TNUMBER => {
                    const num = lua.c.lua_tonumber(wrapper.state, -1);
                    std.debug.print("    Union value: {d}\n", .{num});
                },
                lua.c.LUA_TSTRING => {
                    const str = lua.c.lua_tostring(wrapper.state, -1);
                    std.debug.print("    Union value: \"{s}\"\n", .{str});
                },
                lua.c.LUA_TBOOLEAN => {
                    const bool_val = lua.c.lua_toboolean(wrapper.state, -1) != 0;
                    std.debug.print("    Union value: {}\n", .{bool_val});
                },
                else => {
                    std.debug.print("    Union value type: {}\n", .{value_type});
                },
            }
            lua.c.lua_pop(wrapper.state, 1);
        }
        lua.c.lua_pop(wrapper.state, 1);

        lua.c.lua_pop(wrapper.state, 1); // Remove container table
    }

    // Test 6: Field information extraction
    std.debug.print("\n6. Field information extraction:\n", .{});

    const person_field_info = try StructSerializationUtils.getStructFieldInfo(PersonInfo, allocator);
    defer {
        for (person_field_info) |info| {
            info.deinit(allocator);
        }
        allocator.free(person_field_info);
    }

    std.debug.print("  PersonInfo struct analysis:\n", .{});
    std.debug.print("    Field count: {}\n", .{person_field_info.len});

    for (person_field_info) |field_info| {
        std.debug.print("    Field: {s}\n", .{field_info.name});
        std.debug.print("      Type: {s}\n", .{field_info.type_name});
        std.debug.print("      Optional: {}\n", .{field_info.is_optional});
        std.debug.print("      Has default: {}\n", .{field_info.has_default});
        std.debug.print("      Size: {} bytes\n", .{field_info.size});
        std.debug.print("      Alignment: {} bytes\n", .{field_info.alignment});
        std.debug.print("\n", .{});
    }

    // Test 7: Table validation
    std.debug.print("7. Table structure validation:\n", .{});

    // Create a valid table
    lua.c.lua_newtable(wrapper.state);
    lua.c.lua_pushliteral(wrapper.state, "Valid");
    lua.c.lua_setfield(wrapper.state, -2, "first_name");
    lua.c.lua_pushliteral(wrapper.state, "Person");
    lua.c.lua_setfield(wrapper.state, -2, "last_name");
    lua.c.lua_pushinteger(wrapper.state, 25);
    lua.c.lua_setfield(wrapper.state, -2, "age");
    lua.c.lua_pushboolean(wrapper.state, 1);
    lua.c.lua_setfield(wrapper.state, -2, "is_active");

    var validation_result = try StructSerializationUtils.validateTableStructure(wrapper, PersonInfo, -1, basic_options, allocator);
    defer validation_result.deinit(allocator);

    std.debug.print("  Valid table validation:\n", .{});
    std.debug.print("    Is valid: {}\n", .{validation_result.is_valid});
    std.debug.print("    Error count: {}\n", .{validation_result.errors.len});

    lua.c.lua_pop(wrapper.state, 1); // Remove valid table

    // Create an invalid table (missing required fields)
    lua.c.lua_newtable(wrapper.state);
    lua.c.lua_pushliteral(wrapper.state, "Incomplete");
    lua.c.lua_setfield(wrapper.state, -2, "first_name");
    // Missing last_name, age, is_active

    var invalid_validation = try StructSerializationUtils.validateTableStructure(wrapper, PersonInfo, -1, basic_options, allocator);
    defer invalid_validation.deinit(allocator);

    std.debug.print("  Invalid table validation:\n", .{});
    std.debug.print("    Is valid: {}\n", .{invalid_validation.is_valid});
    std.debug.print("    Error count: {}\n", .{invalid_validation.errors.len});

    for (invalid_validation.errors) |error_msg| {
        std.debug.print("    Error: {s}\n", .{error_msg});
    }

    lua.c.lua_pop(wrapper.state, 1); // Remove invalid table

    // Test 8: Round-trip serialization test
    std.debug.print("\n8. Round-trip serialization test:\n", .{});

    const original_address = Address{
        .street = "456 Oak Avenue",
        .city = "Riverside",
        .postal_code = "67890",
        .country = "Canada",
    };

    // Serialize to Lua
    try StructSerializer.structToLuaTable(wrapper, Address, original_address, basic_options, allocator);

    // Deserialize back to Zig
    const roundtrip_address = try StructSerializer.luaTableToStruct(wrapper, Address, -1, basic_options, allocator);
    defer allocator.free(roundtrip_address.street);
    defer allocator.free(roundtrip_address.city);
    defer allocator.free(roundtrip_address.postal_code);
    defer allocator.free(roundtrip_address.country);

    std.debug.print("  Round-trip test results:\n", .{});
    std.debug.print("    Original street: {s}\n", .{original_address.street});
    std.debug.print("    Roundtrip street: {s}\n", .{roundtrip_address.street});
    std.debug.print("    Streets match: {}\n", .{std.mem.eql(u8, original_address.street, roundtrip_address.street)});

    std.debug.print("    Original city: {s}\n", .{original_address.city});
    std.debug.print("    Roundtrip city: {s}\n", .{roundtrip_address.city});
    std.debug.print("    Cities match: {}\n", .{std.mem.eql(u8, original_address.city, roundtrip_address.city)});

    lua.c.lua_pop(wrapper.state, 1); // Remove table

    // Test 9: Performance benchmarking
    std.debug.print("\n9. Performance benchmarking:\n", .{});

    const benchmark_iterations = 1000;
    var timer = try std.time.Timer.start();

    // Benchmark serialization
    timer.reset();
    for (0..benchmark_iterations) |_| {
        try StructSerializer.structToLuaTable(wrapper, PersonInfo, person, basic_options, allocator);
        lua.c.lua_pop(wrapper.state, 1); // Remove table
    }
    const serialization_time = timer.lap();

    // Benchmark deserialization
    lua.c.lua_newtable(wrapper.state);
    lua.c.lua_pushliteral(wrapper.state, "Benchmark");
    lua.c.lua_setfield(wrapper.state, -2, "first_name");
    lua.c.lua_pushliteral(wrapper.state, "Test");
    lua.c.lua_setfield(wrapper.state, -2, "last_name");
    lua.c.lua_pushinteger(wrapper.state, 30);
    lua.c.lua_setfield(wrapper.state, -2, "age");
    lua.c.lua_pushboolean(wrapper.state, 1);
    lua.c.lua_setfield(wrapper.state, -2, "is_active");

    for (0..benchmark_iterations) |_| {
        const bench_result = try StructSerializer.luaTableToStruct(wrapper, PersonInfo, -1, basic_options, allocator);
        defer allocator.free(bench_result.first_name);
        defer allocator.free(bench_result.last_name);
        defer if (bench_result.email) |email| allocator.free(email);
    }
    const deserialization_time = timer.read();

    lua.c.lua_pop(wrapper.state, 1); // Remove benchmark table

    std.debug.print("  Performance results ({} iterations):\n", .{benchmark_iterations});
    std.debug.print("    Serialization:   {d}ms ({d}μs per operation)\n", .{
        @as(f64, @floatFromInt(serialization_time)) / 1_000_000.0,
        @as(f64, @floatFromInt(serialization_time)) / @as(f64, @floatFromInt(benchmark_iterations)) / 1000.0,
    });
    std.debug.print("    Deserialization: {d}ms ({d}μs per operation)\n", .{
        @as(f64, @floatFromInt(deserialization_time)) / 1_000_000.0,
        @as(f64, @floatFromInt(deserialization_time)) / @as(f64, @floatFromInt(benchmark_iterations)) / 1000.0,
    });

    // Final memory check
    _ = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOLLECT, 0);
    const final_memory = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOUNT, 0);
    std.debug.print("  Final Lua memory: {} KB\n", .{final_memory});

    std.debug.print("\n=== Demo Complete ===\n", .{});
    std.debug.print("\nKey features demonstrated:\n", .{});
    std.debug.print("- Automatic Zig struct to Lua table serialization\n", .{});
    std.debug.print("- Bidirectional conversion with type validation\n", .{});
    std.debug.print("- Complex nested struct handling with depth control\n", .{});
    std.debug.print("- Field name transformation (snake_case ↔ camelCase)\n", .{});
    std.debug.print("- Union type serialization with tag-value pairs\n", .{});
    std.debug.print("- Optional field handling and default value support\n", .{});
    std.debug.print("- Struct field reflection and metadata extraction\n", .{});
    std.debug.print("- Table structure validation with error reporting\n", .{});
    std.debug.print("- Round-trip serialization verification\n", .{});
    std.debug.print("- Performance benchmarking and optimization\n", .{});
}
