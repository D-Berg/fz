const std = @import("std");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const tracy = @import("tracy.zig");
const Io = std.Io;

pub fn lowerStringAlloc(gpa: Allocator, ascii_str: []const u8) ![]const u8 {
    const tr = tracy.trace(@src());
    defer tr.end();

    const out = try gpa.alloc(u8, ascii_str.len);
    return lowerString(out, ascii_str);
}

/// SIMD lower ascii string
pub fn lowerString(output: []u8, ascii_str: []const u8) []u8 {
    const tr = tracy.trace(@src());
    defer tr.end();

    assert(output.len >= ascii_str.len);

    var remaining_str = ascii_str[0..];
    var remaining_out = output[0..];
    if (build_options.use_simd) if (comptime std.simd.suggestVectorLength(u8)) |vec_len| {
        const ascii_A: @Vector(vec_len, u8) = @splat('A');
        const ascii_Z: @Vector(vec_len, u8) = @splat('Z' + 1);

        while (remaining_str.len >= vec_len) {
            const chunk: @Vector(vec_len, u8) = remaining_str[0..vec_len].*;

            const is_upper = (chunk >= ascii_A) & (chunk < ascii_Z);

            const mask = @as(@Vector(vec_len, u8), @intFromBool(is_upper)) << @splat(5);

            remaining_out[0..vec_len].* = chunk | mask;

            remaining_str = remaining_str[vec_len..];
            remaining_out = remaining_out[vec_len..];
        }
    };

    for (remaining_str, 0..) |c, i| {
        remaining_out[i] = std.ascii.toLower(c);
    }

    return output[0..ascii_str.len];
}

/// ctrl + char
pub fn ctrl(k: u8) u8 {
    return k & 0x1f;
}

pub const Input = struct {
    len_len: usize,
    lines: []const []const u8,
    data: []const u8,
};

pub fn getInput(gpa: Allocator, in: *Io.Reader) !Input {
    const tr = tracy.trace(@src());
    defer tr.end();

    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();

    _ = try in.streamRemaining(&aw.writer);

    const written = try aw.toOwnedSlice();
    errdefer gpa.free(written);

    const new_line_count = std.mem.count(u8, written, "\n");

    var lines: std.ArrayList([]const u8) = .empty;
    try lines.ensureUnusedCapacity(gpa, new_line_count);
    errdefer lines.deinit(gpa);

    var it = std.mem.splitScalar(u8, written, '\n');

    var len_len: usize = 0;
    while (it.next()) |line| {
        lines.appendAssumeCapacity(line);
        len_len += line.len;
    }

    return .{
        .len_len = len_len,
        .lines = try lines.toOwnedSlice(gpa),
        .data = written,
    };
}

test lowerString {
    var buf: [4096]u8 = undefined;
    const result = lowerString(&buf, "aBcDeFgHiJ/kLmNOPqrst0234+💩!");
    try std.testing.expectEqualStrings("abcdefghij/klmnopqrst0234+💩!", result);

    try std.testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz0123456789thequickbrownfoxjumpsoverthelazydogthequickbrownfoxjumpsoverthelazydogxxxxxxxxxxxxxoooooooooqqqqqqqqqqqqqqqqqqqqaaaaaaaaaaaazzzzzzzzzzzzzzzzzzzzmmmmmmmmmmmmmmmmmmmmabcdefghijabcdefghijklmnopqrstklmnopqrstuvwxyzuvwxyznopqrstnopqrst0123456789abcdefghabcdefghijklmnopijklmnopqrstuvwxyzqrstuvqrstuvwxyzwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz0987654321loremipsumdolorsitametconsecteturadipiscingelitseddoeiusmodtemporincididuntutlaboreetdoloremagnaaliquautenimadminimveniamabcdefghijklmnopqrstuvlmnopqrstuvwxyzxyzxyz0123456789endendendplmoknijbuhvygctfxrdzeswaqplmoknijbuhvygctfxrdzeswaqqwertyqwertyasdfghasdfghzxcvbnzxcvbnmmnnbbvvhggttrrddssffppllkkjjhhggffddaaqqsswweerrttyyuuiioopp0123456789aaaabbbbccccddddeeeeffffgggghhhhiiiijjjjkkkkllllmmmmnnnnooooppppqqqqrrrrssssttttuuuuvvvvwwwwxxxxyyyyzzzzabcdefghijabcdefghijklmnopqrstuvlmnopqrstuvwxyzxyzxyz0123456789loremipsumdolorsitametloremipsumdolorsitametabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzab", lowerString(&buf, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789thequickbrownfoxjumpsoverthelazydogTHEQUICKBROWNFOXJUMPSOVERTHELAZYDOGxXxXxXxXxXxXxOoOoOoOoOqqqqqqqqqqQQQQQQQQQQaaaaaaaaaaaaZZZZZZZZZZzzzzzzzzzzMMMMMMMMMMmmmmmmmmmmABCDEFGHIJabcdefghijKLMNOPQRSTklmnopqrstUVWXYZuvwxyznopqrstNOPQRST0123456789abcdefghABCDEFGHijklmnopIJKLMNOPQRSTUVWXYZqrstuvQRSTUVwxYZwxYZABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0987654321LoremIPSUMDolorSitametconsecteturADIPISCINGelitSedDoEiusmodTemporIncididuntUtLaboreetDoloreMagnaAliquaUTENIMADMINIMVENIAMabcdefghijklmnopqrstuvLMNOPQRSTUVWXYZxyzXYZ0123456789ENDENDENDplmoknijbuhvygctfxrdzeswaqPLMOKNIJBUHVYGCTFXRDZESWAQqwertyQWERTYasdfghASDFGHzxcvbnZXCVBNmMnNbBvVHgGtTrRdDsSfFpPlLkKjJhHgGfFdDaAqQsSwWeErRtTyYuUiIoOpP0123456789AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKKKLLLLMMMMNNNNOOOOPPPPQQQQRRRRSSSSTTTTUUUUVVVVWWWWXXXXYYYYZZZZabcdefghijABCDEFGHIJklmnopqrstuvLMNOPQRSTUVWXYZxyzXYZ0123456789loremipsumdolorsitametLOREMIPSUMDOLORSITAMETabcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyzAB"));
}
