const std = @import("std");

pub const magic: u32 = 0xd00dfeed;

pub const Header = extern struct {
    magic: u32,
    totalsize: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    off_mem_rsvmap: u32,
    version: u32,
    last_comp_version: u32,
    boot_cpuid_phys: u32,
    size_dt_strings: u32,
    size_dt_struct: u32,

    pub fn format(self: Header, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(@typeName(Header));
        try writer.print("{{ .magic = 0x{x}, .totalsize = {d}, .off_dt_struct = 0x{x}, .off_dt_strings = 0x{x}, .off_mem_rsvmap = 0x{x}, .version = {d}, .last_comp_version = {d}, .boot_cpuid_phys = {d}, .size_dt_strings = {d}, .size_dt_struct = {d} }}", .{
            self.magic,
            self.totalsize,
            self.off_dt_struct,
            self.off_dt_strings,
            self.off_mem_rsvmap,
            self.version,
            self.last_comp_version,
            self.boot_cpuid_phys,
            self.size_dt_strings,
            self.size_dt_struct,
        });
    }
};

pub const ReserveEntry = extern struct {
    address: u64,
    size: u64,
};

pub const Prop = extern struct {
    len: u32,
    name: u32,
};

pub const Token = enum(u32) {
    beginNode = 0x00000001,
    endNode = 0x00000002,
    prop = 0x00000003,
    nop = 0x00000004,
    end = 0x00000009,
};

test "on-disk layouts match the FDT spec" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(Header));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ReserveEntry));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Prop));
}
