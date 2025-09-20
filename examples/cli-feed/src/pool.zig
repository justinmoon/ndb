const std = @import("std");
const websocket = @import("websocket");

const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

/// Simple mutex-protected FIFO queue used for command and event passing.
fn ThreadQueue(comptime T: type) type {
    return struct {
        mutex: Mutex = .{},
        cond: Condition = .{},
        list: std.ArrayListAligned(T, null) = std.ArrayListAligned(T, null).empty,
        allocator: Allocator,

        pub fn init(allocator: Allocator) @This() {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *@This()) void {
            self.list.deinit(self.allocator);
        }

        pub fn push(self: *@This(), value: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.list.append(self.allocator, value);
            self.cond.signal();
        }

        pub fn pop(self: *@This()) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.list.items.len == 0) return null;
            return self.list.orderedRemove(0);
        }

        pub fn wait(self: *@This()) T {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.list.items.len == 0) {
                self.cond.wait(&self.mutex);
            }
            return self.list.orderedRemove(0);
        }
    };
}

/// Parameters describing the filters to send with a REQ message.
pub const SubscriptionSpec = struct {
    /// Client-chosen subscription identifier echoed by the relay.
    subscription_id: []const u8,
    /// Pre-encoded JSON filters sent as part of the REQ.
    filters_json: []const u8,
};

/// Command payload for adding a relay connection.
const AddRelayCommand = struct {
    url: []u8,
    subscriptions: []Subscription,

    fn deinit(self: *AddRelayCommand, allocator: Allocator) void {
        for (self.subscriptions) |*sub| sub.deinit(allocator);
        allocator.free(self.subscriptions);
        allocator.free(self.url);
    }
};

/// Command payload for publishing an event across relays.
const PublishCommand = struct {
    relays: [][]u8,
    payload: []u8,

    fn deinit(self: *PublishCommand, allocator: Allocator) void {
        for (self.relays) |relay| allocator.free(relay);
        allocator.free(self.relays);
        allocator.free(self.payload);
    }
};

/// Commands consumed by the worker thread.
pub const PoolCommand = union(enum) {
    add_relay: AddRelayCommand,
    publish: PublishCommand,
    shutdown,

    pub fn deinit(self: *PoolCommand, allocator: Allocator) void {
        switch (self.*) {
            .add_relay => |*payload| payload.deinit(allocator),
            .publish => |*payload| payload.deinit(allocator),
            .shutdown => {},
        }
    }
};

/// Fully-owned subscription details queued to the worker.
pub const Subscription = struct {
    subscription_id: []u8,
    filters_json: []u8,

    pub fn clone(spec: SubscriptionSpec, allocator: Allocator) !Subscription {
        return Subscription{
            .subscription_id = try allocator.dupe(u8, spec.subscription_id),
            .filters_json = try allocator.dupe(u8, spec.filters_json),
        };
    }

    pub fn deinit(self: *Subscription, allocator: Allocator) void {
        allocator.free(self.subscription_id);
        allocator.free(self.filters_json);
    }
};

/// Events emitted from the worker thread back to the caller.
pub const PoolEvent = union(enum) {
    connected: struct { url: []u8 },
    received: struct { relay: []u8, payload: []u8 },
    eose: struct { relay: []u8, subscription: []u8 },
    notice: struct { relay: []u8, message: []u8 },
    publish_ack: struct { relay: []u8, event_id: []u8, accepted: bool, message: []u8 },
    disconnect: struct { url: []u8, reason: []u8 },
    failure: struct { relay: []u8, message: []u8 },
    shutdown_complete,

    pub fn deinit(self: *PoolEvent, allocator: Allocator) void {
        switch (self.*) {
            .connected => |payload| allocator.free(payload.url),
            .received => |payload| {
                allocator.free(payload.relay);
                allocator.free(payload.payload);
            },
            .eose => |payload| {
                allocator.free(payload.relay);
                allocator.free(payload.subscription);
            },
            .notice => |payload| {
                allocator.free(payload.relay);
                allocator.free(payload.message);
            },
            .publish_ack => |payload| {
                allocator.free(payload.relay);
                allocator.free(payload.event_id);
                allocator.free(payload.message);
            },
            .disconnect => |payload| {
                allocator.free(payload.url);
                allocator.free(payload.reason);
            },
            .failure => |payload| {
                allocator.free(payload.relay);
                allocator.free(payload.message);
            },
            .shutdown_complete => {},
        }
    }
};

/// High-level relay pool that manages websocket clients on a worker thread.
pub const RelayPool = struct {
    allocator: Allocator,
    commands: *ThreadQueue(PoolCommand),
    events: *ThreadQueue(PoolEvent),
    worker_state: *WorkerState,
    worker: std.Thread,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        const commands_ptr = try allocator.create(ThreadQueue(PoolCommand));
        errdefer allocator.destroy(commands_ptr);
        commands_ptr.* = ThreadQueue(PoolCommand).init(allocator);

        const events_ptr = try allocator.create(ThreadQueue(PoolEvent));
        errdefer allocator.destroy(events_ptr);
        events_ptr.* = ThreadQueue(PoolEvent).init(allocator);

        const worker_state = try allocator.create(WorkerState);
        errdefer allocator.destroy(worker_state);

        worker_state.* = .{
            .allocator = allocator,
            .commands = commands_ptr,
            .events = events_ptr,
        };

        const worker_thread = try std.Thread.spawn(.{}, workerMain, .{worker_state});

        return .{
            .allocator = allocator,
            .commands = commands_ptr,
            .events = events_ptr,
            .worker_state = worker_state,
            .worker = worker_thread,
        };
    }

    pub fn deinit(self: *Self) void {
        const cmd = PoolCommand{ .shutdown = void{} };
        self.commands.push(cmd) catch {};
        self.worker.join();
        self.worker_state.deinit();
        self.allocator.destroy(self.worker_state);
        self.commands.deinit();
        self.events.deinit();
        self.allocator.destroy(self.commands);
        self.allocator.destroy(self.events);
    }

    pub fn addRelay(self: *Self, url: []const u8, subscriptions: []const SubscriptionSpec) !void {
        const owned_url = try self.allocator.dupe(u8, url);
        const owned_subs = try self.allocator.alloc(Subscription, subscriptions.len);
        for (subscriptions, 0..) |spec, idx| {
            owned_subs[idx] = try Subscription.clone(spec, self.allocator);
        }
        const command = PoolCommand{ .add_relay = .{ .url = owned_url, .subscriptions = owned_subs } };
        try self.commands.push(command);
    }

    pub fn publish(self: *Self, relays: []const []const u8, payload: []const u8) !void {
        var owned_relays = try self.allocator.alloc([]u8, relays.len);
        for (relays, 0..) |relay, idx| {
            owned_relays[idx] = try self.allocator.dupe(u8, relay);
        }
        const owned_payload = try self.allocator.dupe(u8, payload);
        const command = PoolCommand{ .publish = .{ .relays = owned_relays, .payload = owned_payload } };
        try self.commands.push(command);
    }

    pub fn pollEvent(self: *Self) ?PoolEvent {
        return self.events.pop();
    }

    pub fn waitEvent(self: *Self) PoolEvent {
        return self.events.wait();
    }
};

/// Shared state owned by the worker thread.
const WorkerState = struct {
    allocator: Allocator,
    commands: *ThreadQueue(PoolCommand),
    events: *ThreadQueue(PoolEvent),
    running: bool = true,

    fn deinit(self: *WorkerState) void {
        _ = self;
    }

    fn pushEvent(self: *WorkerState, event: PoolEvent) void {
        self.events.push(event) catch {
            var tmp = event;
            tmp.deinit(self.allocator);
        };
    }

    fn run(self: *WorkerState) !void {
        var clients = std.StringHashMap(*ClientState).init(self.allocator);
        defer {
            var it = clients.iterator();
            while (it.next()) |entry| {
                cleanupClient(self.allocator, entry.value_ptr.*);
            }
            clients.deinit();
        }

        while (self.running) {
            while (self.commands.pop()) |command_value| {
                var command = command_value;
                defer command.deinit(self.allocator);

                switch (command) {
                    .add_relay => |payload| try self.handleAddRelay(&clients, payload),
                    .publish => |payload| try self.handlePublish(&clients, payload),
                    .shutdown => self.running = false,
                }

                if (!self.running) break;
            }

            if (!self.running) break;

            try self.pollRelays(&clients);
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }

        self.pushEvent(PoolEvent{ .shutdown_complete = {} });
    }

    fn reportError(self: *WorkerState, message: []const u8) void {
        const relay = self.allocator.dupe(u8, "relay-pool") catch return;
        const msg = self.allocator.dupe(u8, message) catch {
            self.allocator.free(relay);
            return;
        };
        self.pushEvent(PoolEvent{ .failure = .{ .relay = relay, .message = msg } });
    }

    fn handleAddRelay(self: *WorkerState, clients: *std.StringHashMap(*ClientState), payload: AddRelayCommand) !void {
        const norm = try normalizeUrl(self.allocator, payload.url);
        defer self.allocator.free(norm);

        if (clients.get(norm)) |client_ptr| {
            try self.sendSubscriptions(client_ptr, payload.subscriptions);
            const url_copy = try dup(self.allocator, client_ptr.url);
            self.pushEvent(PoolEvent{ .connected = .{ .url = url_copy } });
            return;
        }

        var parsed = try parseUrl(self.allocator, payload.url);
        defer parsed.deinit(self.allocator);

        var client = try websocket.Client.init(self.allocator, .{
            .host = parsed.host,
            .port = parsed.port,
            .tls = parsed.use_tls,
            .buffer_size = 4096,
            .max_size = 65536,
        });
        errdefer client.deinit();

        var host_buf: [256]u8 = undefined;
        const host_header = hostHeader(&host_buf, parsed.host, parsed.port, parsed.use_tls) catch parsed.host;

        const handshake_headers = try std.fmt.allocPrint(self.allocator, "Host: {s}\r\nUser-Agent: cli-feed\r\n", .{host_header});
        defer self.allocator.free(handshake_headers);

        try client.handshake(parsed.path, .{ .headers = handshake_headers });
        try client.readTimeout(0);

        const client_state = try self.allocator.create(ClientState);
        client_state.* = .{
            .url = try dup(self.allocator, payload.url),
            .host = try dup(self.allocator, parsed.host),
            .path = try dup(self.allocator, parsed.path),
            .port = parsed.port,
            .use_tls = parsed.use_tls,
            .client = client,
        };

        try clients.put(norm, client_state);
        try self.sendSubscriptions(client_state, payload.subscriptions);
        const url_copy = try dup(self.allocator, client_state.url);
        self.pushEvent(PoolEvent{ .connected = .{ .url = url_copy } });
    }

    fn handlePublish(self: *WorkerState, clients: *std.StringHashMap(*ClientState), payload: PublishCommand) !void {
        for (payload.relays) |relay| {
            const norm = try normalizeUrl(self.allocator, relay);
            defer self.allocator.free(norm);
            if (clients.get(norm)) |client_state| {
                const message = try std.fmt.allocPrint(self.allocator, "[\"EVENT\",{s}]", .{payload.payload});
                defer self.allocator.free(message);
                try sendMutable(&client_state.client, message, self.allocator);
            } else {
                const relay_copy = try dup(self.allocator, relay);
                const msg_copy = try dup(self.allocator, "relay not connected");
                self.pushEvent(PoolEvent{ .failure = .{ .relay = relay_copy, .message = msg_copy } });
            }
        }
    }

    fn pollRelays(self: *WorkerState, clients: *std.StringHashMap(*ClientState)) !void {
        var removals = std.ArrayListAligned([]const u8, null).empty;
        defer removals.deinit(self.allocator);

        var it = clients.iterator();
        while (it.next()) |entry| {
            const client_state = entry.value_ptr.*;
            const key = entry.key_ptr.*;
            handleClientMessage(self, client_state) catch |err| switch (err) {
                error.WouldBlock => {},
                error.Closed, error.ConnectionResetByPeer => {
                    const url_copy = try dup(self.allocator, client_state.url);
                    const reason_copy = try dup(self.allocator, @errorName(err));
                    self.pushEvent(PoolEvent{ .disconnect = .{ .url = url_copy, .reason = reason_copy } });
                    cleanupClient(self.allocator, client_state);
                    try removals.append(self.allocator, key);
                },
                else => {
                    const text = std.fmt.allocPrint(self.allocator, "client error: {s}", .{@errorName(err)}) catch "error";
                    defer if (text.ptr != "error".ptr) self.allocator.free(text);
                    const relay_copy = try dup(self.allocator, client_state.url);
                    const msg_copy = if (text.ptr == "error".ptr)
                        try dup(self.allocator, "client error")
                    else
                        try dup(self.allocator, text);
                    self.pushEvent(PoolEvent{ .failure = .{ .relay = relay_copy, .message = msg_copy } });
                },
            };
        }

        for (removals.items) |key| {
            _ = clients.remove(key);
        }
    }

    fn sendSubscriptions(self: *WorkerState, client_state: *ClientState, subscriptions: []Subscription) !void {
        for (subscriptions) |sub| {
            const message = try std.fmt.allocPrint(self.allocator, "[\"REQ\",\"{s}\",{s}]", .{ sub.subscription_id, sub.filters_json });
            defer self.allocator.free(message);
            try sendMutable(&client_state.client, message, self.allocator);
        }
    }
};

/// Internal representation of an active websocket relay connection.
const ClientState = struct {
    url: []u8,
    host: []u8,
    path: []u8,
    port: u16,
    use_tls: bool,
    client: websocket.Client,
};

fn cleanupClient(allocator: Allocator, client: *ClientState) void {
    client.client.close(.{}) catch {};
    client.client.deinit();
    allocator.free(client.url);
    allocator.free(client.host);
    allocator.free(client.path);
    allocator.destroy(client);
}

fn sendMutable(client: *websocket.Client, message: []const u8, allocator: Allocator) !void {
    const buffer = try allocator.dupe(u8, message);
    defer allocator.free(buffer);
    try client.write(buffer);
}

fn handleClientMessage(state: *WorkerState, client_state: *ClientState) !void {
    const msg = (try client_state.client.read()) orelse return error.WouldBlock;
    defer client_state.client.done(msg);

    switch (msg.type) {
        .text => try handleTextFrame(state, client_state, msg.data),
        .binary => {},
        .ping => try client_state.client.writePong(&[_]u8{}),
        .pong => {},
        .close => return error.Closed,
    }
}

fn handleTextFrame(state: *WorkerState, client_state: *ClientState, data: []u8) !void {
    const trimmed = std.mem.trim(u8, data, " \n\r\t");
    if (trimmed.len == 0) return;

    if (std.mem.startsWith(u8, trimmed, "[\"EVENT\"")) {
        const relay_copy = try dup(state.allocator, client_state.url);
        const payload_copy = try dup(state.allocator, trimmed);
        state.pushEvent(PoolEvent{ .received = .{ .relay = relay_copy, .payload = payload_copy } });
        return;
    }

    if (std.mem.startsWith(u8, trimmed, "[\"EOSE\"")) {
        const relay_copy = try dup(state.allocator, client_state.url);
        const sub_copy = extractQuotedValue(state.allocator, trimmed, 1) catch |err| switch (err) {
            error.NotFound => {
                const msg_copy = try dup(state.allocator, "malformed EOSE");
                state.pushEvent(PoolEvent{ .notice = .{ .relay = relay_copy, .message = msg_copy } });
                return;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        state.pushEvent(PoolEvent{ .eose = .{ .relay = relay_copy, .subscription = sub_copy } });
        return;
    }

    if (std.mem.startsWith(u8, trimmed, "[\"NOTICE\"")) {
        const relay_copy = try dup(state.allocator, client_state.url);
        const msg_copy = try dup(state.allocator, trimmed);
        state.pushEvent(PoolEvent{ .notice = .{ .relay = relay_copy, .message = msg_copy } });
        return;
    }

    if (std.mem.startsWith(u8, trimmed, "[\"OK\"")) {
        const relay_copy = try dup(state.allocator, client_state.url);
        const event_id = extractQuotedValue(state.allocator, trimmed, 1) catch |err| switch (err) {
            error.NotFound => {
                const msg_copy = try dup(state.allocator, "malformed OK message");
                state.pushEvent(PoolEvent{ .notice = .{ .relay = relay_copy, .message = msg_copy } });
                return;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        const message_value = extractQuotedValue(state.allocator, trimmed, 3) catch |err| switch (err) {
            error.NotFound => try dup(state.allocator, ""),
            error.OutOfMemory => return error.OutOfMemory,
        };
        const accepted = std.mem.indexOf(u8, trimmed, ",true") != null;
        state.pushEvent(PoolEvent{ .publish_ack = .{
            .relay = relay_copy,
            .event_id = event_id,
            .accepted = accepted,
            .message = message_value,
        } });
        return;
    }

    const relay_copy = try dup(state.allocator, client_state.url);
    const msg_copy = try dup(state.allocator, trimmed);
    state.pushEvent(PoolEvent{ .notice = .{ .relay = relay_copy, .message = msg_copy } });
}

fn extractQuotedValue(allocator: Allocator, data: []const u8, index: usize) error{ NotFound, OutOfMemory }![]u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == '"') {
            const start = i + 1;
            i += 1;
            while (i < data.len and data[i] != '"') : (i += 1) {}
            if (count == index) {
                return allocator.dupe(u8, data[start..i]);
            }
            count += 1;
        }
    }
    return error.NotFound;
}

fn dup(allocator: Allocator, slice: []const u8) ![]u8 {
    return allocator.dupe(u8, slice);
}

/// Parsed components from a websocket URL.
const ParsedUrl = struct {
    host: []u8,
    path: []u8,
    port: u16,
    use_tls: bool,

    fn deinit(self: *ParsedUrl, allocator: Allocator) void {
        allocator.free(self.host);
        allocator.free(self.path);
    }
};

fn parseUrl(allocator: Allocator, url: []const u8) !ParsedUrl {
    const ws_prefix = "ws://";
    const wss_prefix = "wss://";
    var rest: []const u8 = undefined;
    var use_tls = false;
    if (std.mem.startsWith(u8, url, ws_prefix)) {
        rest = url[ws_prefix.len..];
    } else if (std.mem.startsWith(u8, url, wss_prefix)) {
        rest = url[wss_prefix.len..];
        use_tls = true;
    } else return error.UnsupportedScheme;

    const slash_index = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash_index];
    const path = if (slash_index < rest.len) rest[slash_index..] else "/";

    var host_slice = authority;
    var port: u16 = if (use_tls) 443 else 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |idx| {
        host_slice = authority[0..idx];
        port = std.fmt.parseInt(u16, authority[idx + 1 ..], 10) catch port;
    }

    return ParsedUrl{
        .host = try allocator.dupe(u8, host_slice),
        .path = try allocator.dupe(u8, path),
        .port = port,
        .use_tls = use_tls,
    };
}

fn hostHeader(buf: []u8, host: []const u8, port: u16, use_tls: bool) ![]const u8 {
    const default_port: u16 = if (use_tls) 443 else 80;
    if (port == default_port) return host;
    return try std.fmt.bufPrint(buf, "{s}:{d}", .{ host, port });
}

fn normalizeUrl(allocator: Allocator, url: []const u8) ![]u8 {
    var parsed = try parseUrl(allocator, url);
    defer parsed.deinit(allocator);

    const scheme = if (parsed.use_tls) "wss" else "ws";
    const default_port: u16 = if (parsed.use_tls) 443 else 80;

    const host_lower = try allocator.dupe(u8, parsed.host);
    defer allocator.free(host_lower);
    _ = std.ascii.lowerString(host_lower, host_lower);

    if (parsed.port == default_port) {
        return std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{ scheme, host_lower, parsed.path });
    } else {
        return std.fmt.allocPrint(allocator, "{s}://{s}:{d}{s}", .{ scheme, host_lower, parsed.port, parsed.path });
    }
}

fn workerMain(state: *WorkerState) void {
    state.run() catch |err| {
        state.reportError(@errorName(err));
    };
}
