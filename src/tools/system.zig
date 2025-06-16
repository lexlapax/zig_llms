// ABOUTME: System information tool for gathering OS, hardware, and environment details
// ABOUTME: Provides comprehensive system inspection capabilities with safety controls

const std = @import("std");
const builtin = @import("builtin");
const tool = @import("../tool.zig");
const Tool = tool.Tool;
const ToolMetadata = tool.ToolMetadata;
const ToolResult = tool.ToolResult;
const BaseTool = tool.BaseTool;

// System information categories
pub const SystemInfoType = enum {
    os,
    hardware,
    memory,
    cpu,
    disk,
    network,
    environment,
    processes,
    uptime,
    load,

    pub fn toString(self: SystemInfoType) []const u8 {
        return @tagName(self);
    }
};

// System tool error types
pub const SystemToolError = error{
    UnsupportedPlatform,
    PermissionDenied,
    InformationUnavailable,
    UnsafeOperation,
};

// Safety configuration
pub const SystemSafetyConfig = struct {
    allow_process_info: bool = false,
    allow_network_info: bool = true,
    allow_hardware_info: bool = true,
    allow_environment_vars: bool = false,
    blocked_env_vars: []const []const u8 = &[_][]const u8{ "PATH", "HOME", "USER" },
    read_only: bool = true,
};

// System information structures
pub const OSInfo = struct {
    name: []const u8,
    version: []const u8,
    arch: []const u8,
    platform: []const u8,
    kernel_version: ?[]const u8,
};

pub const MemoryInfo = struct {
    total_bytes: u64,
    available_bytes: u64,
    used_bytes: u64,
    free_bytes: u64,
    usage_percent: f64,
};

pub const CPUInfo = struct {
    model: []const u8,
    cores: u32,
    logical_cores: u32,
    architecture: []const u8,
    frequency_mhz: ?u32,
    cache_size_kb: ?u32,
};

pub const DiskInfo = struct {
    path: []const u8,
    total_bytes: u64,
    available_bytes: u64,
    used_bytes: u64,
    usage_percent: f64,
    filesystem: []const u8,
};

pub const ProcessInfo = struct {
    pid: u32,
    name: []const u8,
    cpu_percent: f64,
    memory_bytes: u64,
    status: []const u8,
};

// System information tool
pub const SystemTool = struct {
    base: BaseTool,
    safety_config: SystemSafetyConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, safety_config: SystemSafetyConfig) !*SystemTool {
        const self = try allocator.create(SystemTool);

        // Create tool metadata
        const metadata = ToolMetadata{
            .name = "system_info",
            .description = "Get system information including OS, hardware, and resource usage",
            .version = "1.0.0",
            .category = .system,
            .capabilities = &[_][]const u8{ "os_info", "hardware_info", "resource_monitoring" },
            .input_schema = try createInputSchema(allocator),
            .output_schema = try createOutputSchema(allocator),
            .examples = &[_]ToolMetadata.Example{
                .{
                    .description = "Get OS information",
                    .input = .{ .object = try createExampleInput(allocator, "os") },
                    .output = .{ .object = try createExampleOutput(allocator, true, "OS info retrieved") },
                },
                .{
                    .description = "Get memory usage",
                    .input = .{ .object = try createExampleInput(allocator, "memory") },
                    .output = .{ .object = try createExampleOutput(allocator, true, "Memory info retrieved") },
                },
            },
        };

        self.* = .{
            .base = BaseTool.init(metadata),
            .safety_config = safety_config,
            .allocator = allocator,
        };

        // Set vtable
        self.base.tool.vtable = &.{
            .execute = execute,
            .validate = validate,
            .deinit = deinit,
        };

        return self;
    }

    fn execute(tool_ptr: *Tool, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        const self = @fieldParentPtr(SystemTool, "base", @fieldParentPtr(BaseTool, "tool", tool_ptr));

        // Parse input
        const info_type_str = input.object.get("type") orelse return error.MissingType;

        if (info_type_str != .string) {
            return error.InvalidInput;
        }

        const info_type = std.meta.stringToEnum(SystemInfoType, info_type_str.string) orelse {
            return error.InvalidType;
        };

        // Check permissions
        try self.checkPermissions(info_type);

        // Get system information
        return switch (info_type) {
            .os => self.getOSInfo(allocator),
            .hardware => self.getHardwareInfo(allocator),
            .memory => self.getMemoryInfo(allocator),
            .cpu => self.getCPUInfo(allocator),
            .disk => self.getDiskInfo(allocator),
            .network => self.getNetworkInfo(allocator),
            .environment => self.getEnvironmentInfo(allocator),
            .processes => self.getProcessInfo(allocator),
            .uptime => self.getUptimeInfo(allocator),
            .load => self.getLoadInfo(allocator),
        };
    }

    fn validate(tool_ptr: *Tool, input: std.json.Value, allocator: std.mem.Allocator) !bool {
        _ = tool_ptr;
        _ = allocator;

        // Basic validation
        if (input != .object) return false;

        const info_type = input.object.get("type") orelse return false;

        if (info_type != .string) return false;

        // Validate info type is valid
        const system_info_type = std.meta.stringToEnum(SystemInfoType, info_type.string) orelse return false;
        _ = system_info_type;

        return true;
    }

    fn deinit(tool_ptr: *Tool) void {
        const self = @fieldParentPtr(SystemTool, "base", @fieldParentPtr(BaseTool, "tool", tool_ptr));
        self.allocator.destroy(self);
    }

    fn checkPermissions(self: *const SystemTool, info_type: SystemInfoType) !void {
        switch (info_type) {
            .processes => {
                if (!self.safety_config.allow_process_info) {
                    return SystemToolError.UnsafeOperation;
                }
            },
            .network => {
                if (!self.safety_config.allow_network_info) {
                    return SystemToolError.UnsafeOperation;
                }
            },
            .hardware, .cpu => {
                if (!self.safety_config.allow_hardware_info) {
                    return SystemToolError.UnsafeOperation;
                }
            },
            .environment => {
                if (!self.safety_config.allow_environment_vars) {
                    return SystemToolError.UnsafeOperation;
                }
            },
            else => {},
        }
    }

    fn getOSInfo(self: *const SystemTool, allocator: std.mem.Allocator) !ToolResult {
        _ = self;

        const os_name = switch (builtin.os.tag) {
            .linux => "Linux",
            .windows => "Windows",
            .macos => "macOS",
            .freebsd => "FreeBSD",
            .openbsd => "OpenBSD",
            .netbsd => "NetBSD",
            else => "Unknown",
        };

        const arch = switch (builtin.cpu.arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            .arm => "arm",
            .riscv64 => "riscv64",
            else => "unknown",
        };

        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("name", .{ .string = os_name });
        try result_obj.put("architecture", .{ .string = arch });
        try result_obj.put("platform", .{ .string = @tagName(builtin.os.tag) });
        try result_obj.put("endian", .{ .string = @tagName(builtin.cpu.arch.endian()) });

        // Try to get more detailed version info
        if (builtin.os.tag == .linux) {
            if (self.getLinuxVersion(allocator)) |version| {
                try result_obj.put("version", .{ .string = version });
            } else |_| {
                try result_obj.put("version", .{ .string = "unknown" });
            }
        } else {
            try result_obj.put("version", .{ .string = "unknown" });
        }

        return ToolResult.success(.{ .object = result_obj });
    }

    fn getLinuxVersion(self: *const SystemTool, allocator: std.mem.Allocator) ![]const u8 {
        _ = self;

        // Try to read /etc/os-release
        const file = std.fs.openFileAbsolute("/etc/os-release", .{}) catch {
            return "unknown";
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 4096);
        defer allocator.free(content);

        // Parse PRETTY_NAME
        var lines = std.mem.split(u8, content, "\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "PRETTY_NAME=")) {
                const value = line[12..]; // Skip PRETTY_NAME=
                if (value.len > 2 and value[0] == '"' and value[value.len - 1] == '"') {
                    return try allocator.dupe(u8, value[1 .. value.len - 1]);
                } else {
                    return try allocator.dupe(u8, value);
                }
            }
        }

        return "unknown";
    }

    fn getHardwareInfo(self: *const SystemTool, allocator: std.mem.Allocator) !ToolResult {
        _ = self;

        var result_obj = std.json.ObjectMap.init(allocator);

        // Get CPU count
        const cpu_count = std.Thread.getCpuCount() catch 1;
        try result_obj.put("cpu_cores", .{ .integer = @as(i64, @intCast(cpu_count)) });

        // Get page size
        const page_size = std.mem.page_size;
        try result_obj.put("page_size", .{ .integer = @as(i64, @intCast(page_size)) });

        // Platform-specific hardware info
        if (builtin.os.tag == .linux) {
            if (self.getLinuxCPUInfo(allocator)) |cpu_info| {
                try result_obj.put("cpu_model", .{ .string = cpu_info });
            } else |_| {
                try result_obj.put("cpu_model", .{ .string = "unknown" });
            }
        }

        return ToolResult.success(.{ .object = result_obj });
    }

    fn getLinuxCPUInfo(self: *const SystemTool, allocator: std.mem.Allocator) ![]const u8 {
        _ = self;

        const file = std.fs.openFileAbsolute("/proc/cpuinfo", .{}) catch {
            return "unknown";
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 4096);
        defer allocator.free(content);

        // Parse model name
        var lines = std.mem.split(u8, content, "\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "model name")) {
                if (std.mem.indexOf(u8, line, ":")) |colon_idx| {
                    const value = std.mem.trim(u8, line[colon_idx + 1 ..], " \t");
                    return try allocator.dupe(u8, value);
                }
            }
        }

        return "unknown";
    }

    fn getMemoryInfo(self: *const SystemTool, allocator: std.mem.Allocator) !ToolResult {
        _ = self;

        var result_obj = std.json.ObjectMap.init(allocator);

        if (builtin.os.tag == .linux) {
            if (self.getLinuxMemoryInfo(allocator)) |mem_info| {
                try result_obj.put("total_bytes", .{ .integer = @as(i64, @intCast(mem_info.total_bytes)) });
                try result_obj.put("available_bytes", .{ .integer = @as(i64, @intCast(mem_info.available_bytes)) });
                try result_obj.put("used_bytes", .{ .integer = @as(i64, @intCast(mem_info.used_bytes)) });
                try result_obj.put("free_bytes", .{ .integer = @as(i64, @intCast(mem_info.free_bytes)) });
                try result_obj.put("usage_percent", .{ .float = mem_info.usage_percent });
            } else |_| {
                try result_obj.put("error", .{ .string = "Memory information unavailable" });
            }
        } else {
            try result_obj.put("error", .{ .string = "Memory information not supported on this platform" });
        }

        return ToolResult.success(.{ .object = result_obj });
    }

    fn getLinuxMemoryInfo(self: *const SystemTool, allocator: std.mem.Allocator) !MemoryInfo {
        _ = self;

        const file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch {
            return SystemToolError.InformationUnavailable;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 4096);
        defer allocator.free(content);

        var mem_total: u64 = 0;
        var mem_free: u64 = 0;
        var mem_available: u64 = 0;

        var lines = std.mem.split(u8, content, "\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "MemTotal:")) {
                mem_total = self.parseMemoryValue(line) * 1024; // Convert KB to bytes
            } else if (std.mem.startsWith(u8, line, "MemFree:")) {
                mem_free = self.parseMemoryValue(line) * 1024;
            } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
                mem_available = self.parseMemoryValue(line) * 1024;
            }
        }

        const used = mem_total - mem_free;
        const usage_percent = if (mem_total > 0) @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(mem_total)) * 100.0 else 0.0;

        return MemoryInfo{
            .total_bytes = mem_total,
            .available_bytes = if (mem_available > 0) mem_available else mem_free,
            .used_bytes = used,
            .free_bytes = mem_free,
            .usage_percent = usage_percent,
        };
    }

    fn parseMemoryValue(self: *const SystemTool, line: []const u8) u64 {
        _ = self;

        // Find the number in the line
        var i: usize = 0;
        while (i < line.len and !std.ascii.isDigit(line[i])) {
            i += 1;
        }

        var start = i;
        while (i < line.len and std.ascii.isDigit(line[i])) {
            i += 1;
        }

        if (start < i) {
            return std.fmt.parseInt(u64, line[start..i], 10) catch 0;
        }

        return 0;
    }

    fn getCPUInfo(self: *const SystemTool, allocator: std.mem.Allocator) !ToolResult {
        var result_obj = std.json.ObjectMap.init(allocator);

        const cpu_count = std.Thread.getCpuCount() catch 1;
        try result_obj.put("logical_cores", .{ .integer = @as(i64, @intCast(cpu_count)) });
        try result_obj.put("architecture", .{ .string = @tagName(builtin.cpu.arch) });

        if (builtin.os.tag == .linux) {
            if (self.getLinuxCPUInfo(allocator)) |cpu_model| {
                try result_obj.put("model", .{ .string = cpu_model });
            } else |_| {
                try result_obj.put("model", .{ .string = "unknown" });
            }
        } else {
            try result_obj.put("model", .{ .string = "unknown" });
        }

        return ToolResult.success(.{ .object = result_obj });
    }

    fn getDiskInfo(self: *const SystemTool, allocator: std.mem.Allocator) !ToolResult {
        _ = self;

        var result_obj = std.json.ObjectMap.init(allocator);

        // Get current directory disk usage
        if (builtin.os.tag == .linux) {
            if (self.getLinuxDiskInfo(allocator, "/")) |disk_info| {
                try result_obj.put("path", .{ .string = disk_info.path });
                try result_obj.put("total_bytes", .{ .integer = @as(i64, @intCast(disk_info.total_bytes)) });
                try result_obj.put("available_bytes", .{ .integer = @as(i64, @intCast(disk_info.available_bytes)) });
                try result_obj.put("used_bytes", .{ .integer = @as(i64, @intCast(disk_info.used_bytes)) });
                try result_obj.put("usage_percent", .{ .float = disk_info.usage_percent });
                try result_obj.put("filesystem", .{ .string = disk_info.filesystem });
            } else |_| {
                try result_obj.put("error", .{ .string = "Disk information unavailable" });
            }
        } else {
            try result_obj.put("error", .{ .string = "Disk information not supported on this platform" });
        }

        return ToolResult.success(.{ .object = result_obj });
    }

    fn getLinuxDiskInfo(self: *const SystemTool, allocator: std.mem.Allocator, path: []const u8) !DiskInfo {
        _ = self;

        const statvfs = std.os.linux.statvfs;
        var stat: statvfs = undefined;

        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const result = std.os.linux.statfs(path_z, &stat);
        if (std.os.linux.getErrno(result) != .SUCCESS) {
            return SystemToolError.InformationUnavailable;
        }

        const block_size = stat.f_frsize;
        const total_bytes = stat.f_blocks * block_size;
        const available_bytes = stat.f_bavail * block_size;
        const used_bytes = total_bytes - (stat.f_bfree * block_size);
        const usage_percent = if (total_bytes > 0) @as(f64, @floatFromInt(used_bytes)) / @as(f64, @floatFromInt(total_bytes)) * 100.0 else 0.0;

        return DiskInfo{
            .path = path,
            .total_bytes = total_bytes,
            .available_bytes = available_bytes,
            .used_bytes = used_bytes,
            .usage_percent = usage_percent,
            .filesystem = "unknown", // Would need additional parsing
        };
    }

    fn getNetworkInfo(self: *const SystemTool, allocator: std.mem.Allocator) !ToolResult {
        _ = self;

        var result_obj = std.json.ObjectMap.init(allocator);

        // Basic network info - hostname
        var hostname_buf: [256]u8 = undefined;
        if (std.os.gethostname(&hostname_buf)) |hostname_len| {
            const hostname = hostname_buf[0..hostname_len];
            try result_obj.put("hostname", .{ .string = hostname });
        } else |_| {
            try result_obj.put("hostname", .{ .string = "unknown" });
        }

        try result_obj.put("status", .{ .string = "network_info_basic" });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn getEnvironmentInfo(self: *const SystemTool, allocator: std.mem.Allocator) !ToolResult {
        var result_obj = std.json.ObjectMap.init(allocator);

        var env_obj = std.json.ObjectMap.init(allocator);

        // Get safe environment variables
        const safe_vars = [_][]const u8{ "LANG", "LC_ALL", "TERM", "SHELL" };

        for (safe_vars) |var_name| {
            // Check if this var is blocked
            var blocked = false;
            for (self.safety_config.blocked_env_vars) |blocked_var| {
                if (std.mem.eql(u8, var_name, blocked_var)) {
                    blocked = true;
                    break;
                }
            }

            if (!blocked) {
                if (std.os.getenv(var_name)) |value| {
                    try env_obj.put(var_name, .{ .string = value });
                }
            }
        }

        try result_obj.put("environment_variables", .{ .object = env_obj });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn getProcessInfo(self: *const SystemTool, allocator: std.mem.Allocator) !ToolResult {
        _ = self;

        var result_obj = std.json.ObjectMap.init(allocator);

        // Get current process info
        const pid = std.os.linux.getpid();

        try result_obj.put("current_pid", .{ .integer = @as(i64, @intCast(pid)) });
        try result_obj.put("note", .{ .string = "Process enumeration requires elevated permissions" });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn getUptimeInfo(self: *const SystemTool, allocator: std.mem.Allocator) !ToolResult {
        _ = self;

        var result_obj = std.json.ObjectMap.init(allocator);

        if (builtin.os.tag == .linux) {
            if (self.getLinuxUptime(allocator)) |uptime| {
                try result_obj.put("uptime_seconds", .{ .float = uptime });
                try result_obj.put("uptime_hours", .{ .float = uptime / 3600.0 });
                try result_obj.put("uptime_days", .{ .float = uptime / 86400.0 });
            } else |_| {
                try result_obj.put("error", .{ .string = "Uptime information unavailable" });
            }
        } else {
            try result_obj.put("error", .{ .string = "Uptime information not supported on this platform" });
        }

        return ToolResult.success(.{ .object = result_obj });
    }

    fn getLinuxUptime(self: *const SystemTool, allocator: std.mem.Allocator) !f64 {
        _ = self;

        const file = std.fs.openFileAbsolute("/proc/uptime", .{}) catch {
            return SystemToolError.InformationUnavailable;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 256);
        defer allocator.free(content);

        // Parse first number (uptime in seconds)
        var space_idx: usize = 0;
        while (space_idx < content.len and content[space_idx] != ' ') {
            space_idx += 1;
        }

        if (space_idx > 0) {
            return std.fmt.parseFloat(f64, content[0..space_idx]) catch 0.0;
        }

        return 0.0;
    }

    fn getLoadInfo(self: *const SystemTool, allocator: std.mem.Allocator) !ToolResult {
        _ = self;

        var result_obj = std.json.ObjectMap.init(allocator);

        if (builtin.os.tag == .linux) {
            if (self.getLinuxLoadAverage(allocator)) |load| {
                try result_obj.put("load_1min", .{ .float = load[0] });
                try result_obj.put("load_5min", .{ .float = load[1] });
                try result_obj.put("load_15min", .{ .float = load[2] });
            } else |_| {
                try result_obj.put("error", .{ .string = "Load average information unavailable" });
            }
        } else {
            try result_obj.put("error", .{ .string = "Load average information not supported on this platform" });
        }

        return ToolResult.success(.{ .object = result_obj });
    }

    fn getLinuxLoadAverage(self: *const SystemTool, allocator: std.mem.Allocator) ![3]f64 {
        _ = self;

        const file = std.fs.openFileAbsolute("/proc/loadavg", .{}) catch {
            return SystemToolError.InformationUnavailable;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 256);
        defer allocator.free(content);

        // Parse three load average values
        var values: [3]f64 = [_]f64{ 0.0, 0.0, 0.0 };
        var iter = std.mem.split(u8, content, " ");

        for (&values) |*value| {
            if (iter.next()) |token| {
                value.* = std.fmt.parseFloat(f64, token) catch 0.0;
            }
        }

        return values;
    }
};

// Helper functions for schema creation
fn createInputSchema(allocator: std.mem.Allocator) !std.json.Value {
    var schema = std.json.ObjectMap.init(allocator);
    try schema.put("type", .{ .string = "object" });

    var properties = std.json.ObjectMap.init(allocator);

    var type_prop = std.json.ObjectMap.init(allocator);
    try type_prop.put("type", .{ .string = "string" });
    try type_prop.put("enum", .{ .array = std.json.Array.fromOwnedSlice(allocator, try allocator.dupe(std.json.Value, &[_]std.json.Value{
        .{ .string = "os" },
        .{ .string = "hardware" },
        .{ .string = "memory" },
        .{ .string = "cpu" },
        .{ .string = "disk" },
        .{ .string = "network" },
        .{ .string = "environment" },
        .{ .string = "processes" },
        .{ .string = "uptime" },
        .{ .string = "load" },
    })) });
    try type_prop.put("description", .{ .string = "Type of system information to retrieve" });
    try properties.put("type", .{ .object = type_prop });

    try schema.put("properties", .{ .object = properties });
    try schema.put("required", .{ .array = std.json.Array.fromOwnedSlice(allocator, try allocator.dupe(std.json.Value, &[_]std.json.Value{
        .{ .string = "type" },
    })) });

    return .{ .object = schema };
}

fn createOutputSchema(allocator: std.mem.Allocator) !std.json.Value {
    var schema = std.json.ObjectMap.init(allocator);
    try schema.put("type", .{ .string = "object" });

    var properties = std.json.ObjectMap.init(allocator);

    var success_prop = std.json.ObjectMap.init(allocator);
    try success_prop.put("type", .{ .string = "boolean" });
    try properties.put("success", .{ .object = success_prop });

    var data_prop = std.json.ObjectMap.init(allocator);
    try data_prop.put("type", .{ .string = "object" });
    try properties.put("data", .{ .object = data_prop });

    var error_prop = std.json.ObjectMap.init(allocator);
    try error_prop.put("type", .{ .string = "string" });
    try properties.put("error", .{ .object = error_prop });

    try schema.put("properties", .{ .object = properties });

    return .{ .object = schema };
}

fn createExampleInput(allocator: std.mem.Allocator, info_type: []const u8) !std.json.ObjectMap {
    var input = std.json.ObjectMap.init(allocator);
    try input.put("type", .{ .string = info_type });
    return input;
}

fn createExampleOutput(allocator: std.mem.Allocator, success: bool, message: []const u8) !std.json.ObjectMap {
    var output = std.json.ObjectMap.init(allocator);
    try output.put("success", .{ .bool = success });

    var data = std.json.ObjectMap.init(allocator);
    try data.put("message", .{ .string = message });
    try output.put("data", .{ .object = data });

    return output;
}

// Builder function for easy creation
pub fn createSystemTool(allocator: std.mem.Allocator, safety_config: SystemSafetyConfig) !*Tool {
    const system_tool = try SystemTool.init(allocator, safety_config);
    return &system_tool.base.tool;
}

// Tests
test "system tool creation" {
    const allocator = std.testing.allocator;

    const tool_ptr = try createSystemTool(allocator, .{});
    defer tool_ptr.deinit();

    try std.testing.expectEqualStrings("system_info", tool_ptr.metadata.name);
}

test "system tool validation" {
    const allocator = std.testing.allocator;

    const tool_ptr = try createSystemTool(allocator, .{});
    defer tool_ptr.deinit();

    // Valid input
    var valid_input = std.json.ObjectMap.init(allocator);
    defer valid_input.deinit();
    try valid_input.put("type", .{ .string = "os" });

    const valid = try tool_ptr.validate(.{ .object = valid_input }, allocator);
    try std.testing.expect(valid);

    // Invalid input (unsupported type)
    var invalid_input = std.json.ObjectMap.init(allocator);
    defer invalid_input.deinit();
    try invalid_input.put("type", .{ .string = "invalid_type" });

    const invalid = try tool_ptr.validate(.{ .object = invalid_input }, allocator);
    try std.testing.expect(!invalid);
}

test "os info retrieval" {
    const allocator = std.testing.allocator;

    const tool_ptr = try createSystemTool(allocator, .{});
    defer tool_ptr.deinit();

    var input = std.json.ObjectMap.init(allocator);
    defer input.deinit();
    try input.put("type", .{ .string = "os" });

    const result = try tool_ptr.execute(.{ .object = input }, allocator);
    defer if (result.data) |data| {
        switch (data) {
            .object => |obj| obj.deinit(),
            else => {},
        }
    };

    try std.testing.expect(result.success);
    if (result.data) |data| {
        try std.testing.expect(data.object.get("name") != null);
        try std.testing.expect(data.object.get("architecture") != null);
    }
}
