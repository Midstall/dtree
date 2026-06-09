const std = @import("std");
const dtree = @import("dtree");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();

    _ = args.skip();

    const path = args.next() orelse return error.MissingArgument;

    const file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const fdt = try dtree.Reader.initFile(gpa, io, file);
    defer fdt.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try fdt.writeDts(&stdout.interface);
    try stdout.interface.flush();
}
