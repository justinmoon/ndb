const std = @import("std");
const c = @import("c").c;
const ndb = @import("ndb.zig");

// External C functions from profile_shim.c
extern fn ndb_profile_record_profile(record: *const anyopaque) ?*const anyopaque;
extern fn ndb_profile_record_note_key(record: *const anyopaque) u64;
extern fn ndb_profile_record_lnurl(record: *const anyopaque) ?[*:0]const u8;
extern fn ndb_profile_record_is_valid(record: *const anyopaque, len: usize) c_int;

extern fn ndb_profile_name(profile: *const anyopaque) ?[*:0]const u8;
extern fn ndb_profile_website(profile: *const anyopaque) ?[*:0]const u8;
extern fn ndb_profile_about(profile: *const anyopaque) ?[*:0]const u8;
extern fn ndb_profile_lud16(profile: *const anyopaque) ?[*:0]const u8;
extern fn ndb_profile_banner(profile: *const anyopaque) ?[*:0]const u8;
extern fn ndb_profile_display_name(profile: *const anyopaque) ?[*:0]const u8;
extern fn ndb_profile_picture(profile: *const anyopaque) ?[*:0]const u8;
extern fn ndb_profile_nip05(profile: *const anyopaque) ?[*:0]const u8;
extern fn ndb_profile_lud06(profile: *const anyopaque) ?[*:0]const u8;
extern fn ndb_profile_reactions(profile: *const anyopaque) c_int;
extern fn ndb_profile_damus_donation(profile: *const anyopaque) i32;
extern fn ndb_profile_damus_donation_v2(profile: *const anyopaque) i32;

pub const ProfileKey = struct {
    key: u64,

    pub fn new(key: u64) ProfileKey {
        return .{ .key = key };
    }

    pub fn asU64(self: ProfileKey) u64 {
        return self.key;
    }
};

pub const ProfileRecord = struct {
    ptr: *anyopaque,
    len: usize,
    primary_key: ProfileKey,
    txn: *ndb.Transaction,

    pub fn deinit(self: *ProfileRecord) void {
        _ = self;
    }

    pub fn isValid(self: ProfileRecord) bool {
        return ndb_profile_record_is_valid(self.ptr, self.len) != 0;
    }

    fn getProfile(self: ProfileRecord) !?*const anyopaque {
        try self.txn.ensureValid();
        // Get the profile from the record
        // The validation happens in isValid() which can be called separately
        // We don't validate here because the C library already returns valid data
        return ndb_profile_record_profile(self.ptr);
    }

    fn cStringToSlice(ptr: ?[*:0]const u8) ?[]const u8 {
        if (ptr) |p| {
            return std.mem.span(p);
        }
        return null;
    }

    pub fn name(self: ProfileRecord) !?[]const u8 {
        const profile = (try self.getProfile()) orelse return null;
        const name_ptr = ndb_profile_name(profile);
        return cStringToSlice(name_ptr);
    }

    pub fn displayName(self: ProfileRecord) !?[]const u8 {
        const profile = (try self.getProfile()) orelse return null;
        return cStringToSlice(ndb_profile_display_name(profile));
    }

    pub fn about(self: ProfileRecord) !?[]const u8 {
        const profile = (try self.getProfile()) orelse return null;
        return cStringToSlice(ndb_profile_about(profile));
    }

    pub fn website(self: ProfileRecord) !?[]const u8 {
        const profile = (try self.getProfile()) orelse return null;
        return cStringToSlice(ndb_profile_website(profile));
    }

    pub fn picture(self: ProfileRecord) !?[]const u8 {
        const profile = (try self.getProfile()) orelse return null;
        return cStringToSlice(ndb_profile_picture(profile));
    }

    pub fn banner(self: ProfileRecord) !?[]const u8 {
        const profile = (try self.getProfile()) orelse return null;
        return cStringToSlice(ndb_profile_banner(profile));
    }

    pub fn lud16(self: ProfileRecord) !?[]const u8 {
        const profile = (try self.getProfile()) orelse return null;
        return cStringToSlice(ndb_profile_lud16(profile));
    }

    pub fn nip05(self: ProfileRecord) !?[]const u8 {
        const profile = (try self.getProfile()) orelse return null;
        return cStringToSlice(ndb_profile_nip05(profile));
    }

    pub fn lud06(self: ProfileRecord) !?[]const u8 {
        const profile = (try self.getProfile()) orelse return null;
        return cStringToSlice(ndb_profile_lud06(profile));
    }

    pub fn reactions(self: ProfileRecord) !bool {
        const profile = (try self.getProfile()) orelse return true; // Default is true
        return ndb_profile_reactions(profile) != 0;
    }

    pub fn damusDonation(self: ProfileRecord) !i32 {
        const profile = (try self.getProfile()) orelse return 0;
        return ndb_profile_damus_donation(profile);
    }

    pub fn damusDonationV2(self: ProfileRecord) !i32 {
        const profile = (try self.getProfile()) orelse return 0;
        return ndb_profile_damus_donation_v2(profile);
    }

    pub fn noteKey(self: ProfileRecord) !u64 {
        try self.txn.ensureValid();
        return ndb_profile_record_note_key(self.ptr);
    }

    pub fn lnurl(self: ProfileRecord) !?[]const u8 {
        try self.txn.ensureValid();
        return cStringToSlice(ndb_profile_record_lnurl(self.ptr));
    }
};
