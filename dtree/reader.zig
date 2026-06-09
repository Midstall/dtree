const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Self = @This();

pub const Node = union(enum) {
    begin: Begin,
    end: End,
    prop: Prop,

    pub const Begin = struct {
        depth: usize,
        name: []const u8,

        pub fn format(self: Begin, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll(@typeName(Begin));
            try writer.print("{{ .depth = {d}, .name = \"{s}\" }}", .{
                self.depth,
                self.name,
            });
        }
    };

    pub const End = struct {
        depth: usize,
    };

    pub const Prop = struct {
        depth: usize,
        name: []const u8,
        value: []const u8,

        pub fn format(self: Prop, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll(@typeName(Prop));
            try writer.print("{{ .depth = {d}, .name = \"{s}\", .value = {any} }}", .{
                self.depth,
                self.name,
                self.value,
            });
        }
    };

    pub fn name(self: Node) ?[]const u8 {
        return switch (self) {
            .begin => |b| b.name,
            .end => null,
            .prop => |p| p.name,
        };
    }

    pub fn depth(self: Node) usize {
        return switch (self) {
            .begin => |b| b.depth,
            .end => |e| e.depth,
            .prop => |p| p.depth,
        };
    }
};

pub const NodeIterator = struct {
    reader: *const Self,
    pos: usize = 0,
    depth: usize = 0,
    initPos: usize = 0,
    minDepth: usize = 0,

    pub fn realPos(self: *const NodeIterator) usize {
        return self.pos + self.reader.hdr.off_dt_struct;
    }

    pub fn offset(self: *const NodeIterator) usize {
        return (self.pos + self.reader.hdr.off_dt_struct) - @sizeOf(types.Header);
    }

    pub fn alignTo(self: *NodeIterator, comptime T: type) void {
        self.pos += @sizeOf(T) - 1;
        self.pos &= ~@as(usize, @sizeOf(T) - 1);
    }

    pub fn readBuffer(self: *NodeIterator, buf: []u8) void {
        var i: usize = 0;
        while (i < buf.len) : (i += 1) {
            buf[i] = self.reader.buff[self.offset()];
            self.pos += 1;
        }
    }

    pub fn readBytes(self: *NodeIterator, len: usize) []const u8 {
        const pos = self.offset();
        const value = self.reader.buff[pos..][0..len];
        self.pos += len;
        return value;
    }

    pub fn readInt(self: *NodeIterator, comptime T: type) T {
        const len = @divExact(@typeInfo(T).int.bits, 8);
        const pos = self.offset();
        const value = self.reader.buff[pos..][0..len];
        self.pos += len;
        return std.mem.readInt(T, value, .big);
    }

    pub fn readStruct(self: *NodeIterator, comptime T: type) T {
        var res: [1]T = undefined;
        self.readBuffer(std.mem.sliceAsBytes(res[0..]));
        if (builtin.cpu.arch.endian() != std.builtin.Endian.big) {
            std.mem.byteSwapAllFields(T, &res[0]);
        }
        return res[0];
    }

    pub fn token(self: *NodeIterator) error{InvalidToken}!types.Token {
        return std.enums.fromInt(types.Token, self.readInt(u32)) orelse error.InvalidToken;
    }

    pub fn stringAt(self: *NodeIterator, off: usize) []const u8 {
        const pos = (self.reader.hdr.off_dt_strings + off) - @sizeOf(types.Header);
        const len = std.mem.len(@as([*c]const u8, @ptrCast(self.reader.buff[pos..])));
        return self.reader.buff[pos..(pos + len)];
    }

    pub fn string(self: *NodeIterator) []const u8 {
        const pos = self.offset();
        const len = std.mem.len(@as([*c]const u8, @ptrCast(self.reader.buff[pos..])));
        const str = self.reader.buff[pos..(pos + len)];
        self.pos += len + 1;
        return str;
    }

    pub fn next(self: *NodeIterator) !?Node {
        if (self.depth == self.minDepth and self.pos > self.initPos) return null;

        return switch (try self.token()) {
            .beginNode => blk: {
                self.depth += 1;
                const str = self.string();
                self.alignTo(u32);
                break :blk .{ .begin = .{
                    .name = str,
                    .depth = self.depth - 1,
                } };
            },
            .endNode => blk: {
                self.depth -= 1;
                break :blk .{ .end = .{ .depth = self.depth } };
            },
            .prop => blk: {
                const prop = self.readStruct(types.Prop);
                const name = self.stringAt(prop.name);
                const value = self.readBytes(prop.len);
                self.alignTo(u32);
                break :blk .{ .prop = .{
                    .depth = self.depth,
                    .name = name,
                    .value = value,
                } };
            },
            .nop => null,
            .end => error.InvalidToken,
        };
    }
};

allocator: ?Allocator,
hdr: types.Header,
buff: []const u8,

fn readHeader(bytes: *const [@sizeOf(types.Header)]u8) types.Header {
    var hdr: types.Header = @bitCast(bytes.*);
    if (builtin.cpu.arch.endian() != std.builtin.Endian.big) {
        std.mem.byteSwapAllFields(types.Header, &hdr);
    }
    return hdr;
}

fn finish(allocator: ?Allocator, hdr: types.Header, buff: []const u8) error{ Truncated, OverRead, InvalidToken }!Self {
    const buffSize = hdr.totalsize - @sizeOf(types.Header);
    if (buff.len < buffSize) return error.Truncated;
    if (buff.len > buffSize) return error.OverRead;
    if (std.mem.readInt(u32, buff[(hdr.off_dt_struct - @sizeOf(types.Header))..][0..4], .big) != @intFromEnum(types.Token.beginNode)) return error.InvalidToken;

    return .{
        .allocator = allocator,
        .hdr = hdr,
        .buff = buff,
    };
}

pub fn initBuffer(buff: []const u8) !Self {
    if (buff.len < @sizeOf(types.Header)) return error.Truncated;
    const hdr = readHeader(buff[0..@sizeOf(types.Header)]);
    if (hdr.magic != types.magic) return error.InvalidMagic;
    if (buff.len < hdr.totalsize) return error.Truncated;
    return finish(null, hdr, buff[@sizeOf(types.Header)..hdr.totalsize]);
}

pub fn initReader(alloc: Allocator, reader: *std.Io.Reader) !Self {
    const hdr = readHeader(try reader.takeArray(@sizeOf(types.Header)));
    if (hdr.magic != types.magic) return error.InvalidMagic;

    const buff = try reader.readAlloc(alloc, hdr.totalsize - @sizeOf(types.Header));
    errdefer alloc.free(buff);
    return finish(alloc, hdr, buff);
}

pub fn initFile(alloc: Allocator, io: std.Io, file: std.Io.File) !Self {
    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    return initReader(alloc, &file_reader.interface);
}

pub fn deinit(self: *const Self) void {
    if (self.allocator) |alloc| alloc.free(self.buff);
}

pub fn nodeIterator(self: *const Self) NodeIterator {
    return .{ .reader = self };
}

pub fn writeDts(self: *const Self, writer: anytype) !void {
    var iter = self.nodeIterator();
    while (try iter.next()) |node| {
        for (0..(node.depth() * 2)) |_| try writer.writeByte(' ');

        switch (node) {
            .begin => |b| {
                try writer.writeAll(if (b.name.len == 0) "/" else b.name);
                try writer.writeAll(" {");
            },
            .end => {
                try writer.writeAll("}");
            },
            .prop => |p| {
                try writer.writeAll(p.name);
                try writer.writeAll(" = <");

                for (p.value, 0..) |c, i| {
                    try writer.print("0x{x}", .{c});
                    if (i + 1 < p.value.len) try writer.writeByte(' ');
                }

                try writer.writeByte('>');
            },
        }

        try writer.writeByte('\n');
    }
}

pub fn find(self: *const Self, path: []const []const u8) ![]const u8 {
    var iter = self.nodeIterator();
    var matchDepth: ?usize = null;
    while (try iter.next()) |node| {
        const depth = node.depth();
        if (depth >= path.len) continue;

        const name = node.name() orelse continue;
        const pathItem = path[depth];

        if (!std.mem.eql(u8, name, pathItem)) continue;

        if (node == .begin) {
            matchDepth = depth;
        } else if (node == .end) {
            if (matchDepth) |md| {
                matchDepth = md - 1;
            } else matchDepth = null;
        }

        if ((depth + 1) == path.len and matchDepth != null) {
            if (matchDepth.? == (depth - 1)) {
                if (node == .prop) return node.prop.value;
                return error.UnexpectedBeginOrEnd;
            }
        }
    }
    return error.NotFound;
}

pub fn findLoose(self: *const Self, path: []const []const u8) ![]const u8 {
    var iter = self.nodeIterator();
    var matchDepth: ?usize = null;
    while (try iter.next()) |node| {
        const depth = node.depth();
        if (depth >= path.len) continue;

        const name = node.name() orelse continue;
        const pathItem = path[depth];

        const loose = (path.len - 1) == depth + 1;
        if (loose) {
            if (!std.mem.containsAtLeast(u8, name, 1, pathItem)) continue;
        } else {
            if (!std.mem.eql(u8, name, pathItem)) continue;
        }

        if (node == .begin) {
            matchDepth = depth;
        } else if (node == .end) {
            if (matchDepth) |md| {
                matchDepth = md - 1;
            } else matchDepth = null;
        }

        if ((depth + 1) == path.len and matchDepth != null) {
            if (matchDepth.? == (depth - 1)) {
                if (node == .prop) return node.prop.value;
                return error.UnexpectedBeginOrEnd;
            }
        }
    }
    return error.NotFound;
}

pub fn findAs(self: *const Self, comptime T: type, path: []const []const u8) !T {
    if (T == bool) {
        _ = self.find(path) catch |err| {
            if (err == error.NotFound) return false;
            return err;
        };
        return true;
    }

    return decode(T, try self.find(path));
}

fn decode(comptime T: type, value: []const u8) error{WrongSize}!T {
    return switch (@typeInfo(T)) {
        .int => |info| blk: {
            if (info.signedness != .unsigned) @compileError("findAs only supports unsigned integers, got " ++ @typeName(T));
            const len = @divExact(info.bits, 8);
            if (value.len != len) return error.WrongSize;
            break :blk std.mem.readInt(T, value[0..len], .big);
        },
        .pointer => |info| blk: {
            if (info.size != .slice or info.child != u8) @compileError("findAs only supports []const u8 slices, got " ++ @typeName(T));
            const end = std.mem.indexOfScalar(u8, value, 0) orelse value.len;
            break :blk value[0..end];
        },
        else => @compileError("findAs does not support " ++ @typeName(T)),
    };
}

test "decode reads an unsigned cell big-endian" {
    try std.testing.expectEqual(@as(u32, 0x989680), try decode(u32, &.{ 0x00, 0x98, 0x96, 0x80 }));
    try std.testing.expectEqual(@as(u64, 0x1), try decode(u64, &.{ 0, 0, 0, 0, 0, 0, 0, 1 }));
}

test "decode rejects a mismatched width" {
    try std.testing.expectError(error.WrongSize, decode(u32, &.{ 0x00, 0x98 }));
}

test "decode strips a trailing NUL from a string" {
    try std.testing.expectEqualStrings("ok", try decode([]const u8, "ok\x00"));
    try std.testing.expectEqualStrings("nonul", try decode([]const u8, "nonul"));
}
