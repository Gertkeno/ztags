const std = @import("std");

fn tagKind(tree: *std.zig.ast.Tree, node: *std.zig.ast.Node) u8 {
    const NTag = std.zig.ast.Node.Tag;
    return switch (node.tag) {
        NTag.FnProto => 'f',
        NTag.VarDecl => {
            const var_decl_node = node.cast(std.zig.ast.Node.VarDecl).?;
            if (var_decl_node.getInitNode()) |init_node| {
                if (init_node.tag == NTag.ContainerDecl) {
                    const container_node = init_node.cast(std.zig.ast.Node.ContainerDecl).?;
                    return switch (tree.token_ids[container_node.kind_token]) {
                        std.zig.Token.Id.Keyword_struct => 's',
                        std.zig.Token.Id.Keyword_union => 'u',
                        std.zig.Token.Id.Keyword_enum => 'g',
                        else => @as(u8, 0),
                    };
                } else if (init_node.tag == NTag.ErrorType or init_node.tag == NTag.ErrorSetDecl) {
                    return 'r';
                }
            }
            return 'v';
        },
        NTag.ContainerField => {
            const member_decl_node = node.castTag(NTag.ContainerField).?;
            // hacky but enumerated types do not allow for type expressions while union/structs require
            // this just happens to be an easy check if the container field is a enum or otherwise (assuming valid code).
            if (member_decl_node.type_expr == null) {
                return 'e';
            } else {
                return 'm';
            }
        },
        else => @as(u8, 0),
    };
}

fn escapeString(allocator: *std.mem.Allocator, line: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    // Max length of escaped string is twice the length of the original line.
    try result.ensureCapacity(line.len * 2);
    for (line) |ch| {
        switch (ch) {
            '/', '\\' => {
                try result.append('\\');
                try result.append(ch);
            },
            else => {
                try result.append(ch);
            },
        }
    }
    return result.toOwnedSlice();
}

const ErrorSet = error{
    OutOfMemory,
    WriteError,
};

const ParseArgs = struct {
    allocator: *std.mem.Allocator,
    tree: *std.zig.ast.Tree,
    node: *std.zig.ast.Node,
    path: []const u8,
    scope_field_name: []const u8,
    scope: []const u8,
    tags_file_stream: *std.fs.File.Writer,
};

fn findTags(args: *const ParseArgs) ErrorSet!void {
    var token_index: ?std.zig.ast.TokenIndex = null;
    const NTag = std.zig.ast.Node.Tag;
    switch (args.node.tag) {
        NTag.ContainerField => {
            const container_field = args.node.castTag(NTag.ContainerField).?;
            token_index = container_field.name_token;
        },
        NTag.FnProto => {
            const fn_node = args.node.castTag(NTag.FnProto).?;
            if (fn_node.getNameToken()) |name_index| {
                token_index = name_index;
            }
        },
        NTag.VarDecl => {
            const var_node = args.node.castTag(NTag.VarDecl).?;
            token_index = var_node.name_token;

            if (var_node.getInitNode()) |init_node| {
                if (init_node.tag == NTag.ContainerDecl) {
                    const container_node = init_node.cast(std.zig.ast.Node.ContainerDecl).?;
                    const container_kind = args.tree.tokenSlice(container_node.kind_token);
                    const container_name = args.tree.tokenSlice(token_index.?);
                    const delim = ".";
                    var sub_scope: []u8 = undefined;
                    if (args.scope.len > 0) {
                        sub_scope = try args.allocator.alloc(u8, args.scope.len + delim.len + container_name.len);
                        std.mem.copy(u8, sub_scope[0..args.scope.len], args.scope);
                        std.mem.copy(u8, sub_scope[args.scope.len .. args.scope.len + delim.len], delim);
                        std.mem.copy(u8, sub_scope[args.scope.len + delim.len ..], container_name);
                    } else {
                        sub_scope = try std.mem.dupe(args.allocator, u8, container_name);
                    }
                    defer args.allocator.free(sub_scope);
                    for (container_node.fieldsAndDecls()) |child| {
                        const child_args = ParseArgs{
                            .allocator = args.allocator,
                            .tree = args.tree,
                            .node = child,
                            .path = args.path,
                            .scope_field_name = container_kind,
                            .scope = sub_scope,
                            .tags_file_stream = args.tags_file_stream,
                        };
                        try findTags(&child_args);
                    }
                }
            }
        },
        else => {},
    }

    if (token_index == null) {
        return;
    }

    const name = args.tree.tokenSlice(token_index.?);
    const location = args.tree.tokenLocation(0, token_index.?);
    const line = args.tree.source[location.line_start..location.line_end];
    const escaped_line = try escapeString(args.allocator, line);
    defer args.allocator.free(escaped_line);

    args.tags_file_stream.print("{s}\t{s}\t/^{s}$/;\"\t{c}", .{
        name,
        args.path,
        escaped_line,
        tagKind(args.tree, args.node),
    }) catch return ErrorSet.WriteError;

    if (args.scope.len > 0) {
        args.tags_file_stream.print("\t{s}:{s}", .{ args.scope_field_name, args.scope }) catch return ErrorSet.WriteError;
    }
    args.tags_file_stream.print("\n", .{}) catch return ErrorSet.WriteError;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = &gpa.allocator;
    var args_it = std.process.args();
    _ = args_it.skip(); // Discard program name

    var stdout = std.io.getStdOut().writer();

    while (args_it.next(allocator)) |try_path| {
        const path = try try_path;
        defer allocator.free(path);

        const source = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
        defer allocator.free(source);

        var tree = try std.zig.parse(allocator, source);
        defer tree.deinit();

        const node = &tree.root_node.base;
        var child_i: usize = 0;
        while (node.iterate(child_i)) |child| : (child_i += 1) {
            const child_args = ParseArgs{
                .allocator = allocator,
                .tree = tree,
                .node = child,
                .path = path,
                .scope_field_name = "",
                .scope = "",
                .tags_file_stream = &stdout,
            };
            try findTags(&child_args);
        }
    }
}
