//! A package for translating strings with CTranslate2 and SentencePiece models.
const std = @import("std");
const c = @import("wrapper.zig");

/// Translates the given input string and returns the translated output string.
pub fn translate(allocator: std.mem.Allocator, ct2_model_path: []const u8, spm_source_path: []const u8, spm_target_path: []const u8, input: []const u8) ![]u8 {
    const model_dir = try allocator.dupeSentinel(u8, ct2_model_path, 0);
    defer allocator.free(model_dir);

    const source_file = try allocator.dupeSentinel(u8, spm_source_path, 0);
    defer allocator.free(source_file);

    const target_file = try allocator.dupeSentinel(u8, spm_target_path, 0);
    defer allocator.free(target_file);

    const input_sentinel = try allocator.dupeSentinel(u8, input, 0);
    defer allocator.free(input_sentinel);

    const translator: ?*c.TranslatorHandle = c.create_translator(model_dir, source_file, target_file) orelse {
        return error.TranslatorCreationError;
    };
    defer c.destroy_translator(translator);

    const result: [*c]u8 = c.translate(translator, input_sentinel) orelse {
        return error.TranslationError;
    };
    defer c.free_string(result);

    return try allocator.dupe(u8, std.mem.span(result));
}
