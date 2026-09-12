const std = @import("std");

pub const string = std.mem.trim(u8, @embedFile("VERSION"), " \t\r\n");

test "version is a SemVer core" {
    try std.testing.expect(string.len > 0);

    const core_end = std.mem.indexOfAny(u8, string, "-+") orelse string.len;
    var parts = std.mem.splitScalar(u8, string[0..core_end], '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        _ = try std.fmt.parseInt(u64, part, 10);
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}
