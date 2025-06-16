// ABOUTME: Demonstrates versioned userdata type registry with compatibility checking and migration
// ABOUTME: Shows type evolution, version management, and automatic migration capabilities

const std = @import("std");
const zig_llms = @import("zig_llms");

const lua = @import("zig_llms").bindings.lua;
const ScriptValue = @import("zig_llms").scripting.value_bridge.ScriptValue;
const UserdataRegistry = @import("zig_llms").scripting.engines.lua_userdata_registry;
const VersionedUserdataRegistry = UserdataRegistry.VersionedUserdataRegistry;
const TypeVersion = UserdataRegistry.TypeVersion;
const VersionedTypeInfo = UserdataRegistry.VersionedTypeInfo;
const RegistrationUtils = UserdataRegistry.RegistrationUtils;
const ExampleMigrations = UserdataRegistry.ExampleMigrations;
const UserdataSystem = @import("zig_llms").scripting.engines.lua_userdata_system;

// Example types for demonstration
const PersonV1 = struct {
    name: [32]u8,
    age: u32,
};

const PersonV2 = struct {
    name: [32]u8,
    age: u32,
    email: [64]u8, // New field added in v2
};

const PersonV3 = struct {
    first_name: [32]u8, // Renamed and split from 'name'
    last_name: [32]u8,
    age: u32,
    email: [64]u8,
    phone: [16]u8, // New field in v3
};

// Migration functions
fn migratePersonV1ToV2(
    old_data: *anyopaque,
    old_version: TypeVersion,
    new_version: TypeVersion,
    allocator: std.mem.Allocator,
) !*anyopaque {
    _ = old_version;
    _ = new_version;

    const old_person: *PersonV1 = @ptrCast(@alignCast(old_data));
    const new_person = try allocator.create(PersonV2);

    // Copy existing fields
    new_person.name = old_person.name;
    new_person.age = old_person.age;

    // Initialize new fields with defaults
    @memset(&new_person.email, 0);
    const default_email = "unknown@example.com";
    @memcpy(new_person.email[0..default_email.len], default_email);

    return new_person;
}

fn migratePersonV2ToV3(
    old_data: *anyopaque,
    old_version: TypeVersion,
    new_version: TypeVersion,
    allocator: std.mem.Allocator,
) !*anyopaque {
    _ = old_version;
    _ = new_version;

    const old_person: *PersonV2 = @ptrCast(@alignCast(old_data));
    const new_person = try allocator.create(PersonV3);

    // Split name into first_name and last_name
    const name_str = std.mem.sliceTo(&old_person.name, 0);
    if (std.mem.indexOf(u8, name_str, " ")) |space_idx| {
        // Split at first space
        @memset(&new_person.first_name, 0);
        @memset(&new_person.last_name, 0);

        const first_len = @min(space_idx, 31);
        @memcpy(new_person.first_name[0..first_len], name_str[0..first_len]);

        const last_start = @min(space_idx + 1, name_str.len);
        const last_len = @min(name_str.len - last_start, 31);
        if (last_len > 0) {
            @memcpy(new_person.last_name[0..last_len], name_str[last_start .. last_start + last_len]);
        }
    } else {
        // No space found, use entire name as first name
        @memset(&new_person.first_name, 0);
        @memset(&new_person.last_name, 0);
        @memcpy(new_person.first_name[0..@min(name_str.len, 31)], name_str[0..@min(name_str.len, 31)]);
    }

    // Copy other fields
    new_person.age = old_person.age;
    new_person.email = old_person.email;

    // Initialize new field
    @memset(&new_person.phone, 0);
    const default_phone = "000-000-0000";
    @memcpy(new_person.phone[0..default_phone.len], default_phone);

    return new_person;
}

// Validation functions
fn validatePersonV1(data: *anyopaque, size: usize) bool {
    if (size != @sizeOf(PersonV1)) return false;

    const person: *PersonV1 = @ptrCast(@alignCast(data));

    // Validate that name is null-terminated
    const name_slice = std.mem.sliceTo(&person.name, 0);
    if (name_slice.len == 0 or name_slice.len >= 32) return false;

    // Validate reasonable age range
    return person.age > 0 and person.age < 150;
}

fn validatePersonV2(data: *anyopaque, size: usize) bool {
    if (size != @sizeOf(PersonV2)) return false;

    const person: *PersonV2 = @ptrCast(@alignCast(data));

    // Validate name and age like V1
    const name_slice = std.mem.sliceTo(&person.name, 0);
    if (name_slice.len == 0 or name_slice.len >= 32) return false;
    if (person.age == 0 or person.age >= 150) return false;

    // Validate email format (basic check)
    const email_slice = std.mem.sliceTo(&person.email, 0);
    if (email_slice.len > 0) {
        return std.mem.indexOf(u8, email_slice, "@") != null;
    }

    return true;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Lua Userdata Registry with Version Management Demo ===\\n\\n", .{});

    // Test 1: Basic version operations
    std.debug.print("1. Basic version operations:\\n", .{});

    const v1_0_0 = TypeVersion.init(1, 0, 0);
    const v1_1_0 = TypeVersion.init(1, 1, 0);
    const v2_0_0 = TypeVersion.init(2, 0, 0);

    std.debug.print("  Version 1.0.0: {}\\n", .{v1_0_0});
    std.debug.print("  Version 1.1.0: {}\\n", .{v1_1_0});
    std.debug.print("  Version 2.0.0: {}\\n", .{v2_0_0});

    std.debug.print("  Compatibility checks:\\n", .{});
    std.debug.print("    v1.1.0 compatible with v1.0.0: {}\\n", .{v1_1_0.isCompatible(v1_0_0)});
    std.debug.print("    v1.0.0 compatible with v1.1.0: {}\\n", .{v1_0_0.isCompatible(v1_1_0)});
    std.debug.print("    v2.0.0 compatible with v1.0.0: {}\\n", .{v2_0_0.isCompatible(v1_0_0)});

    // Test 2: Registry setup and type registration
    std.debug.print("\\n2. Registry setup and type registration:\\n", .{});

    var registry = VersionedUserdataRegistry.init(allocator);
    defer registry.deinit();

    // Register PersonV1
    const person_v1_base = UserdataSystem.UserdataTypeInfo{
        .name = "Person",
        .size = @sizeOf(PersonV1),
        .alignment = @alignOf(PersonV1),
        .destructor = null,
    };

    var person_v1_info = VersionedTypeInfo.init(person_v1_base, TypeVersion.init(1, 0, 0));
    person_v1_info.validation_fn = validatePersonV1;
    try registry.registerVersionedType(person_v1_info);
    std.debug.print("  ✓ Registered Person v1.0.0\\n", .{});

    // Register PersonV2 with migration support
    const person_v2_base = UserdataSystem.UserdataTypeInfo{
        .name = "Person",
        .size = @sizeOf(PersonV2),
        .alignment = @alignOf(PersonV2),
        .destructor = null,
    };

    var person_v2_info = VersionedTypeInfo.init(person_v2_base, TypeVersion.init(1, 1, 0));
    person_v2_info.min_compatible_version = TypeVersion.init(1, 0, 0);
    person_v2_info.migration_fn = migratePersonV1ToV2;
    person_v2_info.supports_migration = true;
    person_v2_info.validation_fn = validatePersonV2;
    try registry.registerVersionedType(person_v2_info);
    std.debug.print("  ✓ Registered Person v1.1.0 with migration from v1.0.0\\n", .{});

    // Register PersonV3
    const person_v3_base = UserdataSystem.UserdataTypeInfo{
        .name = "Person",
        .size = @sizeOf(PersonV3),
        .alignment = @alignOf(PersonV3),
        .destructor = null,
    };

    var person_v3_info = VersionedTypeInfo.init(person_v3_base, TypeVersion.init(2, 0, 0));
    person_v3_info.min_compatible_version = TypeVersion.init(1, 1, 0);
    person_v3_info.migration_fn = migratePersonV2ToV3;
    person_v3_info.supports_migration = true;
    try registry.registerVersionedType(person_v3_info);
    std.debug.print("  ✓ Registered Person v2.0.0 with migration from v1.1.0\\n", .{});

    // Test 3: Version history and compatibility
    std.debug.print("\\n3. Version history and compatibility:\\n", .{});

    const history = registry.getVersionHistory("Person");
    if (history) |versions| {
        std.debug.print("  Person type version history ({} versions):\\n", .{versions.len});
        for (versions, 0..) |version, i| {
            std.debug.print("    {}: {}\\n", .{ i + 1, version });
        }
    }

    std.debug.print("  Compatibility checks:\\n", .{});
    const test_versions = [_]TypeVersion{
        TypeVersion.init(1, 0, 0),
        TypeVersion.init(1, 1, 0),
        TypeVersion.init(2, 0, 0),
        TypeVersion.init(3, 0, 0),
    };

    for (test_versions) |test_version| {
        const supports = registry.supportsVersion("Person", test_version);
        std.debug.print("    Supports v{}: {}\\n", .{ test_version, supports });
    }

    // Test 4: Type migration simulation
    std.debug.print("\\n4. Type migration simulation:\\n", .{});

    // Create a PersonV1 instance
    var person_v1 = PersonV1{
        .name = std.mem.zeroes([32]u8),
        .age = 25,
    };
    const name = "John Doe";
    @memcpy(person_v1.name[0..name.len], name);

    std.debug.print("  Original PersonV1:\\n", .{});
    const name_slice = std.mem.sliceTo(&person_v1.name, 0);
    std.debug.print("    Name: {s}\\n", .{name_slice});
    std.debug.print("    Age: {}\\n", .{person_v1.age});

    // Validate original data
    const valid_v1 = registry.validateUserdata("Person", &person_v1, @sizeOf(PersonV1));
    std.debug.print("    Validation: {}\\n", .{if (valid_v1) "✓" else "✗"});

    // Migrate V1 -> V2
    const migrated_v2_ptr = try registry.migrateUserdata(
        "Person",
        &person_v1,
        TypeVersion.init(1, 0, 0),
        TypeVersion.init(1, 1, 0),
    );
    defer allocator.destroy(@as(*PersonV2, @ptrCast(@alignCast(migrated_v2_ptr))));

    const person_v2: *PersonV2 = @ptrCast(@alignCast(migrated_v2_ptr));
    std.debug.print("  Migrated to PersonV2:\\n", .{});
    const v2_name_slice = std.mem.sliceTo(&person_v2.name, 0);
    const v2_email_slice = std.mem.sliceTo(&person_v2.email, 0);
    std.debug.print("    Name: {s}\\n", .{v2_name_slice});
    std.debug.print("    Age: {}\\n", .{person_v2.age});
    std.debug.print("    Email: {s}\\n", .{v2_email_slice});

    // Validate migrated data
    const valid_v2 = registry.validateUserdata("Person", person_v2, @sizeOf(PersonV2));
    std.debug.print("    Validation: {}\\n", .{if (valid_v2) "✓" else "✗"});

    // Migrate V2 -> V3
    const migrated_v3_ptr = try registry.migrateUserdata(
        "Person",
        person_v2,
        TypeVersion.init(1, 1, 0),
        TypeVersion.init(2, 0, 0),
    );
    defer allocator.destroy(@as(*PersonV3, @ptrCast(@alignCast(migrated_v3_ptr))));

    const person_v3: *PersonV3 = @ptrCast(@alignCast(migrated_v3_ptr));
    std.debug.print("  Migrated to PersonV3:\\n", .{});
    const v3_first_name = std.mem.sliceTo(&person_v3.first_name, 0);
    const v3_last_name = std.mem.sliceTo(&person_v3.last_name, 0);
    const v3_email_slice = std.mem.sliceTo(&person_v3.email, 0);
    const v3_phone_slice = std.mem.sliceTo(&person_v3.phone, 0);
    std.debug.print("    First Name: {s}\\n", .{v3_first_name});
    std.debug.print("    Last Name: {s}\\n", .{v3_last_name});
    std.debug.print("    Age: {}\\n", .{person_v3.age});
    std.debug.print("    Email: {s}\\n", .{v3_email_slice});
    std.debug.print("    Phone: {s}\\n", .{v3_phone_slice});

    // Test 5: Compatibility matrix
    std.debug.print("\\n5. Compatibility matrix:\\n", .{});

    var matrix = try registry.getCompatibilityMatrix(allocator);
    defer matrix.deinit(allocator);

    for (matrix.types.items) |type_info| {
        std.debug.print("  Type: {s}\\n", .{type_info.name});
        std.debug.print("    Current version: {}\\n", .{type_info.current_version});
        std.debug.print("    Min compatible: {}\\n", .{type_info.min_compatible_version});
        std.debug.print("    Supports migration: {}\\n", .{type_info.supports_migration});
        std.debug.print("    Compatible versions: [", .{});
        for (type_info.compatible_versions.items, 0..) |version, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{}", .{version});
        }
        std.debug.print("]\\n", .{});
    }

    // Test 6: Registry statistics
    std.debug.print("\\n6. Registry statistics:\\n", .{});

    const stats = registry.getStatistics();
    std.debug.print("  Total types: {}\\n", .{stats.total_types});
    std.debug.print("  Total versions: {}\\n", .{stats.total_versions});
    std.debug.print("  Types with migration: {}\\n", .{stats.types_with_migration});
    std.debug.print("  Types with validation: {}\\n", .{stats.types_with_validation});
    std.debug.print("  Max versions per type: {}\\n", .{stats.max_versions_per_type});
    std.debug.print("  Average versions per type: {d:.1}\\n", .{stats.getAverageVersionsPerType()});

    // Test 7: Error handling
    std.debug.print("\\n7. Error handling:\\n", .{});

    // Try to get non-existent type
    const missing_type = try registry.getVersionedType("NonExistent", null);
    std.debug.print("  Non-existent type lookup: {}\\n", .{if (missing_type == null) "correctly returned null" else "unexpected result"});

    // Try to get incompatible version
    const incompatible_result = registry.getVersionedType("Person", TypeVersion.init(0, 1, 0));
    if (incompatible_result) |_| {
        std.debug.print("  Incompatible version check: failed (should have returned error)\\n", .{});
    } else |err| {
        std.debug.print("  Incompatible version check: correctly returned error {}\\n", .{err});
    }

    // Test 8: Utility functions
    std.debug.print("\\n8. Utility functions:\\n", .{});

    // Register types using utility functions
    try RegistrationUtils.registerSimpleType(&registry, i64, "SimpleInt64", TypeVersion.init(1, 0, 0));
    std.debug.print("  ✓ Registered simple i64 type using utility\\n", .{});

    try RegistrationUtils.registerMigratableType(
        &registry,
        f64,
        "MigratableFloat",
        TypeVersion.init(2, 0, 0),
        TypeVersion.init(1, 0, 0),
        ExampleMigrations.paddingMigration,
    );
    std.debug.print("  ✓ Registered migratable f64 type using utility\\n", .{});

    // Test final statistics
    const final_stats = registry.getStatistics();
    std.debug.print("  Final type count: {}\\n", .{final_stats.total_types});

    std.debug.print("\\n=== Demo Complete ===\\n", .{});
    std.debug.print("\\nKey features demonstrated:\\n", .{});
    std.debug.print("- Semantic versioning with compatibility checking\\n", .{});
    std.debug.print("- Type evolution with automatic migration between versions\\n", .{});
    std.debug.print("- Version history tracking and compatibility matrix\\n", .{});
    std.debug.print("- Data validation with custom validation functions\\n", .{});
    std.debug.print("- Registry statistics and monitoring capabilities\\n", .{});
    std.debug.print("- Error handling for invalid versions and types\\n", .{});
    std.debug.print("- Utility functions for simplified type registration\\n", .{});
    std.debug.print("- Schema evolution from simple types to complex structures\\n", .{});
}
