# Relay Pool Work Plan

## References Consulted
- https://github.com/karlseguin/websocket.zig (client API, buffer provider, thread-safe writes)
- https://github.com/futurepaul/nostr_zig/blob/master/src/client.zig (relay message parsing, filter serialization)
- https://github.com/justinmoon/ssr/blob/master/core.zig (timeline fetch pipeline, websocket usage, request composition)

## Actor-Style Plan with Shared Worker Thread (Mutex-Protected Queues)
1. **Architecture Overview**
   - Spawn one dedicated relay pool worker thread responsible for all websocket clients. The thread owns a mutex-protected command queue fed by the main thread and pushes results through a second mutex-protected event queue back to the main thread. No per-client threads.
   - Each websocket client runs in non-blocking mode; the worker loops over active connections using `client.read()` with timeouts or `readLoop` variants that return without blocking indefinitely. On macOS/Linux the underlying sockets are non-blocking, so a simple round-robin read loop suffices; consider epoll/kqueue integration later if needed.
2. **Memory & Buffer Strategy**
   - Preallocate a 64 KiB arena per client using `std.heap.ArenaAllocator`. Allocate arenas lazily when relays are added, store pointers in `ClientState`. Reuse existing websocket.zig `buffer_provider` to handle occasional overflow: create a pool of N buffers (e.g. 4 × 64 KiB) shared across clients to avoid heap growth.
3. **Command API**
   - Define `Command` union enum: `{ AddRelay { url, filters? }, RemoveRelay { url }, UpdateFilters { url, filters }, Publish { relays, payload_bytes }, Shutdown }`. Main thread enqueues commands into the queue; worker thread drains and acts on them. Use generation counters or ack IDs in `Event` to confirm operations.
4. **Event Emission**
   - Define `Event` union enum: `FoundEvent { relay, payload_slice }, PublishAck { relay, event_id, ok, message }, Notice { relay, message }, Error { relay, code }, Debug { text }`. Worker pushes events immediately after processing; main thread polls the event queue each tick (or blocks on a condition variable signaled by the worker when new events arrive).
5. **Worker Loop**
   - The worker maintains `std.StringHashMap(ClientState)` and an array of active clients for iteration. Each tick:
     1. Drain incoming command queue, applying mutations (create/destroy `websocket.Client`, update filters, queue publish payloads).
     2. For each active client: write any pending payloads (REQs, EVENT publishes), then call `client.read()` with a small timeout. If a message arrives, emit appropriate `Event` and hand raw JSON to a nostrdb ingestion helper.
     3. Yield/sleep briefly when idle to avoid spinning.
   - `ClientState` stores: websocket client handle, normalized URL, `ArenaAllocator`, pending publish queue (`std.ArrayListUnmanaged([]u8)` storing allocations backed by the arena), active subscriptions/filter descriptors.
6. **Nostrdb Integration**
   - Main thread (or a dedicated ingestion helper) consumes `FoundEvent`, converting JSON payload to `[]const u8` and calling `ndb.Ndb.processEvent`. After storing, follow up with `ensureProcessed`. Logging remains on main thread for now.
7. **Shutdown Procedure**
   - Enqueue `Shutdown` command; worker drains commands, closes all websocket clients with `client.close(.{})`, deinitializes arenas and shared buffers, pushes a final `Event.ShutdownComplete`, then exits. Main thread joins the worker.
8. **Proof-of-Concept Flow**
   - `main.zig` initializes pool, adds three relays with shared filter (kinds, authors). It issues a REQ command and waits for `FoundEvent` events, verifying writes to nostrdb. Finally it enqueues a `Publish` command with a locally signed event and observes `PublishAck` before sending `Shutdown`.

This approach keeps threading simple (one worker thread), avoids per-connection threads, uses non-blocking reads, and leverages `std.atomic.Queue` for message passing while preserving deterministic memory usage.
