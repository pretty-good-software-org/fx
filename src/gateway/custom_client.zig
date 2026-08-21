const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const custom_provider = @import("../core/config/custom_provider.zig");

const Allocator = std.mem.Allocator;

pub const StreamChunkCallback = *const fn (ctx: *anyopaque, chunk: []const u8) void;

/// Extract prompt from Gateway payload (prompt array or input string)
pub fn extractPromptFromPayload(alloc: Allocator, payload: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch {
        return try alloc.dupe(u8, payload[0..@min(payload.len, 4000)]);
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return try alloc.dupe(u8, payload[0..@min(payload.len, 4000)]);
    }
    const prompt_key = parsed.value.object.get("prompt") orelse parsed.value.object.get("messages") orelse parsed.value.object.get("input");
    if (prompt_key) |pk| {
        if (pk == .array) {
            var i = pk.array.items.len;
            while (i > 0) {
                i -= 1;
                const msg = pk.array.items[i];
                if (msg != .object) continue;
                const role = msg.object.get("role") orelse continue;
                if (role != .string) continue;
                if (!std.mem.eql(u8, role.string, "user")) continue;
                const content = msg.object.get("content") orelse continue;
                if (content == .string) {
                    return try alloc.dupe(u8, content.string);
                } else if (content == .array) {
                    for (content.array.items) |block| {
                        if (block == .object) {
                            if (block.object.get("text")) |txt| {
                                if (txt == .string) return try alloc.dupe(u8, txt.string);
                            }
                            if (block.object.get("content")) |c2| {
                                if (c2 == .string) return try alloc.dupe(u8, c2.string);
                            }
                        }
                    }
                }
            }
            if (pk.array.items.len > 0) {
                const last = pk.array.items[pk.array.items.len - 1];
                if (last == .object) {
                    if (last.object.get("content")) |c| {
                        if (c == .string) return try alloc.dupe(u8, c.string);
                    }
                }
            }
        } else if (pk == .string) {
            return try alloc.dupe(u8, pk.string);
        }
    }
    return try alloc.dupe(u8, payload[0..@min(payload.len, 4000)]);
}

pub fn resolveCustomModel(alloc: Allocator, model_id: []const u8) !?struct {
    provider: custom_provider.CustomProvider,
    model: custom_provider.CustomModel,
    config: custom_provider.CustomConfig,
} {
    var cfg = try custom_provider.loadCustomConfig(alloc, null);
    errdefer cfg.deinit(alloc);

    if (cfg.findModel(model_id)) |_| {
        var owned_cfg = cfg;
        const found2 = owned_cfg.findModel(model_id).?;
        var prov = custom_provider.CustomProvider{
            .name = try alloc.dupe(u8, found2.provider.name),
            .baseUrl = if (found2.provider.baseUrl) |b| try alloc.dupe(u8, b) else null,
            .api = found2.provider.api,
            .apiKeyRaw = if (found2.provider.apiKeyRaw) |r| try alloc.dupe(u8, r) else null,
            .apiKeyResolved = if (found2.provider.apiKeyResolved) |res| try alloc.dupe(u8, res) else null,
            .models = &.{},
        };
        errdefer prov.deinit(alloc);
        var m = custom_provider.CustomModel{
            .id = try alloc.dupe(u8, found2.model.id),
            .name = if (found2.model.name) |n| try alloc.dupe(u8, n) else null,
            .baseUrl = if (found2.model.baseUrl) |b| try alloc.dupe(u8, b) else null,
            .api = found2.model.api,
            .reasoning = found2.model.reasoning,
            .contextWindow = found2.model.contextWindow,
            .maxTokens = found2.model.maxTokens,
            .input = if (found2.model.input) |input| blk: {
                var cloned = try alloc.alloc([]u8, input.len);
                errdefer alloc.free(cloned);
                var count: usize = 0;
                errdefer for (cloned[0..count]) |value| alloc.free(value);
                for (input) |value| {
                    cloned[count] = try alloc.dupe(u8, value);
                    count += 1;
                }
                break :blk cloned;
            } else null,
        };
        errdefer m.deinit(alloc);
        owned_cfg.deinit(alloc);
        return .{
            .provider = prov,
            .model = m,
            .config = custom_provider.CustomConfig{},
        };
    }

    cfg.deinit(alloc);
    return null;
}

pub fn isCustomModel(model_id: []const u8) bool {
    // Heuristic: check if id looks like custom (e.g., contains spark or meta/ prefix)
    // Full check will be done via config lookup
    if (std.mem.indexOf(u8, model_id, "muse-spark") != null) return true;
    if (std.mem.startsWith(u8, model_id, "meta/")) return true;
    if (std.mem.startsWith(u8, model_id, "custom/")) return true;
    // Also try config lookup (may be heavy, but ok for isCustom check)
    // We do quick check without allocs: if file exists and contains model id, assume custom
    // For now, heuristic is enough – real check happens in stream path via loadCustomConfig
    return false;
}

/// Direct HTTP client for custom providers (openai-responses compatible, e.g., Meta Model API)
pub fn streamViaDirectHttp(
    alloc: Allocator,
    provider: custom_provider.CustomProvider,
    model: custom_provider.CustomModel,
    prompt: []const u8,
    callback_ctx: *anyopaque,
    on_chunk: StreamChunkCallback,
) !void {
    const base_url = provider.baseUrl orelse model.baseUrl orelse return error.MissingBaseUrl;
    const api_key = provider.apiKeyResolved orelse return error.MissingApiKey;

    // Build URL: baseUrl + /responses (for openai-responses) or /chat/completions for completions
    const api_type = provider.api orelse model.api orelse .openai_responses;
    const endpoint = switch (api_type) {
        .openai_responses => "/responses",
        .openai_completions => "/chat/completions",
        .anthropic_messages => return error.UnsupportedApiType,
        else => "/responses",
    };

    const url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ std.mem.trimEnd(u8, base_url, "/"), endpoint });
    defer alloc.free(url);

    // Build JSON body: for openai-responses, { "model": id, "input": prompt }
    // For completions, { "model": id, "messages": [{"role":"user","content":prompt}] }
    var prompt_json = std.Io.Writer.Allocating.init(alloc);
    defer prompt_json.deinit();
    try std.json.Stringify.value(prompt, .{}, &prompt_json.writer);
    const prompt_json_slice = try prompt_json.toOwnedSlice();
    defer alloc.free(prompt_json_slice);
    var model_json = std.Io.Writer.Allocating.init(alloc);
    defer model_json.deinit();
    try std.json.Stringify.value(model.id, .{}, &model_json.writer);
    const model_json_slice = try model_json.toOwnedSlice();
    defer alloc.free(model_json_slice);

    var body: []u8 = undefined;
    if (api_type == .openai_completions) {
        body = try std.fmt.allocPrint(alloc,
            \\{{"model":{s},"messages":[{{"role":"user","content":{s}}}]}}
        , .{ model_json_slice, prompt_json_slice });
    } else {
        body = try std.fmt.allocPrint(alloc,
            \\{{"model":{s},"input":{s}}}
        , .{ model_json_slice, prompt_json_slice });
    }
    defer alloc.free(body);

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{api_key});
    defer {
        @memset(auth_header, 0);
        alloc.free(auth_header);
    }

    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth_header },
            .accept_encoding = .omit,
        },
        .response_writer = &out.writer,
    });

    if (result.status != .ok) {
        return error.HttpError;
    }

    const resp_body = try out.toOwnedSlice();
    defer alloc.free(resp_body);

    // Parse response to extract text (best-effort for different APIs)
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp_body, .{}) catch {
        // If parse fails, return raw body as chunk
        on_chunk(callback_ctx, resp_body);
        return;
    };
    defer parsed.deinit();

    var extracted: ?[]const u8 = null;
    if (parsed.value == .object) {
        // Try openai-responses: output_text top-level
        if (parsed.value.object.get("output_text")) |ot| {
            if (ot == .string) extracted = ot.string;
        }
        // Try output array: find message with role assistant and content output_text
        if (extracted == null) {
            if (parsed.value.object.get("output")) |out_arr| {
                if (out_arr == .array) {
                    for (out_arr.array.items) |item| {
                        if (item != .object) continue;
                        const typ = item.object.get("type") orelse continue;
                        if (typ != .string) continue;
                        if (!std.mem.eql(u8, typ.string, "message")) continue;
                        const role = item.object.get("role") orelse continue;
                        if (role != .string) continue;
                        if (!std.mem.eql(u8, role.string, "assistant")) continue;
                        const content = item.object.get("content") orelse continue;
                        if (content != .array) continue;
                        for (content.array.items) |cblock| {
                            if (cblock != .object) continue;
                            if (cblock.object.get("type")) |ct| {
                                if (ct != .string) continue;
                                if (!std.mem.eql(u8, ct.string, "output_text")) continue;
                            }
                            if (cblock.object.get("text")) |txt| {
                                if (txt == .string) {
                                    extracted = txt.string;
                                    break;
                                }
                            }
                        }
                        if (extracted != null) break;
                    }
                }
            }
        }
        // Fallback: first output item content[0].text (old logic)
        if (extracted == null) {
            if (parsed.value.object.get("output")) |out_arr| {
                if (out_arr == .array and out_arr.array.items.len > 0) {
                    const first = out_arr.array.items[0];
                    if (first == .object) {
                        if (first.object.get("content")) |content| {
                            if (content == .array and content.array.items.len > 0) {
                                const c0 = content.array.items[0];
                                if (c0 == .object) {
                                    if (c0.object.get("text")) |txt| {
                                        if (txt == .string) extracted = txt.string;
                                    }
                                }
                            } else if (content == .string) {
                                extracted = content.string;
                            }
                        }
                    }
                }
            }
        }
        // Try chat completions: choices[0].message.content
        if (extracted == null) {
            if (parsed.value.object.get("choices")) |choices| {
                if (choices == .array and choices.array.items.len > 0) {
                    const first = choices.array.items[0];
                    if (first == .object) {
                        if (first.object.get("message")) |msg| {
                            if (msg == .object) {
                                if (msg.object.get("content")) |c| {
                                    if (c == .string) extracted = c.string;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (extracted) |text| {
        on_chunk(callback_ctx, text);
    } else {
        // Fallback: return raw body
        on_chunk(callback_ctx, resp_body);
    }
}

/// Legacy wrapper that still spawns external CLI if direct HTTP fails – kept for compatibility but now uses direct HTTP
pub fn streamViaExternalCli(
    alloc: Allocator,
    model: []const u8,
    prompt: []const u8,
    callback_ctx: *anyopaque,
    on_chunk: StreamChunkCallback,
) !void {
    // Try direct HTTP path first via custom config
    if (try resolveCustomModel(alloc, model)) |resolved| {
        var prov = resolved.provider;
        var m = resolved.model;
        defer prov.deinit(alloc);
        defer m.deinit(alloc);
        var cfg = resolved.config;
        defer cfg.deinit(alloc);

        return try streamViaDirectHttp(alloc, prov, m, prompt, callback_ctx, on_chunk);
    }

    // Fallback: if model not in custom config, return error to let Gateway handle it
    return error.ModelNotFoundInCustomConfig;
}
