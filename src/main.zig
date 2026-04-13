const std = @import("std");

const StdWriter = std.Io.Writer;
const StdReader = std.Io.Reader;

const JsonValue = std.json.Value;
const JsonValueParse = std.json.Parsed(JsonValue);

const GlobalContext = struct {
    allocator: std.mem.Allocator,
    methods: MethodHashMap,
    writer: *StdWriter,
};

const RequestContext = struct {
    allocator: std.mem.Allocator,
    id: std.json.Value,
    params: ?std.json.Value,
    writer: *StdWriter,
    response: *ResponseWriter,
    diag: ?*RequestDiagnostics,
};

const RequestDiagnostics = struct {
    innerError: ?anyerror,
};

const RequestError = error{
    InvalidParams,
    InvalidOperation,
};

const JsonRpcErrorCode = enum(i16) {
    InvalidRequest = -32600,
    MethodNotFound = -32601,
    InvalidParams = -32602,
    InternalError = -32603,
    ParseError = -32700,
};

const MethodHandlerDelegate = *const fn (ctx: RequestContext) RequestError!void;

const MethodHashMap = std.StringArrayHashMap(MethodHandlerDelegate);

const JSONRPC_VERSION = "2.0";

const FS_READ_METHOD: []const u8 = "fs/read";
const FS_WRITE_METHOD: []const u8 = "fs/write";

const FS_READ_BUFFER_SIZE = 1024 * 1024; // 1 MB

pub fn main() !void {
    // Initialize a buffer for reading from stdin and wrap it in a reader interface
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader_wrapper = std.fs.File.stdin().reader(&stdin_buffer);
    const stdin = &stdin_reader_wrapper.interface;

    // Initialize a buffer for writing to stdout and wrap it in a writer interface
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer_wrapper = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer_wrapper.interface;

    // Initialize general-purpose allocator for parsing json
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // Initialize a set of supported JSON-RPC methods
    var supportedMethods = try initMethodHashSet(allocator);
    defer supportedMethods.deinit();

    const ctx = GlobalContext{
        .allocator = allocator,
        .methods = supportedMethods,
        .writer = stdout,
    };

    // Read lines from stdin and write responses to stdout
    while (stdin.takeDelimiter('\n')) |line| {
        if (line) |input| {
            try processInput(ctx, input);
        } else {
            // EOF reached, exit the loop and end the program
            break;
        }
    } else |err| {
        return err;
    }
}

fn processInput(ctx: GlobalContext, inputRaw: []const u8) !void {
    // Initialize a temporary arena allocator for this request's processing
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var response = ResponseWriter.init(ctx.writer);

    var jsonDiag = std.json.Diagnostics{};
    const parsed = parseInputAsJsonValue(allocator, inputRaw, &jsonDiag) catch |err| {
        std.debug.print("Invalid JSON-RPC request: parsing error {s} at line {d}, column {d}\n", .{ @errorName(err), jsonDiag.getLine(), jsonDiag.getColumn() });
        try response.sendFullError(null, .ParseError, null);
        return;
    };

    const input = parsed.value;

    if (input != .object) {
        std.debug.print("Invalid JSON-RPC request: expected an object\n", .{});
        try response.sendFullError(null, .InvalidRequest, null);
        return;
    }

    const rawId = input.object.get("id") orelse std.json.Value.null;

    if (!checkJsonRpcVersion20(input.object.get("jsonrpc"))) {
        std.debug.print("Invalid JSON-RPC request: only JSONRPC 2.0 supported\n", .{});
        try response.sendFullError(rawId, .InvalidRequest, null);
        return;
    }

    if (!checkIdFieldType(input.object.get("id"))) {
        std.debug.print("Invalid JSON-RPC request: 'id' field must be a string, number, or null\n", .{});
        try response.sendFullError(rawId, .InvalidRequest, null);
        return;
    }

    const method = parseMethodFromJsonValue(input.object.get("method")) catch |err| switch (err) {
        error.MethodFieldMissing => {
            std.debug.print("Invalid JSON-RPC request: missing 'method' field\n", .{});
            try response.sendFullError(rawId, .InvalidRequest, null);
            return;
        },
        error.MethodFieldInvalidType => {
            std.debug.print("Invalid JSON-RPC request: 'method' field must be a string\n", .{});
            try response.sendFullError(rawId, .InvalidRequest, null);
            return;
        },
    };

    if (ctx.methods.get(method)) |handler| {
        var requestDiag = RequestDiagnostics{ .innerError = null };
        const requestCtx = RequestContext{
            .allocator = allocator,
            .id = rawId,
            .params = input.object.get("params"),
            .writer = ctx.writer,
            .response = &response,
            .diag = &requestDiag,
        };

        handler(requestCtx) catch |err| switch (err) {
            RequestError.InvalidParams => {
                std.debug.print("Invalid parameters for method '{s}': {s}\n", .{ method, if (requestDiag.innerError) |e| @errorName(e) else "unknown error" });
                try response.sendFullError(rawId, .InvalidParams, null);
                return;
            },
            RequestError.InvalidOperation => {
                std.debug.print("Failed to execute method '{s}' due to an internal error: {s}\n", .{ method, if (requestDiag.innerError) |e| @errorName(e) else "unknown error" });
                try response.sendFullError(rawId, .InternalError, null);
                return;
            },
        };
    } else {
        std.debug.print("Invalid JSON-RPC request: method '{s}' not found\n", .{method});
        try response.sendFullError(rawId, .MethodNotFound, null);
        return;
    }
}

fn parseInputAsJsonValue(allocator: std.mem.Allocator, input: []const u8, diag: *std.json.Diagnostics) !JsonValueParse {
    var scanner = std.json.Scanner.initCompleteInput(allocator, input);
    scanner.enableDiagnostics(diag);
    return try std.json.parseFromTokenSource(std.json.Value, allocator, &scanner, .{});
}

fn checkJsonRpcVersion20(value: ?std.json.Value) bool {
    const val = value orelse return false;
    return switch (val) {
        .string => return std.mem.eql(u8, val.string, JSONRPC_VERSION),
        else => return false,
    };
}

fn checkIdFieldType(value: ?std.json.Value) bool {
    const val = value orelse return false;
    return switch (val) {
        .string, .integer, .null => return true,
        else => return false,
    };
}

fn parseMethodFromJsonValue(value: ?std.json.Value) ![]const u8 {
    const val = value orelse return error.MethodFieldMissing;
    return switch (val) {
        .string => val.string,
        else => return error.MethodFieldInvalidType,
    };
}

fn initMethodHashSet(allocator: std.mem.Allocator) !MethodHashMap {
    var set = MethodHashMap.init(allocator);
    try set.put(FS_READ_METHOD, handleFsReadMethod);
    try set.put(FS_WRITE_METHOD, handleFsReadMethod);
    return set;
}

fn handleFsReadMethod(ctx: RequestContext) RequestError!void {
    const path = parsePathFromJson(ctx.params) catch |err| {
        if (ctx.diag) |d| {
            d.innerError = err;
        }
        return RequestError.InvalidParams;
    };

    processFsReadMethod(ctx, path) catch |err| {
        if (ctx.diag) |d| {
            d.innerError = err;
        }
        return RequestError.InvalidOperation;
    };
}

fn processFsReadMethod(ctx: RequestContext, path: []const u8) !void {
    const content = try std.fs.cwd().readFileAlloc(ctx.allocator, path, FS_READ_BUFFER_SIZE);
    try ctx.response.beginResponse();
    try ctx.response.writeResultField();
    try ctx.writer.writeAll("{ \"content\": \"");
    try std.json.Stringify.encodeJsonString(content, .{}, ctx.writer);
    try ctx.writer.writeAll("\", \"encoding\": \"utf-8\" }");
    try ctx.response.writeId(ctx.id);
    try ctx.response.endResponse();
}

fn parsePathFromJson(value: ?std.json.Value) ![]const u8 {
    const val = value orelse return error.NoPathSpecified;
    return switch (val) {
        .string => val.string,
        .object => {
            const pathVal = val.object.get("path") orelse return error.NoPathSpecified;
            return switch (pathVal) {
                .string => pathVal.string,
                else => return error.InvalidPathType,
            };
        },
        .array => {
            if (val.array.items.len == 0) {
                return error.NoPathSpecified;
            }
            const pathVal = val.array.items[0];
            return switch (pathVal) {
                .string => pathVal.string,
                else => return error.InvalidPathType,
            };
        },
        else => return error.InvalidParamsType,
    };
}

const ResponseWriter = struct {
    writer: *StdWriter,

    fn init(writer: *StdWriter) ResponseWriter {
        return ResponseWriter{ .writer = writer };
    }

    fn beginResponse(self: *ResponseWriter) !void {
        try self.writer.writeAll("{\"jsonrpc\": \"2.0\", ");
    }

    fn endResponse(self: *ResponseWriter) !void {
        try self.writer.writeAll("}\n");
        try self.writer.flush();
    }

    fn writeResultField(self: *ResponseWriter) !void {
        try self.writer.writeAll("\"result\": ");
    }

    fn writeResult(self: *ResponseWriter, data: JsonValue) !void {
        try self.writeResultField();
        try std.json.Stringify.value(data, .{}, self.writer);
    }

    fn writeError(self: *ResponseWriter, code: JsonRpcErrorCode, data: ?JsonValue) !void {
        try self.writer.writeAll("\"error\": { \"code\": ");
        try self.writer.print("{d}", .{@intFromEnum(code)});
        try self.writer.writeAll(", \"message\": \"");
        try self.writer.writeAll(getJsonRpcErrorMessage(code));
        try self.writer.writeAll("\"");
        if (data) |d| {
            try self.writer.writeAll(", \"data\": ");
            try std.json.Stringify.value(d, .{}, self.writer);
        }
        try self.writer.writeAll(" }");
    }

    fn writeId(self: *ResponseWriter, id: ?std.json.Value) !void {
        if (id) |idValue| {
            try self.writer.writeAll(", \"id\": ");
            try std.json.Stringify.value(idValue, .{}, self.writer);
        } else {
            try self.writer.writeAll(", \"id\": null");
        }
    }

    fn sendFullError(self: *ResponseWriter, id: ?std.json.Value, code: JsonRpcErrorCode, data: ?JsonValue) !void {
        try self.beginResponse();
        try self.writeError(code, data);
        try self.writeId(id);
        try self.endResponse();
    }

    fn getJsonRpcErrorMessage(code: JsonRpcErrorCode) []const u8 {
        return switch (code) {
            .InvalidRequest => "Invalid request",
            .MethodNotFound => "Method not found",
            .InvalidParams => "Invalid params",
            .InternalError => "Internal error",
            .ParseError => "Parse error",
        };
    }
};
