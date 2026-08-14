const std = @import("std");
const text = @import("lenore-text");

const testing = std.testing;

// The build description's own check.
//
// Both libraries are compiled from their own sources here, so what fails if the
// file list or the defines are wrong is the link, and nothing before it: a
// declaration in `src/` is not analysed until something calls it, and the C
// sources are not reached until a symbol from them is. Calling into both is
// what makes that happen at a point a test can report.
//
// The versions are exact on purpose. They are the pins in `build.zig.zon`, so
// this fails when one moves and the pin has to be read rather than assumed;
// a looser assertion would also pass against whatever the system has installed,
// which is the one answer this must not accept.
test "both libraries link, and report the versions they were pinned to" {
    const found = try text.versions();

    try testing.expectEqual(@as(u16, 2), found.freetype_major);
    try testing.expectEqual(@as(u16, 14), found.freetype_minor);
    try testing.expectEqual(@as(u16, 3), found.freetype_patch);
    try testing.expectEqualStrings("14.3.0", found.harfbuzz);
}
