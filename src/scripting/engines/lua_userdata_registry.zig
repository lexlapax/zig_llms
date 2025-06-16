// ABOUTME: Enhanced userdata type registry with version checking and compatibility management
// ABOUTME: Provides type safety, version compatibility, and schema evolution for userdata types

const std = @import("std");
const lua = @import("../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptContext = @import("../context.zig").ScriptContext;
const UserdataSystem = @import("lua_userdata_system.zig");

/// Version information for userdata types
pub const TypeVersion = struct {
    major: u16,
    minor: u16,
    patch: u16,

    pub fn init(major: u16, minor: u16, patch: u16) TypeVersion {
        return TypeVersion{ .major = major, .minor = minor, .patch = patch };
    }

    pub fn fromU32(version: u32) TypeVersion {
        return TypeVersion{
            .major = @intCast((version >> 16) & 0xFFFF),
            .minor = @intCast((version >> 8) & 0xFF),
            .patch = @intCast(version & 0xFF),
        };
    }

    pub fn toU32(self: TypeVersion) u32 {
        return (@as(u32, self.major) << 16) | (@as(u32, self.minor) << 8) | @as(u32, self.patch);
    }

    pub fn isCompatible(self: TypeVersion, other: TypeVersion) bool {
        // Compatible if major versions match and this version >= other version
        if (self.major != other.major) return false;

        if (self.minor > other.minor) return true;
        if (self.minor < other.minor) return false;

        return self.patch >= other.patch;
    }

    pub fn compare(self: TypeVersion, other: TypeVersion) std.math.Order {
        if (self.major != other.major) {
            return std.math.order(self.major, other.major);
        }
        if (self.minor != other.minor) {
            return std.math.order(self.minor, other.minor);
        }
        return std.math.order(self.patch, other.patch);
    }

    pub fn format(
        self: TypeVersion,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{}.{}.{}", .{ self.major, self.minor, self.patch });
    }
};

/// Migration function for userdata type upgrades
pub const TypeMigrationFn = *const fn (
    old_data: *anyopaque,
    old_version: TypeVersion,
    new_version: TypeVersion,
    allocator: std.mem.Allocator,
) anyerror!*anyopaque;

/// Enhanced type information with version support
pub const VersionedTypeInfo = struct {
    /// Base type information
    base: UserdataSystem.UserdataTypeInfo,

    /// Type version
    version: TypeVersion,

    /// Minimum compatible version
    min_compatible_version: TypeVersion,

    /// Migration function for version upgrades
    migration_fn: ?TypeMigrationFn = null,

    /// Type schema hash for validation
    schema_hash: u64 = 0,

    /// Whether this type supports version migration
    supports_migration: bool = false,

    /// Custom validation function
    validation_fn: ?*const fn (data: *anyopaque, size: usize) bool = null,

    pub fn init(base: UserdataSystem.UserdataTypeInfo, version: TypeVersion) VersionedTypeInfo {
        return VersionedTypeInfo{
            .base = base,
            .version = version,
            .min_compatible_version = version,
        };
    }

    pub fn isCompatibleWith(self: VersionedTypeInfo, other_version: TypeVersion) bool {
        return self.version.isCompatible(other_version) and
            other_version.compare(self.min_compatible_version) != .lt;
    }

    pub fn needsMigration(self: VersionedTypeInfo, other_version: TypeVersion) bool {
        return self.supports_migration and
            self.version.compare(other_version) == .gt and
            self.isCompatibleWith(other_version);
    }
};

/// Registry errors
pub const RegistryError = error{
    TypeNotFound,
    IncompatibleVersion,
    MigrationFailed,
    InvalidSchema,
    ValidationFailed,
    VersionConflict,
    DuplicateType,
} || std.mem.Allocator.Error;

/// Enhanced userdata type registry with version support
pub const VersionedUserdataRegistry = struct {
    allocator: std.mem.Allocator,
    types: std.StringHashMap(VersionedTypeInfo),
    version_history: std.StringHashMap(std.ArrayList(TypeVersion)),

    pub fn init(allocator: std.mem.Allocator) VersionedUserdataRegistry {
        return VersionedUserdataRegistry{
            .allocator = allocator,
            .types = std.StringHashMap(VersionedTypeInfo).init(allocator),
            .version_history = std.StringHashMap(std.ArrayList(TypeVersion)).init(allocator),
        };
    }

    pub fn deinit(self: *VersionedUserdataRegistry) void {
        // Free type names and version histories
        var type_iter = self.types.iterator();
        while (type_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.types.deinit();

        var history_iter = self.version_history.iterator();
        while (history_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.version_history.deinit();
    }

    /// Register a new versioned type
    pub fn registerVersionedType(self: *VersionedUserdataRegistry, type_info: VersionedTypeInfo) !void {
        const name_copy = try self.allocator.dupe(u8, type_info.base.name);
        errdefer self.allocator.free(name_copy);

        // Check if type already exists
        if (self.types.get(name_copy)) |existing| {
            // Verify compatibility
            if (!existing.isCompatibleWith(type_info.version)) {
                self.allocator.free(name_copy);
                return RegistryError.IncompatibleVersion;
            }

            // Update if this is a newer compatible version
            if (type_info.version.compare(existing.version) == .gt) {
                var updated_info = type_info;
                updated_info.base.name = name_copy;
                try self.types.put(name_copy, updated_info);

                // Update version history
                if (self.version_history.getPtr(name_copy)) |history| {
                    try history.append(type_info.version);
                } else {
                    var new_history = std.ArrayList(TypeVersion).init(self.allocator);
                    try new_history.append(existing.version);
                    try new_history.append(type_info.version);
                    try self.version_history.put(try self.allocator.dupe(u8, name_copy), new_history);
                }
            }
        } else {
            // New type registration
            var info_copy = type_info;
            info_copy.base.name = name_copy;
            try self.types.put(name_copy, info_copy);

            // Initialize version history
            var history = std.ArrayList(TypeVersion).init(self.allocator);
            try history.append(type_info.version);
            try self.version_history.put(try self.allocator.dupe(u8, name_copy), history);
        }
    }

    /// Get type information with version checking
    pub fn getVersionedType(self: *VersionedUserdataRegistry, name: []const u8, required_version: ?TypeVersion) !?VersionedTypeInfo {
        const type_info = self.types.get(name) orelse return null;

        if (required_version) |req_ver| {
            if (!type_info.isCompatibleWith(req_ver)) {
                return RegistryError.IncompatibleVersion;
            }
        }

        return type_info;
    }

    /// Get all versions of a type
    pub fn getVersionHistory(self: *VersionedUserdataRegistry, name: []const u8) ?[]const TypeVersion {
        if (self.version_history.get(name)) |history| {
            return history.items;
        }
        return null;
    }

    /// Check if a type supports a specific version
    pub fn supportsVersion(self: *VersionedUserdataRegistry, name: []const u8, version: TypeVersion) bool {
        const type_info = self.types.get(name) orelse return false;
        return type_info.isCompatibleWith(version);
    }

    /// Migrate userdata from old version to new version
    pub fn migrateUserdata(
        self: *VersionedUserdataRegistry,
        name: []const u8,
        old_data: *anyopaque,
        old_version: TypeVersion,
        target_version: TypeVersion,
    ) !*anyopaque {
        const type_info = self.types.get(name) orelse return RegistryError.TypeNotFound;

        if (!type_info.needsMigration(old_version)) {
            if (type_info.isCompatibleWith(old_version)) {
                return old_data; // No migration needed
            } else {
                return RegistryError.IncompatibleVersion;
            }
        }

        if (type_info.migration_fn) |migrate_fn| {
            return try migrate_fn(old_data, old_version, target_version, self.allocator);
        } else {
            return RegistryError.MigrationFailed;
        }
    }

    /// Validate userdata against its schema
    pub fn validateUserdata(self: *VersionedUserdataRegistry, name: []const u8, data: *anyopaque, size: usize) bool {
        const type_info = self.types.get(name) orelse return false;

        if (type_info.validation_fn) |validate_fn| {
            return validate_fn(data, size);
        }

        // Default validation: check size matches
        return size == type_info.base.size;
    }

    /// Get compatibility matrix for all types
    pub fn getCompatibilityMatrix(self: *VersionedUserdataRegistry, allocator: std.mem.Allocator) !CompatibilityMatrix {
        var matrix = CompatibilityMatrix.init(allocator);

        var iter = self.types.iterator();
        while (iter.next()) |entry| {
            const type_name = entry.key_ptr.*;
            const type_info = entry.value_ptr.*;

            var compatibility_info = TypeCompatibilityInfo{
                .name = try allocator.dupe(u8, type_name),
                .current_version = type_info.version,
                .min_compatible_version = type_info.min_compatible_version,
                .supports_migration = type_info.supports_migration,
                .compatible_versions = std.ArrayList(TypeVersion).init(allocator),
            };

            // Find all compatible versions from history
            if (self.getVersionHistory(type_name)) |history| {
                for (history) |version| {
                    if (type_info.isCompatibleWith(version)) {
                        try compatibility_info.compatible_versions.append(version);
                    }
                }
            }

            try matrix.types.append(compatibility_info);
        }

        return matrix;
    }

    /// Generate type registry statistics
    pub fn getStatistics(self: *VersionedUserdataRegistry) RegistryStatistics {
        var stats = RegistryStatistics{};

        var iter = self.types.iterator();
        while (iter.next()) |entry| {
            const type_info = entry.value_ptr.*;

            stats.total_types += 1;
            if (type_info.supports_migration) stats.types_with_migration += 1;
            if (type_info.validation_fn != null) stats.types_with_validation += 1;

            if (self.getVersionHistory(entry.key_ptr.*)) |history| {
                stats.total_versions += history.len;
                if (history.len > stats.max_versions_per_type) {
                    stats.max_versions_per_type = history.len;
                }
            }
        }

        return stats;
    }
};

/// Type compatibility information
pub const TypeCompatibilityInfo = struct {
    name: []const u8,
    current_version: TypeVersion,
    min_compatible_version: TypeVersion,
    supports_migration: bool,
    compatible_versions: std.ArrayList(TypeVersion),

    pub fn deinit(self: *TypeCompatibilityInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.compatible_versions.deinit();
    }
};

/// Compatibility matrix for all registered types
pub const CompatibilityMatrix = struct {
    types: std.ArrayList(TypeCompatibilityInfo),

    pub fn init(allocator: std.mem.Allocator) CompatibilityMatrix {
        return CompatibilityMatrix{
            .types = std.ArrayList(TypeCompatibilityInfo).init(allocator),
        };
    }

    pub fn deinit(self: *CompatibilityMatrix, allocator: std.mem.Allocator) void {
        for (self.types.items) |*type_info| {
            type_info.deinit(allocator);
        }
        self.types.deinit();
    }
};

/// Registry statistics
pub const RegistryStatistics = struct {
    total_types: usize = 0,
    total_versions: usize = 0,
    types_with_migration: usize = 0,
    types_with_validation: usize = 0,
    max_versions_per_type: usize = 0,

    pub fn getAverageVersionsPerType(self: RegistryStatistics) f64 {
        if (self.total_types == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_versions)) / @as(f64, @floatFromInt(self.total_types));
    }
};

/// Example migration functions
pub const ExampleMigrations = struct {
    /// Simple padding migration for struct size changes
    pub fn paddingMigration(
        old_data: *anyopaque,
        old_version: TypeVersion,
        new_version: TypeVersion,
        allocator: std.mem.Allocator,
    ) !*anyopaque {
        _ = old_version;
        _ = new_version;

        // Example: migrate from smaller struct to larger struct with padding
        const old_ptr: [*]u8 = @ptrCast(old_data);
        const new_data = try allocator.alloc(u8, 32); // Assume new size is 32 bytes

        // Copy old data and zero-pad the rest
        @memcpy(new_data[0..16], old_ptr[0..16]); // Assume old size was 16 bytes
        @memset(new_data[16..], 0);

        return new_data.ptr;
    }

    /// Field reordering migration
    pub fn fieldReorderMigration(
        old_data: *anyopaque,
        old_version: TypeVersion,
        new_version: TypeVersion,
        allocator: std.mem.Allocator,
    ) !*anyopaque {
        _ = old_version;
        _ = new_version;
        _ = allocator;

        // Example: reorder fields in a struct
        // This would need to be customized per specific type
        return old_data; // Placeholder
    }
};

/// Utility functions for type registration
pub const RegistrationUtils = struct {
    /// Register a simple type with version
    pub fn registerSimpleType(
        registry: *VersionedUserdataRegistry,
        comptime T: type,
        name: []const u8,
        version: TypeVersion,
    ) !void {
        const base_info = UserdataSystem.UserdataTypeInfo{
            .name = name,
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
            .destructor = null,
        };

        const versioned_info = VersionedTypeInfo.init(base_info, version);
        try registry.registerVersionedType(versioned_info);
    }

    /// Register a type with migration support
    pub fn registerMigratableType(
        registry: *VersionedUserdataRegistry,
        comptime T: type,
        name: []const u8,
        version: TypeVersion,
        min_compatible: TypeVersion,
        migration_fn: TypeMigrationFn,
    ) !void {
        const base_info = UserdataSystem.UserdataTypeInfo{
            .name = name,
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
            .destructor = null,
        };

        var versioned_info = VersionedTypeInfo.init(base_info, version);
        versioned_info.min_compatible_version = min_compatible;
        versioned_info.migration_fn = migration_fn;
        versioned_info.supports_migration = true;

        try registry.registerVersionedType(versioned_info);
    }
};

// Tests
test "TypeVersion operations" {
    const v1 = TypeVersion.init(1, 2, 3);
    const v2 = TypeVersion.init(1, 2, 4);
    const v3 = TypeVersion.init(2, 0, 0);

    // Test version conversion
    try std.testing.expectEqual(v1.toU32(), 0x010203);
    try std.testing.expectEqual(v1, TypeVersion.fromU32(0x010203));

    // Test compatibility
    try std.testing.expect(v2.isCompatible(v1));
    try std.testing.expect(!v1.isCompatible(v2));
    try std.testing.expect(!v3.isCompatible(v1));

    // Test comparison
    try std.testing.expectEqual(std.math.Order.lt, v1.compare(v2));
    try std.testing.expectEqual(std.math.Order.gt, v2.compare(v1));
    try std.testing.expectEqual(std.math.Order.eq, v1.compare(v1));
}

test "VersionedUserdataRegistry basic operations" {
    const allocator = std.testing.allocator;

    var registry = VersionedUserdataRegistry.init(allocator);
    defer registry.deinit();

    // Register a simple type
    try RegistrationUtils.registerSimpleType(&registry, i32, "TestInt", TypeVersion.init(1, 0, 0));

    // Test retrieval
    const type_info = try registry.getVersionedType("TestInt", null);
    try std.testing.expect(type_info != null);
    try std.testing.expectEqual(TypeVersion.init(1, 0, 0), type_info.?.version);

    // Test version compatibility
    const compatible = registry.supportsVersion("TestInt", TypeVersion.init(1, 0, 0));
    try std.testing.expect(compatible);

    const incompatible = registry.supportsVersion("TestInt", TypeVersion.init(0, 9, 0));
    try std.testing.expect(!incompatible);
}

test "Version history tracking" {
    const allocator = std.testing.allocator;

    var registry = VersionedUserdataRegistry.init(allocator);
    defer registry.deinit();

    // Register multiple versions of the same type
    try RegistrationUtils.registerSimpleType(&registry, i32, "EvolvingType", TypeVersion.init(1, 0, 0));
    try RegistrationUtils.registerSimpleType(&registry, i32, "EvolvingType", TypeVersion.init(1, 1, 0));
    try RegistrationUtils.registerSimpleType(&registry, i32, "EvolvingType", TypeVersion.init(1, 2, 0));

    // Check version history
    const history = registry.getVersionHistory("EvolvingType");
    try std.testing.expect(history != null);
    try std.testing.expectEqual(@as(usize, 3), history.?.len);
}

test "Registry statistics" {
    const allocator = std.testing.allocator;

    var registry = VersionedUserdataRegistry.init(allocator);
    defer registry.deinit();

    // Register several types
    try RegistrationUtils.registerSimpleType(&registry, i32, "Type1", TypeVersion.init(1, 0, 0));
    try RegistrationUtils.registerSimpleType(&registry, f64, "Type2", TypeVersion.init(2, 0, 0));

    const stats = registry.getStatistics();
    try std.testing.expectEqual(@as(usize, 2), stats.total_types);
    try std.testing.expect(stats.getAverageVersionsPerType() > 0.0);
}
