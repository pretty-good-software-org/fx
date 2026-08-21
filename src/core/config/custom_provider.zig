const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

/// Fx custom models config — inspired by external provider registry.
/// Supports apiKey resolution: `!command`, `$ENV`, `${ENV}`, `$$` -> `$`, `$!` -> `!`.
/// File: ~/.fx/models.json (primary), ~/.fx/providers.json (fallback), or $FX_MODELS_PATH.
pub const ApiType = enum {
    openai_completions,
    openai_responses,
    anthropic_messages,
    google_generative_ai,
    unknown,

    pub fn fromString(s: []const u8) ApiType {
        if (std.mem.eql(u8, s, "openai-completions")) return .openai_completions;
        if (std.mem.eql(u8, s, "openai-responses")) return .openai_responses;
        if (std.mem.eql(u8, s, "anthropic-messages")) return .anthropic_messages;
        if (std.mem.eql(u8, s, "google-generative-ai")) return .google_generative_ai;
        return .unknown;
    }
};

pub const CustomModel = struct {
    id: []u8,
    name: ?[]u8 = null,
    baseUrl: ?[]u8 = null,
    api: ?ApiType = null,
    reasoning: bool = false,
    input: ?[][]u8 = null,
    contextWindow: ?u32 = null,
    maxTokens: ?u32 = null,

    pub fn deinit(self: *CustomModel, alloc: Allocator) void {
        alloc.free(self.id);
        if (self.name) |v| alloc.free(v);
        if (self.baseUrl) |v| alloc.free(v);
        if (self.input) |arr| {
            for (arr) |s| alloc.free(s);
            alloc.free(arr);
        }
        self.* = undefined;
    }
};

pub const CustomProvider = struct {
    name: []u8, // key from providers map, e.g. "meta"
    baseUrl: ?[]u8 = null,
    api: ?ApiType = null,
    apiKeyRaw: ?[]u8 = null,
    apiKeyResolved: ?[]u8 = null,
    models: []CustomModel = &.{},

    pub fn deinit(self: *CustomProvider, alloc: Allocator) void {
        alloc.free(self.name);
        if (self.baseUrl) |v| alloc.free(v);
        if (self.apiKeyRaw) |v| {
            @memset(v, 0);
            alloc.free(v);
        }
        if (self.apiKeyResolved) |v| {
            @memset(v, 0);
            alloc.free(v);
        }
        for (self.models) |*m| m.deinit(alloc);
        if (self.models.len > 0) alloc.free(self.models);
        self.* = undefined;
    }
};

pub const CustomConfig = struct {
    providers: []CustomProvider = &.{},

    pub fn deinit(self: *CustomConfig, alloc: Allocator) void {
        for (self.providers) |*p| p.deinit(alloc);
        if (self.providers.len > 0) alloc.free(self.providers);
        self.* = undefined;
    }

    pub fn findModel(self: *const CustomConfig, model_id: []const u8) ?struct { provider: *const CustomProvider, model: *const CustomModel } {
        var search_id = model_id;
        var provider_hint: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, model_id, '/')) |idx| {
            provider_hint = model_id[0..idx];
            search_id = model_id[idx + 1 ..];
        }
        for (self.providers) |*prov| {
            if (provider_hint) |hint| {
                if (!std.mem.eql(u8, prov.name, hint)) continue;
            }
            for (prov.models) |*m| {
                if (std.mem.eql(u8, m.id, search_id) or std.mem.eql(u8, m.id, model_id)) {
                    return .{ .provider = prov, .model = m };
                }
            }
        }
        return null;
    }
};

pub fn resolveApiKeyValue(alloc: Allocator, raw: []const u8) !?[]u8 {
    if (raw.len == 0) return null;
    if (raw.len > 1 and raw[0] == '!' and !(raw.len >= 2 and raw[0] == '$' and raw[1] == '!')) {
        const cmd = raw[1..];
        const result = std.process.run(alloc, io_mod.getIo(), .{
            .argv = &.{ "sh", "-c", cmd },
        }) catch return null;
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return null,
            else => return null,
        }
        const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (trimmed.len == 0) return null;
        return try alloc.dupe(u8, trimmed);
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '$' and i + 1 < raw.len) {
            const next = raw[i + 1];
            if (next == '$') {
                try out.append(alloc, '$');
                i += 2;
                continue;
            } else if (next == '!') {
                try out.append(alloc, '!');
                i += 2;
                continue;
            } else if (next == '{') {
                const end = std.mem.indexOfScalarPos(u8, raw, i + 2, '}') orelse {
                    try out.append(alloc, c);
                    i += 1;
                    continue;
                };
                const var_name = raw[i + 2 .. end];
                if (io_mod.getenv(var_name)) |val| {
                    try out.appendSlice(alloc, val);
                } else {
                    return null;
                }
                i = end + 1;
                continue;
            } else {
                var j = i + 1;
                while (j < raw.len and (std.ascii.isAlphanumeric(raw[j]) or raw[j] == '_')) : (j += 1) {}
                if (j == i + 1) {
                    try out.append(alloc, c);
                    i += 1;
                    continue;
                }
                const var_name = raw[i + 1 .. j];
                if (io_mod.getenv(var_name)) |val| {
                    try out.appendSlice(alloc, val);
                } else {
                    return null;
                }
                i = j;
                continue;
            }
        } else {
            try out.append(alloc, c);
            i += 1;
        }
    }
    return try out.toOwnedSlice(alloc);
}

fn resolveConfigPath(alloc: Allocator, custom_path: ?[]const u8) !?[]u8 {
    if (custom_path) |p| return try alloc.dupe(u8, p);
    if (io_mod.getenv("FX_MODELS_PATH")) |p| return try alloc.dupe(u8, p);
    const home = io_mod.getenv("HOME") orelse return null;

    // Try ~/.fx/models.json first
    const primary = try std.fs.path.join(alloc, &.{ home, ".fx", "models.json" });
    // Check existence by trying to open, but we return path regardless – caller will handle FileNotFound as empty
    // We also support fallback ~/.fx/providers.json via secondary check in load
    return primary;
}

pub fn loadCustomConfig(alloc: Allocator, custom_path: ?[]const u8) !CustomConfig {
    const maybe_path = try resolveConfigPath(alloc, custom_path);
    defer if (maybe_path) |p| alloc.free(p);

    const path = maybe_path orelse return CustomConfig{};
    const use_default_fallback = custom_path == null and io_mod.getenv("FX_MODELS_PATH") == null;

    // Try primary path, then the legacy fallback only for the default path.
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => if (!use_default_fallback) {
            return CustomConfig{};
        } else {
            const home = io_mod.getenv("HOME") orelse return CustomConfig{};
            const fallback = try std.fs.path.join(alloc, &.{ home, ".fx", "providers.json" });
            defer alloc.free(fallback);
            var fb = std.Io.Dir.openFileAbsolute(io_mod.getIo(), fallback, .{ .mode = .read_only }) catch |e| switch (e) {
                error.FileNotFound => return CustomConfig{},
                else => return e,
            };
            defer fb.close(io_mod.getIo());
            const content = try io_mod.readFileToEnd(alloc, &fb, 1024 * 1024);
            defer alloc.free(content);
            return try parseCustomConfigJsonWithOptions(alloc, content, use_default_fallback);
        },
        else => return err,
    };
    defer file.close(io_mod.getIo());

    const content = io_mod.readFileToEnd(alloc, &file, 1024 * 1024) catch |err| switch (err) {
        error.StreamTooLong => return error.StreamTooLong,
        else => return err,
    };
    defer alloc.free(content);

    return try parseCustomConfigJsonWithOptions(alloc, content, use_default_fallback);
}

pub fn parseCustomConfigJson(alloc: Allocator, json_bytes: []const u8) !CustomConfig {
    return parseCustomConfigJsonWithOptions(alloc, json_bytes, true);
}

fn parseCustomConfigJsonWithOptions(alloc: Allocator, json_bytes: []const u8, allow_commands: bool) !CustomConfig {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    if (parsed.value != .object) return CustomConfig{};
    const providers_val = parsed.value.object.get("providers") orelse return CustomConfig{};
    if (providers_val != .object) return CustomConfig{};

    var providers = std.ArrayList(CustomProvider).empty;
    errdefer {
        for (providers.items) |*p| p.deinit(alloc);
        providers.deinit(alloc);
    }

    var it = providers_val.object.iterator();
    while (it.next()) |entry| {
        const prov_name = entry.key_ptr.*;
        const prov_obj = entry.value_ptr.*;
        if (prov_obj != .object) continue;

        var provider = CustomProvider{
            .name = try alloc.dupe(u8, prov_name),
        };
        errdefer provider.deinit(alloc);

        if (prov_obj.object.get("baseUrl")) |v| {
            if (v == .string) provider.baseUrl = try alloc.dupe(u8, v.string);
        }
        if (prov_obj.object.get("api")) |v| {
            if (v == .string) provider.api = ApiType.fromString(v.string);
        }
        if (prov_obj.object.get("apiKey")) |v| {
            if (v == .string) {
                provider.apiKeyRaw = try alloc.dupe(u8, v.string);
                if (allow_commands or !std.mem.startsWith(u8, v.string, "!")) {
                    if (try resolveApiKeyValue(alloc, v.string)) |resolved| {
                        provider.apiKeyResolved = resolved;
                    }
                }
            }
        }

        if (prov_obj.object.get("models")) |models_val| {
            if (models_val == .array) {
                var models = std.ArrayList(CustomModel).empty;
                errdefer {
                    for (models.items) |*m| m.deinit(alloc);
                    models.deinit(alloc);
                }
                for (models_val.array.items) |model_item| {
                    if (model_item != .object) continue;
                    var m = CustomModel{
                        .id = undefined,
                    };
                    if (model_item.object.get("id")) |id_v| {
                        if (id_v != .string) continue;
                        m.id = try alloc.dupe(u8, id_v.string);
                    } else continue;

                    if (model_item.object.get("name")) |n| {
                        if (n == .string) m.name = try alloc.dupe(u8, n.string);
                    }
                    if (model_item.object.get("baseUrl")) |b| {
                        if (b == .string) m.baseUrl = try alloc.dupe(u8, b.string);
                    }
                    if (model_item.object.get("api")) |a| {
                        if (a == .string) m.api = ApiType.fromString(a.string);
                    }
                    if (model_item.object.get("reasoning")) |r| {
                        if (r == .bool) m.reasoning = r.bool;
                    }
                    if (model_item.object.get("contextWindow")) |cw| {
                        if (cw == .integer) m.contextWindow = std.math.cast(u32, cw.integer);
                    }
                    if (model_item.object.get("maxTokens")) |mt| {
                        if (mt == .integer) m.maxTokens = std.math.cast(u32, mt.integer);
                    }
                    if (model_item.object.get("input")) |inp| {
                        if (inp == .array) {
                            var input_arr = std.ArrayList([]u8).empty;
                            for (inp.array.items) |inp_item| {
                                if (inp_item == .string) {
                                    try input_arr.append(alloc, try alloc.dupe(u8, inp_item.string));
                                }
                            }
                            m.input = try input_arr.toOwnedSlice(alloc);
                        }
                    }

                    try models.append(alloc, m);
                }
                provider.models = try models.toOwnedSlice(alloc);
            }
        }

        try providers.append(alloc, provider);
    }

    return CustomConfig{
        .providers = try providers.toOwnedSlice(alloc),
    };
}

test "resolveApiKeyValue literal" {
    const alloc = std.testing.allocator;
    const res = try resolveApiKeyValue(alloc, "sk-foo");
    defer if (res) |v| alloc.free(v);
    try std.testing.expectEqualStrings("sk-foo", res.?);
}

test "resolveApiKeyValue env interpolation" {
    const alloc = std.testing.allocator;
    const home = io_mod.getenv("HOME") orelse return;
    const res = try resolveApiKeyValue(alloc, "$HOME");
    defer if (res) |v| alloc.free(v);
    try std.testing.expectEqualStrings(home, res.?);
}

test "resolveApiKeyValue escaped $$ and $!" {
    const alloc = std.testing.allocator;
    const res1 = try resolveApiKeyValue(alloc, "$$literal");
    defer if (res1) |v| alloc.free(v);
    try std.testing.expectEqualStrings("$literal", res1.?);

    const res2 = try resolveApiKeyValue(alloc, "$!literal-bang");
    defer if (res2) |v| alloc.free(v);
    try std.testing.expectEqualStrings("!literal-bang", res2.?);
}

test "resolveApiKeyValue command" {
    const alloc = std.testing.allocator;
    const res = try resolveApiKeyValue(alloc, "!echo hello");
    defer if (res) |v| alloc.free(v);
    try std.testing.expectEqualStrings("hello", res.?);
}

test "parseCustomConfigJson" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "providers": {
        \\    "meta": {
        \\      "baseUrl": "https://api.meta.ai/v1",
        \\      "api": "openai-responses",
        \\      "apiKey": "sk-test",
        \\      "models": [{ "id": "muse-spark-1.1", "name": "Muse Spark 1.1", "reasoning": true, "contextWindow": 1048576, "maxTokens": 131072 }]
        \\    }
        \\  }
        \\}
    ;
    var cfg = try parseCustomConfigJson(alloc, json);
    defer cfg.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), cfg.providers.len);
    try std.testing.expectEqualStrings("meta", cfg.providers[0].name);
    try std.testing.expectEqualStrings("muse-spark-1.1", cfg.providers[0].models[0].id);
    const found = cfg.findModel("meta/muse-spark-1.1");
    try std.testing.expect(found != null);
}
