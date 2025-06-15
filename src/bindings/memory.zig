// ABOUTME: Advanced memory management for C-API with tracking, pooling, and safety features
// ABOUTME: Provides leak detection, allocation tracking, and custom allocators for C clients

const std = @import("std");

// Memory allocation statistics
pub const MemoryStats = struct {
    total_allocated: usize = 0,
    total_freed: usize = 0,
    current_allocated: usize = 0,
    peak_allocated: usize = 0,
    allocation_count: usize = 0,
    free_count: usize = 0,
    leak_count: usize = 0,
    
    pub fn addAllocation(self: *MemoryStats, size: usize) void {
        self.total_allocated += size;
        self.current_allocated += size;
        self.allocation_count += 1;
        
        if (self.current_allocated > self.peak_allocated) {
            self.peak_allocated = self.current_allocated;
        }
    }
    
    pub fn addFree(self: *MemoryStats, size: usize) void {
        self.total_freed += size;
        if (self.current_allocated >= size) {
            self.current_allocated -= size;
        }
        self.free_count += 1;
    }
    
    pub fn updateLeakCount(self: *MemoryStats) void {
        self.leak_count = self.allocation_count - self.free_count;
    }
};

// Allocation record for tracking
const AllocationRecord = struct {
    ptr: [*]u8,
    size: usize,
    timestamp: i64,
    tag: []const u8,
};

// Custom tracking allocator
pub const TrackingAllocator = struct {
    child_allocator: std.mem.Allocator,
    stats: MemoryStats,
    allocations: std.HashMap(usize, AllocationRecord, std.HashMap.AutoContext(usize), 80),
    mutex: std.Thread.Mutex,
    enable_leak_detection: bool,
    max_allocations: usize,
    
    const Self = @This();
    
    pub fn init(child: std.mem.Allocator, enable_leak_detection: bool, max_allocations: usize) Self {
        return Self{
            .child_allocator = child,
            .stats = MemoryStats{},
            .allocations = std.HashMap(usize, AllocationRecord, std.HashMap.AutoContext(usize), 80).init(child),
            .mutex = std.Thread.Mutex{},
            .enable_leak_detection = enable_leak_detection,
            .max_allocations = max_allocations,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Report leaks if detection is enabled
        if (self.enable_leak_detection and self.allocations.count() > 0) {
            std.log.warn("Memory leaks detected: {} allocations not freed", .{self.allocations.count()});
            
            var iter = self.allocations.iterator();
            while (iter.next()) |entry| {
                const record = entry.value_ptr.*;
                std.log.warn("Leaked: {} bytes at 0x{x}, tag: {s}, allocated at: {}", .{
                    record.size, @intFromPtr(record.ptr), record.tag, record.timestamp
                });
            }
        }
        
        self.allocations.deinit();
    }
    
    pub fn allocator(self: *Self) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }
    
    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Check allocation limits
        if (self.allocations.count() >= self.max_allocations) {
            return null;
        }
        
        const result = self.child_allocator.rawAlloc(len, ptr_align, ret_addr);
        if (result) |ptr| {
            self.stats.addAllocation(len);
            
            if (self.enable_leak_detection) {
                const record = AllocationRecord{
                    .ptr = ptr,
                    .size = len,
                    .timestamp = std.time.milliTimestamp(),
                    .tag = "c_api",
                };
                
                self.allocations.put(@intFromPtr(ptr), record) catch {
                    // If we can't track it, still allow the allocation
                    // but warn about it
                    std.log.warn("Failed to track allocation of {} bytes", .{len});
                };
            }
        }
        
        return result;
    }
    
    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const old_len = buf.len;
        const result = self.child_allocator.rawResize(buf, buf_align, new_len, ret_addr);
        
        if (result) {
            if (new_len > old_len) {
                self.stats.addAllocation(new_len - old_len);
            } else {
                self.stats.addFree(old_len - new_len);
            }
            
            // Update tracking record if enabled
            if (self.enable_leak_detection) {
                const ptr_addr = @intFromPtr(buf.ptr);
                if (self.allocations.getPtr(ptr_addr)) |record| {
                    record.size = new_len;
                }
            }
        }
        
        return result;
    }
    
    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.stats.addFree(buf.len);
        
        if (self.enable_leak_detection) {
            const ptr_addr = @intFromPtr(buf.ptr);
            _ = self.allocations.remove(ptr_addr);
        }
        
        self.child_allocator.rawFree(buf, buf_align, ret_addr);
    }
    
    pub fn getStats(self: *Self) MemoryStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var stats = self.stats;
        stats.updateLeakCount();
        return stats;
    }
    
    pub fn getAllocationCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.allocations.count();
    }
};

// Fixed-size memory pool for small allocations
pub const MemoryPool = struct {
    buffer: []u8,
    block_size: usize,
    blocks_per_pool: usize,
    free_blocks: std.ArrayList(usize),
    allocated_blocks: std.ArrayList(bool),
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, block_size: usize, block_count: usize) !Self {
        const buffer = try allocator.alloc(u8, block_size * block_count);
        var free_blocks = std.ArrayList(usize).init(allocator);
        var allocated_blocks = std.ArrayList(bool).init(allocator);
        
        // Initialize all blocks as free
        for (0..block_count) |i| {
            try free_blocks.append(i);
            try allocated_blocks.append(false);
        }
        
        return Self{
            .buffer = buffer,
            .block_size = block_size,
            .blocks_per_pool = block_count,
            .free_blocks = free_blocks,
            .allocated_blocks = allocated_blocks,
            .mutex = std.Thread.Mutex{},
        };
    }
    
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
        self.free_blocks.deinit();
        self.allocated_blocks.deinit();
    }
    
    pub fn allocate(self: *Self) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.free_blocks.items.len == 0) {
            return null; // Pool exhausted
        }
        
        const block_index = self.free_blocks.pop();
        self.allocated_blocks.items[block_index] = true;
        
        const start_offset = block_index * self.block_size;
        return self.buffer[start_offset..start_offset + self.block_size];
    }
    
    pub fn deallocate(self: *Self, ptr: []u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Check if pointer is within our buffer
        const buffer_start = @intFromPtr(self.buffer.ptr);
        const buffer_end = buffer_start + self.buffer.len;
        const ptr_addr = @intFromPtr(ptr.ptr);
        
        if (ptr_addr < buffer_start or ptr_addr >= buffer_end) {
            return false; // Not our memory
        }
        
        // Calculate block index
        const offset = ptr_addr - buffer_start;
        const block_index = offset / self.block_size;
        
        if (block_index >= self.blocks_per_pool or !self.allocated_blocks.items[block_index]) {
            return false; // Invalid or already freed
        }
        
        // Mark as free
        self.allocated_blocks.items[block_index] = false;
        self.free_blocks.append(block_index) catch return false;
        
        return true;
    }
    
    pub fn getUsage(self: *Self) struct { allocated: usize, total: usize } {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var allocated: usize = 0;
        for (self.allocated_blocks.items) |is_allocated| {
            if (is_allocated) allocated += 1;
        }
        
        return .{ .allocated = allocated, .total = self.blocks_per_pool };
    }
};

// Arena allocator wrapper for C-API sessions
pub const SessionArena = struct {
    arena: std.heap.ArenaAllocator,
    session_id: []const u8,
    created_time: i64,
    
    const Self = @This();
    
    pub fn init(child: std.mem.Allocator, session_id: []const u8) Self {
        return Self{
            .arena = std.heap.ArenaAllocator.init(child),
            .session_id = session_id,
            .created_time = std.time.milliTimestamp(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }
    
    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }
    
    pub fn reset(self: *Self) void {
        _ = self.arena.reset(.retain_capacity);
    }
    
    pub fn getAge(self: *const Self) i64 {
        return std.time.milliTimestamp() - self.created_time;
    }
};

// Session manager for C-API clients
pub const SessionManager = struct {
    sessions: std.StringHashMap(*SessionArena),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    max_sessions: usize,
    session_timeout_ms: i64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, max_sessions: usize, timeout_ms: i64) Self {
        return Self{
            .sessions = std.StringHashMap(*SessionArena).init(allocator),
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
            .max_sessions = max_sessions,
            .session_timeout_ms = timeout_ms,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit();
    }
    
    pub fn createSession(self: *Self, session_id: []const u8) !*SessionArena {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Clean up expired sessions first
        self.cleanupExpiredSessions();
        
        if (self.sessions.count() >= self.max_sessions) {
            return error.TooManySessions;
        }
        
        if (self.sessions.contains(session_id)) {
            return error.SessionAlreadyExists;
        }
        
        const session = try self.allocator.create(SessionArena);
        session.* = SessionArena.init(self.allocator, session_id);
        
        const owned_id = try self.allocator.dupe(u8, session_id);
        try self.sessions.put(owned_id, session);
        
        return session;
    }
    
    pub fn getSession(self: *Self, session_id: []const u8) ?*SessionArena {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.sessions.get(session_id);
    }
    
    pub fn destroySession(self: *Self, session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.sessions.fetchRemove(session_id)) |kv| {
            kv.value.deinit();
            self.allocator.destroy(kv.value);
            self.allocator.free(kv.key);
            return true;
        }
        return false;
    }
    
    fn cleanupExpiredSessions(self: *Self) void {
        var expired_sessions = std.ArrayList([]const u8).init(self.allocator);
        defer expired_sessions.deinit();
        
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.getAge() > self.session_timeout_ms) {
                expired_sessions.append(entry.key_ptr.*) catch continue;
            }
        }
        
        for (expired_sessions.items) |session_id| {
            if (self.sessions.fetchRemove(session_id)) |kv| {
                kv.value.deinit();
                self.allocator.destroy(kv.value);
                self.allocator.free(kv.key);
            }
        }
    }
    
    pub fn getSessionCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.count();
    }
};