//! Provides CLI related types and functions for the `VeMT` tool.
const std = @import("std");
const c = @import("wrapper.zig");

const OPUS_REPO = "https://object.pouta.csc.fi/OPUS-MT-models";

const ModelStatus = enum(u2) {
    invalid,
    partial,
    ready
};

const Suggestion = struct {
    pair: []const u8,
    distance: usize,
};

/// Calculates the Levenshtein distance, i.e. similarity between two strings.
fn levenshtein(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !usize {
    const m: usize = a.len;
    const n: usize = b.len;

    var prev: []usize = try allocator.alloc(usize, n + 1);
    defer allocator.free(prev);

    var curr: []usize = try allocator.alloc(usize, n + 1);
    defer allocator.free(curr);

    for (0..n + 1) |j| {
        prev[j] = j;
    }

    for (1..m + 1) |i| {
        curr[0] = i;

        for (1..n + 1) |j| {
            if (a[i - 1] == b[j - 1]) {
                curr[j] = prev[j - 1];
            } else {
                curr[j] = 1 + @min(curr[j - 1], @min(prev[j], prev[j - 1]));
            }
        }
        const temp: []usize = prev;
        prev = curr;
        curr = temp;
    }
    return prev[n];
}

/// Returns the integrity status of the model based on found files.
fn getModelStatus(io: std.Io, model_dir: std.Io.Dir) ModelStatus {
    const has_spms: bool = blk: {
        model_dir.access(io, "source.spm", .{}) catch break :blk false;
        model_dir.access(io, "target.spm", .{}) catch break :blk false;
        break :blk true;
    };

    const has_ct2: bool = blk: {
        const model_subdir: std.Io.Dir = model_dir.openDir(io, "ct2", .{}) catch break :blk false;
        defer model_subdir.close(io);
        break :blk true;
    };
    if (!has_spms and !has_ct2) return .invalid;
    if (!has_spms or !has_ct2) return .partial;

    const model_subdir: std.Io.Dir = model_dir.openDir(io, "ct2", .{}) catch return .partial;
    defer model_subdir.close(io);

    model_subdir.access(io, "config.json", .{}) catch return .partial;
    model_subdir.access(io, "model.bin", .{}) catch return .partial;
    model_subdir.access(io, "shared_vocabulary.json", .{}) catch return .partial;

    return .ready;
}

/// Checks that the language code contains only alphabetic characters and underscores.
fn isValidLanguageCode(code: []const u8) bool {
    for (code) |ch| {
        if (!std.ascii.isAlphabetic(ch) and ch != '_') return false;
    }
    return true;
}

/// Finds and returns a list of suggested models from the index that are similar to the given language codes based on Levenshtein distance.
fn findSimilarLanguagePairs(allocator: std.mem.Allocator, index: []const u8, source: []const u8, target: []const u8) !std.ArrayList(Suggestion) {
    var suggestions: std.ArrayList(Suggestion) = .empty;
    errdefer suggestions.deinit(allocator);

    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(allocator);

    var lines = std.mem.splitScalar(u8, index, '\n');

    while (lines.next()) |line| {
        const slash_index: usize = std.mem.indexOfScalar(u8, line, '/') orelse continue;
        const pair: []const u8 = line[0..slash_index];

        const sep_index: usize = std.mem.indexOfScalar(u8, pair, '-') orelse continue;
        const candidate_source: []const u8 = pair[0..sep_index];
        const candidate_target: []const u8 = pair[sep_index + 1..];
        if (candidate_source.len == 0 or candidate_target.len == 0) continue;

        const duplicate: bool = for (seen.items) |previous| {
            if (std.mem.eql(u8, previous, pair)) break true;
        } else false;

        if (duplicate) continue;

        try seen.append(allocator, pair);

        const source_distance: usize = try levenshtein(allocator, source, candidate_source);
        const target_distance: usize = try levenshtein(allocator, target, candidate_target);
        const distance: usize = source_distance + target_distance;
        if (distance > 3) continue;

        var position: usize = suggestions.items.len;

        for (suggestions.items, 0..) |suggestion, i| {
            if (distance < suggestion.distance) {
                position = i;
                break;
            }
        }

        // Only store the top 5 suggestions
        if (position < 5) {
            try suggestions.insert(allocator, position, .{ .pair = pair, .distance = distance });
            if (suggestions.items.len > 5) _ = suggestions.pop();
        }
    }
    return suggestions;
}

/// Fetches and returns the contents of the index file of the OPUS-MT model repository.
fn fetchModelIndex(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var response: std.Io.Writer.Allocating = std.Io.Writer.Allocating.init(allocator);
    errdefer response.deinit();

    const result: std.http.Client.FetchResult = try client.fetch(.{
        .location = .{ .url = OPUS_REPO ++ "/index.txt" },
        .response_writer = &response.writer
    });
    if (result.status != .ok) return error.IndexDownloadError;

    return try allocator.dupe(u8, response.written());
}

/// Finds and returns a list of models from the index that match the given language codes.
fn findModels(allocator: std.mem.Allocator, index: []const u8, source: []const u8, target: []const u8) !std.ArrayList([]const u8) {
    const prefix: []u8 = try allocator.print("{s}-{s}/opus", .{ source, target });
    defer allocator.free(prefix);

    var models: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, index, '\n');

    while (lines.next()) |line_raw| {
        const line: []const u8 = std.mem.trim(u8, line_raw, " \t\r");
        if (!std.mem.startsWith(u8, line, prefix) or std.mem.endsWith(u8, line, ".eval.zip") or !std.mem.endsWith(u8, line, ".zip")) continue;

        const filename: []const u8 = line[prefix.len..];
        if (filename.len == 0 or (filename[0] != '+' and filename[0] != '-')) continue;

        try models.append(allocator, try allocator.dupe(u8, line));
    }
    if (models.items.len == 0) return error.ModelNotFound;

    return models;
}

/// Prompts the user to select a model from the list of choices.
fn selectModel(io: std.Io, models: std.ArrayList([]const u8)) ![]const u8 {
    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const writer: *std.Io.Writer = &stdout_writer.interface;

    try writer.writeAll("Model selection\n");

    for (models.items, 1..) |model, i| {
        try writer.print("  {d}. {s}\n", .{ i, model });
    }
    try writer.print("Select a model (1-{d}): ", .{ models.items.len });
    try writer.flush();

    var stdin_buffer: [32]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const reader: *std.Io.Reader = &stdin_reader.interface;

    const input: []u8 = try reader.takeDelimiter('\n') orelse return error.EmptyInput;
    const trimmed: []const u8 = std.mem.trim(u8, input, " \t\r");
    const index: usize = try std.fmt.parseInt(usize, trimmed, 10);
    if (index == 0 or index > models.items.len) return error.InvalidSelection;

    return models.items[index - 1];
}

/// Downloads the model from the OPUS-MT model repository.
fn downloadModel(allocator: std.mem.Allocator, io: std.Io, model_path: []const u8, output_path: []const u8) !void {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const url: []u8 = try allocator.print("{s}/{s}", .{ OPUS_REPO, model_path });
    defer allocator.free(url);

    const temporary_path: []u8 = try allocator.print("{s}.part", .{ output_path });
    defer allocator.free(temporary_path);

    const dir: std.Io.Dir = std.Io.Dir.cwd();
    const file: std.Io.File = try dir.createFile(io, temporary_path, .{});
    defer file.close(io);

    var buffer: [1024 * 1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = file.writerStreaming(io, &buffer);
    const writer: *std.Io.Writer = &file_writer.interface;

    const result: std.http.Client.FetchResult = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = writer
    });
    try writer.flush();
    if (result.status != .ok) return error.ModelDownloadError;

    try dir.rename(temporary_path, dir, output_path, io);
}

/// Extracts the downloaded model archive.
fn extractArchive(io: std.Io, archive_path: []const u8, destination: []const u8) !void {
    const dir: std.Io.Dir = std.Io.Dir.cwd();
    
    // Delete an existing archive first
    dir.deleteTree(io, destination) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    try dir.createDirPath(io, destination);

    const archive: std.Io.File = try dir.openFile(io, archive_path, .{});
    defer archive.close(io);

    var buffer: [1024 * 1024]u8 = undefined;
    var reader: std.Io.File.Reader = archive.reader(io, &buffer);

    const dest_dir: std.Io.Dir = try dir.openDir(io, destination, .{});
    defer dest_dir.close(io);

    try std.zip.extract(dest_dir, &reader, .{ .allow_backslashes = true });
}

/// Converts the model to CTranslate2 format via a Python child process.
fn convertModel(io: std.Io, temp_dir: []const u8, output_dir: []const u8, python_path: []const u8, quantization: ?[]const u8) !void {
    const base_argv: [10][]const u8 = .{
        python_path,
        "-W", "ignore::RuntimeWarning",
        "-m", "ctranslate2.converters.opus_mt",
        "--model_dir", temp_dir,
        "--output_dir", output_dir,
        "--force"
    };
    var argv: [12][]const u8 = undefined;

    // Optional argument handling
    @memcpy(argv[0..base_argv.len], &base_argv);
    var argv_len: usize = base_argv.len;

    if (quantization) |value| {
        argv[argv_len] = "--quantization";
        argv[argv_len + 1] = value;
        argv_len += 2;
    }
    var child: std.process.Child = try std.process.spawn(io, .{ .argv = argv[0..argv_len] });
    const result: std.process.Child.Term = try child.wait(io);
    if (!result.success()) return error.ModelConversionError;
}

/// Cleans up the model directory by moving SentencePiece model files, and deleting the archive and temporary directory.
fn finalizeModel(allocator: std.mem.Allocator, io: std.Io, pair_dir: []const u8, temp_dir: []const u8, archive_path: []const u8, partial: bool) !void {
    const old_source_file: []u8 = try allocator.print("{s}/source.spm", .{ temp_dir });
    defer allocator.free(old_source_file);

    const new_source_file: []u8 = try allocator.print("{s}/source.spm", .{ pair_dir });
    defer allocator.free(new_source_file);

    const old_target_file: []u8 = try allocator.print("{s}/target.spm", .{ temp_dir });
    defer allocator.free(old_target_file);

    const new_target_file: []u8 = try allocator.print("{s}/target.spm", .{ pair_dir });
    defer allocator.free(new_target_file);

    const dir: std.Io.Dir = std.Io.Dir.cwd();
    try dir.rename(old_source_file, dir, new_source_file, io);
    try dir.rename(old_target_file, dir, new_target_file, io);

    try dir.deleteFile(io, archive_path);
    if (!partial) try dir.deleteTree(io, temp_dir);
}

/// Writes model related metadata.
fn writeMetadata(allocator: std.mem.Allocator, io: std.Io, model_dir: []const u8, source: []const u8, target: []const u8, model: []const u8, quantization: ?[]const u8) !void {
    const Metadata = struct {
        source_language: []const u8,
        target_language: []const u8,
        model: []const u8,
        quantization: ?[]const u8
    };
    const ext_index: usize = std.mem.lastIndexOfScalar(u8, model, '.') orelse model.len;
    const model_name: []const u8 = model[0..ext_index];

    const metadata: Metadata = .{ .source_language = source, .target_language = target, .model = model_name, .quantization = quantization };
    const json: []u8 = try std.json.Stringify.valueAlloc(allocator, metadata, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    const path: []u8 = try allocator.print("{s}/metadata.json", .{ model_dir });
    defer allocator.free(path);

    const dir: std.Io.Dir = std.Io.Dir.cwd();
    const file: std.Io.File = try dir.createFile(io, path, .{});
    defer file.close(io);

    var buffer: [128]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = file.writerStreaming(io, &buffer);
    const writer: *std.Io.Writer = &stdout_writer.interface;

    try writer.writeAll(json);
    try writer.flush();
}

/// Prints the installed models and their integrity status.
pub fn list(io: std.Io) !void {
    const dir: std.Io.Dir = std.Io.Dir.cwd().openDir(io, "models", .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter: std.Io.Dir.Iterator = dir.iterate();
    
    var buffer: [256]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = std.Io.File.stdout().writer(io, &buffer);
    const writer: *std.Io.Writer = &stdout_writer.interface;

    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        const model_dir: std.Io.Dir = dir.openDir(io, entry.name, .{}) catch continue;
        defer model_dir.close(io);

        const model_status: ModelStatus = getModelStatus(io, model_dir);

        try writer.print("{s} ({s})\n", .{ entry.name, @tagName(model_status)});
    }
    try writer.flush();
}

/// Removes an installed model.
pub fn remove(allocator: std.mem.Allocator, io: std.Io, source: []const u8, target: []const u8) !void {
    if (!isValidLanguageCode(source) or !isValidLanguageCode(target)) return error.InvalidLanguageCode;

    const model_dir: []u8 = try allocator.print("models/{s}-{s}", .{ source, target });
    defer allocator.free(model_dir);

    try std.Io.Dir.cwd().access(io, model_dir, .{});
    try std.Io.Dir.cwd().deleteTree(io, model_dir);

    var buffer: [256]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = std.Io.File.stdout().writer(io, &buffer);
    const writer: *std.Io.Writer = &stdout_writer.interface;

    try writer.print("Successfully removed the model from \"{s}\"\n", .{ model_dir });
    try writer.flush();
}

/// Downloads and extracts a model from the OPUS-MT model repository that matches the given language codes, and converts it to CTranslate2 format.
pub fn install(allocator: std.mem.Allocator, io: std.Io, source: []const u8, target: []const u8, python_path: []const u8, quantization: ?[]const u8, no_input: bool) !void {
    if (!isValidLanguageCode(source) or !isValidLanguageCode(target)) return error.InvalidLanguageCode;

    const pair: []u8 = try allocator.print("{s}-{s}", .{ source, target });
    defer allocator.free(pair);

    const model_dir: []u8 = try allocator.print("models/{s}", .{ pair });
    defer allocator.free(model_dir);

    const archive_path: []u8 = try allocator.print("{s}/model.zip", .{ model_dir });
    defer allocator.free(archive_path);

    var buffer: [512]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = std.Io.File.stdout().writer(io, &buffer);
    const writer: *std.Io.Writer = &stdout_writer.interface;

    try writer.print("[1/5] Looking for OPUS-MT model {s}... ", .{ pair });
    try writer.flush();

    const index: []const u8 = fetchModelIndex(allocator, io) catch |err| {
        try writer.print("FAILED\n", .{});
        try writer.flush();

        return err;
    };

    var models: std.ArrayList([]const u8) = findModels(allocator, index, source, target) catch |err| {
        try writer.print("FAILED\n", .{});

        if (err == error.ModelNotFound) {
            try writer.print("\nCould not find OPUS-MT model {s}-{s}.\n", .{ source, target });

            var suggestions: std.ArrayList(Suggestion) = try findSimilarLanguagePairs(allocator, index, source, target);
            defer suggestions.deinit(allocator);

            if (suggestions.items.len == 0) {
                try writer.writeAll("No similar language pairs found.\n");
                
                return try writer.flush();
            }
            try writer.writeAll("Did you mean:\n");

            for (suggestions.items, 0..) |suggestion, i| {
                try writer.print("  {d}. {s}\n", .{ i + 1, suggestion.pair });
            }
            try writer.flush();

            return err;
        }
        try writer.flush();

        return err;
    };
    defer models.deinit(allocator);

    try writer.print("DONE\n", .{});
    if (!no_input and models.items.len != 1) try writer.writeAll("\n");

    try writer.flush();

    const model: []const u8 = if (no_input or models.items.len == 1) models.items[models.items.len - 1] else try selectModel(io, models);
    if (!no_input and models.items.len != 1) try writer.writeAll("\n");

    try writer.print("[2/5] Downloading model... ", .{});
    try writer.flush();

    const dir: std.Io.Dir = std.Io.Dir.cwd();
    try dir.createDirPath(io, model_dir);

    downloadModel(allocator, io, model, archive_path) catch |err| {
        try writer.print("FAILED\n", .{});
        try writer.flush();

        return err;
    };
    try writer.print("DONE\n", .{});
    try writer.print("[3/5] Extracting model... ", .{});
    try writer.flush();

    const temp_dir: []u8 = try allocator.print("{s}/tmp", .{ model_dir });
    defer allocator.free(temp_dir);

    const ct2_dir: []u8 = try allocator.print("{s}/ct2", .{ model_dir });
    defer allocator.free(ct2_dir);

    extractArchive(io, archive_path, temp_dir) catch |err| {
        try writer.print("FAILED\n", .{});
        try writer.flush();

        return err;
    };
    try writer.print("DONE\n", .{});
    try writer.print("[4/5] Converting model... ", .{});
    try writer.flush();

    var converted: bool = true;

    if (convertModel(io, temp_dir, ct2_dir, python_path, quantization)) {
        try writer.print("DONE\n", .{});
    } else |_| {
        converted = false;
        try writer.print("FAILED\n", .{});
        try writer.flush();
        std.log.err("Model conversion failed. Use --python-path=<path> to set the path of the Python executable, or convert the model manually.", .{});
    }
    try writer.print("[5/5] Cleaning up... ", .{});
    try writer.flush();

    finalizeModel(allocator, io, model_dir, temp_dir, archive_path, !converted) catch |err| {
        try writer.print("FAILED\n", .{});
        try writer.flush();

        return err;
    };

    writeMetadata(allocator, io, model_dir, source, target, model, quantization) catch |err| {
        try writer.print("FAILED\n", .{});
        try writer.flush();

        return err;
    };
    try writer.print("DONE\n", .{});
    if (converted) try writer.print("Successfully installed the model in \"{s}\"\n", .{ model_dir });

    try writer.flush();
}

/// Translates the given input string and prints the translated output string.
pub fn translate(allocator: std.mem.Allocator, io: std.Io, source: []const u8, target: []const u8, input: []const u8) !void {
    if (!isValidLanguageCode(source) or !isValidLanguageCode(target)) return error.InvalidLanguageCode;

    const path = try allocator.printSentinel("{s}-{s}", .{ source, target }, 0);
    defer allocator.free(path);

    const model_dir = try allocator.printSentinel("models/{s}/ct2/", .{ path }, 0);
    defer allocator.free(model_dir);

    const source_file = try allocator.printSentinel("models/{s}/source.spm", .{ path }, 0);
    defer allocator.free(source_file);

    const target_file = try allocator.printSentinel("models/{s}/target.spm", .{ path }, 0);
    defer allocator.free(target_file);

    const input_sentinel = try allocator.dupeSentinel(u8, input, 0);
    defer allocator.free(input_sentinel);

    const translator: ?*c.TranslatorHandle = c.create_translator(model_dir, source_file, target_file) orelse return error.TranslatorCreationError;
    defer c.destroy_translator(translator);

    const result: [*c]u8 = c.translate(translator, input_sentinel) orelse return error.TranslationError;
    defer c.free_string(result);

    var buffer: [512]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = std.Io.File.stdout().writer(io, &buffer);
    const writer: *std.Io.Writer = &stdout_writer.interface;

    try writer.print("{s}\n", .{ result });
    try writer.flush();
}
