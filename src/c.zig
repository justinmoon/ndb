pub const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("nostrdb.h");
    @cInclude("nostr_bech32.h");
});
