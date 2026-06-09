const std = @import("std");
const dtree = @import("dtree");

const blob = @embedFile("riscv-virt.dtb").*;

fn parsed() dtree.Reader {
    @setEvalBranchQuota(1_000_000);
    return dtree.Reader.initBuffer(&blob) catch unreachable;
}

test "comptime: bake a u32 cell into a constant" {
    @setEvalBranchQuota(1_000_000);
    const timebase = comptime try parsed().findAs(u32, &.{ "", "cpus", "timebase-frequency" });
    try std.testing.expectEqual(@as(u32, 0x989680), timebase);
}

test "comptime: string has its trailing NUL stripped" {
    @setEvalBranchQuota(1_000_000);
    const model = comptime try parsed().findAs([]const u8, &.{ "", "model" });
    try std.testing.expectEqualStrings("riscv-virtio,qemu", model);
}

test "comptime: bool reports presence without erroring" {
    @setEvalBranchQuota(1_000_000);
    try std.testing.expect(comptime try parsed().findAs(bool, &.{ "", "model" }));
    try std.testing.expect(!(comptime try parsed().findAs(bool, &.{ "", "not-a-real-prop" })));
}

test "findAs is strict about integer width" {
    @setEvalBranchQuota(1_000_000);
    try std.testing.expectError(error.WrongSize, comptime parsed().findAs(u32, &.{ "", "model" }));
}

test "runtime: the same parse path works without comptime" {
    const fdt = try dtree.Reader.initBuffer(&blob);
    try std.testing.expectEqual(@as(u32, 0x989680), try fdt.findAs(u32, &.{ "", "cpus", "timebase-frequency" }));
    try std.testing.expectEqualStrings("riscv-virtio,qemu", try fdt.findAs([]const u8, &.{ "", "model" }));
}

test "runtime: find returns the raw big-endian value" {
    const fdt = try dtree.Reader.initBuffer(&blob);
    const raw = try fdt.find(&.{ "", "cpus", "timebase-frequency" });
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x98, 0x96, 0x80 }, raw);
}

test "runtime: writeDts renders the tree" {
    const fdt = try dtree.Reader.initBuffer(&blob);
    var buf: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fdt.writeDts(&writer);
    const out = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "cpus {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "timebase-frequency = <") != null);
}
