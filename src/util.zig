const std = @import("std");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

fn lowerStringAlloc(gpa: Allocator, ascii_str: []const u8) ![]const u8 {
    const out = try gpa.alloc(u8, ascii_str.len);
    lowerString(out, ascii_str);
    return out;
}

fn lowerString(output: []u8, ascii_str: []const u8) []u8 {
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

test lowerString {
    var buf: [4096]u8 = undefined;
    const result = lowerString(&buf, "aBcDeFgHiJ/kLmNOPqrst0234+💩!");
    try std.testing.expectEqualStrings("abcdefghij/klmnopqrst0234+💩!", result);

    try std.testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz0123456789thequickbrownfoxjumpsoverthelazydogthequickbrownfoxjumpsoverthelazydogxxxxxxxxxxxxxoooooooooqqqqqqqqqqqqqqqqqqqqaaaaaaaaaaaazzzzzzzzzzzzzzzzzzzzmmmmmmmmmmmmmmmmmmmmabcdefghijabcdefghijklmnopqrstklmnopqrstuvwxyzuvwxyznopqrstnopqrst0123456789abcdefghabcdefghijklmnopijklmnopqrstuvwxyzqrstuvqrstuvwxyzwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz0987654321loremipsumdolorsitametconsecteturadipiscingelitseddoeiusmodtemporincididuntutlaboreetdoloremagnaaliquautenimadminimveniamabcdefghijklmnopqrstuvlmnopqrstuvwxyzxyzxyz0123456789endendendplmoknijbuhvygctfxrdzeswaqplmoknijbuhvygctfxrdzeswaqqwertyqwertyasdfghasdfghzxcvbnzxcvbnmmnnbbvvhggttrrddssffppllkkjjhhggffddaaqqsswweerrttyyuuiioopp0123456789aaaabbbbccccddddeeeeffffgggghhhhiiiijjjjkkkkllllmmmmnnnnooooppppqqqqrrrrssssttttuuuuvvvvwwwwxxxxyyyyzzzzabcdefghijabcdefghijklmnopqrstuvlmnopqrstuvwxyzxyzxyz0123456789loremipsumdolorsitametloremipsumdolorsitametabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzab", lowerString(&buf, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789thequickbrownfoxjumpsoverthelazydogTHEQUICKBROWNFOXJUMPSOVERTHELAZYDOGxXxXxXxXxXxXxOoOoOoOoOqqqqqqqqqqQQQQQQQQQQaaaaaaaaaaaaZZZZZZZZZZzzzzzzzzzzMMMMMMMMMMmmmmmmmmmmABCDEFGHIJabcdefghijKLMNOPQRSTklmnopqrstUVWXYZuvwxyznopqrstNOPQRST0123456789abcdefghABCDEFGHijklmnopIJKLMNOPQRSTUVWXYZqrstuvQRSTUVwxYZwxYZABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0987654321LoremIPSUMDolorSitametconsecteturADIPISCINGelitSedDoEiusmodTemporIncididuntUtLaboreetDoloreMagnaAliquaUTENIMADMINIMVENIAMabcdefghijklmnopqrstuvLMNOPQRSTUVWXYZxyzXYZ0123456789ENDENDENDplmoknijbuhvygctfxrdzeswaqPLMOKNIJBUHVYGCTFXRDZESWAQqwertyQWERTYasdfghASDFGHzxcvbnZXCVBNmMnNbBvVHgGtTrRdDsSfFpPlLkKjJhHgGfFdDaAqQsSwWeErRtTyYuUiIoOpP0123456789AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKKKLLLLMMMMNNNNOOOOPPPPQQQQRRRRSSSSTTTTUUUUVVVVWWWWXXXXYYYYZZZZabcdefghijABCDEFGHIJklmnopqrstuvLMNOPQRSTUVWXYZxyzXYZ0123456789loremipsumdolorsitametLOREMIPSUMDOLORSITAMETabcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyzAB"));
}
