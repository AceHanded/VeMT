const std = @import("std");
const cli = @import("cli.zig");

const quantization_types: [8][]const u8 = .{
    "int8",
    "int8_float32",
    "int8_float16",
    "int8_bfloat16",
    "int16",
    "float16",
    "bfloat16",
    "float32"
};

/// Prints the usage info log message.
fn printUsage() void {
    return std.log.info(
        \\
        \\Usage:
        \\  vemt list
        \\  vemt remove <source_language> <target_language>
        \\  vemt install <source_language> <target_language> [--python-path=<path>] [--quantization=<type>] [--no-input]
        \\  vemt <source_language> <target_language> <input>
        \\
        \\Options:
        \\  --python-path=<path>   Path to the Python executable [default: "python"].
        \\  --quantization=<type>  Quantization type to use during model conversion
        \\                         (int8|int8_float32|int8_float16|int8_bfloat16|int16|float16|bfloat16|float32).
        \\  --no-input             Skips interactive model selection and automatically chooses the last model.
    , .{});
}

/// Checks that the quantization type is one of the available ones.
fn isValidQuantization(value: []const u8) bool {
    for (quantization_types) |quantization| {
        if (std.mem.eql(u8, value, quantization)) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const io: std.Io = init.io;
    const allocator: std.mem.Allocator = init.arena.allocator();
    const args: []const [:0]const u8 = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) return printUsage();

    const is_list_command: bool = std.mem.eql(u8, args[1], "list");
    const is_remove_command: bool = std.mem.eql(u8, args[1], "remove");
    const is_install_command: bool = std.mem.eql(u8, args[1], "install");

    if (is_list_command) {
        if (args.len != 2) return printUsage();
    } else if (is_remove_command) {
        if (args.len != 4) return printUsage();
    } else if (is_install_command) {
        if (args.len != 4 and args.len != 5 and args.len != 6 and args.len != 7) return printUsage();
    } else {
        if (args.len != 4) return printUsage();
    }
    var python_path: []const u8 = "python";
    var quantization: ?[]const u8 = null;
    var no_input: bool = false;

    if (std.mem.eql(u8, args[1], "install") and args.len > 4) {
        for (args[4..]) |arg| {
            if (std.mem.startsWith(u8, arg, "--python-path=")) {
                python_path = arg["--python-path=".len..];
                if (python_path.len == 0) return printUsage();
            } else if (std.mem.startsWith(u8, arg, "--quantization=")) {
                quantization = arg["--quantization=".len..];
                if (quantization.?.len == 0 or !isValidQuantization(quantization.?)) return printUsage();
            } else if (std.mem.eql(u8, arg, "--no-input")) {
                no_input = true;
            } else {
                return printUsage();
            }
        }
    }

    return (
        if (is_list_command)
            cli.list(io)
        else if (is_remove_command)
            cli.remove(allocator, io, args[2], args[3])
        else if (is_install_command)
            cli.install(allocator, io, args[2], args[3], python_path, quantization, no_input)
        else
            cli.translate(allocator, io, args[1], args[2], args[3])
    ) catch |err| {
        std.log.err("error.{s}", .{ @errorName(err) });
    };
}
