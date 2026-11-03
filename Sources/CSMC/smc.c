#include "smc.h"

#include <string.h>

// Layout of the struct exchanged with the AppleSMC user client (selector 2).
// Field order and sizes must match the kernel driver exactly (80 bytes total).
typedef struct {
    char major;
    char minor;
    char build;
    char reserved;
    uint16_t release;
} smc_vers_t;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpu_plimit;
    uint32_t gpu_plimit;
    uint32_t mem_plimit;
} smc_plimit_t;

typedef struct {
    uint32_t data_size;
    uint32_t data_type;
    uint8_t data_attributes;
} smc_keyinfo_t;

typedef struct {
    uint32_t key;
    smc_vers_t vers;
    smc_plimit_t plimit;
    smc_keyinfo_t keyinfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[SMC_MAX_BYTES];
} smc_param_t;

_Static_assert(sizeof(smc_param_t) == 80, "AppleSMC parameter struct must be 80 bytes");

enum {
    kSMCHandleYPCEvent = 2,
    kSMCReadKey = 5,
    kSMCWriteKey = 6,
    kSMCGetKeyFromIndex = 8,
    kSMCGetKeyInfo = 9,
};

static uint32_t fourcc(const char *key) {
    return ((uint32_t)(uint8_t)key[0] << 24) | ((uint32_t)(uint8_t)key[1] << 16) |
           ((uint32_t)(uint8_t)key[2] << 8) | (uint32_t)(uint8_t)key[3];
}

static int smc_call(io_connect_t conn, smc_param_t *in, smc_param_t *out, int *detail_out) {
    size_t out_size = sizeof(*out);
    memset(out, 0, sizeof(*out));
    kern_return_t kr = IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, in, sizeof(*in), out, &out_size);
    if (kr != KERN_SUCCESS) {
        if (detail_out) *detail_out = kr;
        return SMC_ERR_CALL;
    }
    if (out->result != 0) {
        if (detail_out) *detail_out = out->result;
        return SMC_ERR_KEY;
    }
    return SMC_OK;
}

static int smc_key_info(io_connect_t conn, uint32_t key, smc_keyinfo_t *info, int *detail_out) {
    smc_param_t in, out;
    memset(&in, 0, sizeof(in));
    in.key = key;
    in.data8 = kSMCGetKeyInfo;
    int rc = smc_call(conn, &in, &out, detail_out);
    if (rc == SMC_OK) *info = out.keyinfo;
    return rc;
}

int smc_open(io_connect_t *conn) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return SMC_ERR_OPEN;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, conn);
    IOObjectRelease(service);
    return kr == KERN_SUCCESS ? SMC_OK : SMC_ERR_OPEN;
}

void smc_close(io_connect_t conn) {
    IOServiceClose(conn);
}

int smc_read_key(io_connect_t conn, const char *key, smc_value_t *out_value, int *detail_out) {
    uint32_t k = fourcc(key);
    smc_keyinfo_t info;
    int rc = smc_key_info(conn, k, &info, detail_out);
    if (rc != SMC_OK) return rc;

    smc_param_t in, out;
    memset(&in, 0, sizeof(in));
    in.key = k;
    in.keyinfo.data_size = info.data_size;
    in.data8 = kSMCReadKey;
    rc = smc_call(conn, &in, &out, detail_out);
    if (rc != SMC_OK) return rc;

    out_value->data_type = info.data_type;
    out_value->data_size = info.data_size > SMC_MAX_BYTES ? SMC_MAX_BYTES : info.data_size;
    memcpy(out_value->bytes, out.bytes, out_value->data_size);
    return SMC_OK;
}

int smc_key_at_index(io_connect_t conn, uint32_t index, char key_out[4], int *detail_out) {
    smc_param_t in, out;
    memset(&in, 0, sizeof(in));
    in.data8 = kSMCGetKeyFromIndex;
    in.data32 = index;
    int rc = smc_call(conn, &in, &out, detail_out);
    if (rc != SMC_OK) return rc;
    key_out[0] = (char)(out.key >> 24);
    key_out[1] = (char)(out.key >> 16);
    key_out[2] = (char)(out.key >> 8);
    key_out[3] = (char)out.key;
    return SMC_OK;
}

int smc_write_key(io_connect_t conn, const char *key, const uint8_t *bytes, uint32_t size, int *detail_out) {
    uint32_t k = fourcc(key);
    smc_keyinfo_t info;
    int rc = smc_key_info(conn, k, &info, detail_out);
    if (rc != SMC_OK) return rc;
    if (info.data_size != size || size > SMC_MAX_BYTES) {
        if (detail_out) *detail_out = (int)info.data_size;
        return SMC_ERR_SIZE;
    }

    smc_param_t in, out;
    memset(&in, 0, sizeof(in));
    in.key = k;
    in.keyinfo.data_size = size;
    in.data8 = kSMCWriteKey;
    memcpy(in.bytes, bytes, size);
    return smc_call(conn, &in, &out, detail_out);
}
