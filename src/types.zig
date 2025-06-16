// ABOUTME: Core type definitions for the zig_llms library
// ABOUTME: Defines fundamental types like Message, Content, Role used throughout the system

const std = @import("std");

pub const Role = enum {
    system,
    user,
    assistant,
    function,
};

pub const Message = struct {
    role: Role,
    content: Content,
    metadata: ?std.json.Value = null,
};

pub const Content = union(enum) {
    text: []const u8,
    multimodal: []const MultimodalPart,
};

pub const MultimodalPart = union(enum) {
    text: []const u8,
    image: ImageContent,
    file: FileContent,
};

pub const ImageContent = struct {
    data: []const u8, // base64 encoded
    mime_type: []const u8,
};

pub const FileContent = struct {
    path: []const u8,
    mime_type: []const u8,
};

pub const GenerateOptions = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    top_p: ?f32 = null,
    stop_sequences: ?[]const []const u8 = null,
    stream: bool = false,
};

pub const Response = struct {
    content: []const u8,
    usage: ?Usage = null,
    metadata: ?std.json.Value = null,
};

pub const Usage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
};

pub const StreamResponse = struct {
    // TODO: Implement streaming response
};

test "basic types" {
    const msg = Message{
        .role = .user,
        .content = .{ .text = "Hello, world!" },
    };
    try std.testing.expectEqual(Role.user, msg.role);
}
