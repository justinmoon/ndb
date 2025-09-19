// Profile field accessor shim to work around Zig/C alignment issues
// This provides exported functions to access flatbuffer profile fields

#include "../nostrdb/src/bindings/c/flatbuffers_common_reader.h"
#include "../nostrdb/src/bindings/c/profile_reader.h"
#include <stddef.h>

// Export functions to access NdbProfileRecord fields
const void* ndb_profile_record_profile(const void* record) {
    if (!record) return NULL;
    // The record is actually a flatbuffer buffer, we need to get the root table
    NdbProfileRecord_table_t rec = NdbProfileRecord_as_root(record);
    if (!rec) return NULL;
    NdbProfile_table_t prof = NdbProfileRecord_profile(rec);
    return prof;
}

uint64_t ndb_profile_record_note_key(const void* record) {
    if (!record) return 0;
    NdbProfileRecord_table_t rec = NdbProfileRecord_as_root(record);
    if (!rec) return 0;
    return NdbProfileRecord_note_key(rec);
}

const char* ndb_profile_record_lnurl(const void* record) {
    if (!record) return NULL;
    NdbProfileRecord_table_t rec = NdbProfileRecord_as_root(record);
    if (!rec) return NULL;
    return NdbProfileRecord_lnurl(rec);
}

// Export functions to access NdbProfile fields
const char* ndb_profile_name(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_name(prof);
}

const char* ndb_profile_website(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_website(prof);
}

const char* ndb_profile_about(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_about(prof);
}

const char* ndb_profile_lud16(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_lud16(prof);
}

const char* ndb_profile_banner(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_banner(prof);
}

const char* ndb_profile_display_name(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_display_name(prof);
}

const char* ndb_profile_picture(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_picture(prof);
}

const char* ndb_profile_nip05(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_nip05(prof);
}

const char* ndb_profile_lud06(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_lud06(prof);
}

int ndb_profile_reactions(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_reactions(prof);
}

int32_t ndb_profile_damus_donation(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_damus_donation(prof);
}

int32_t ndb_profile_damus_donation_v2(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_damus_donation_v2(prof);
}

// Validate that a profile record buffer is a valid flatbuffer
int ndb_profile_record_is_valid(const void* record, size_t len) {
    if (!record || len < 8) return 0;  // Min flatbuffer size
    
    const uint8_t* buffer = (const uint8_t*)record;
    
    // Check root offset is within bounds
    // Flatbuffers start with a 4-byte offset to the root table
    uint32_t root_offset = *(uint32_t*)buffer;
    if (root_offset + 4 > len) return 0;
    
    // The root table is at buffer + root_offset + 4
    // (the +4 skips past the offset itself)
    const uint8_t* root_table = buffer + root_offset + 4;
    if ((size_t)(root_table - buffer) >= len) return 0;
    
    // Check vtable offset (first field of table)
    // This is a signed offset pointing backwards to the vtable
    int32_t vtable_soffset = *(int32_t*)root_table;
    if (vtable_soffset >= 0) return 0;  // Must be negative (points backwards)
    
    const uint8_t* vtable = root_table - vtable_soffset;
    if (vtable < buffer || (size_t)(vtable - buffer) >= len) return 0;
    
    // Check vtable size (first field of vtable)
    uint16_t vtable_size = *(uint16_t*)vtable;
    if (vtable_size < 4) return 0;  // Min vtable size (size + object_size)
    if ((size_t)(vtable - buffer) + vtable_size > len) return 0;
    
    // Try to actually parse it as a ProfileRecord to be sure
    NdbProfileRecord_table_t rec = NdbProfileRecord_as_root(record);
    if (!rec) return 0;
    
    return 1;  // Valid flatbuffer
}