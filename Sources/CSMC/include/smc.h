#ifndef CHARGECAP_SMC_H
#define CHARGECAP_SMC_H

#include <stdint.h>
#include <IOKit/IOKitLib.h>

#define SMC_MAX_BYTES 32

// Result of reading one SMC key.
typedef struct {
    uint32_t data_type;   // four-char type code, e.g. 'ui32', 'ui8 ', 'hex_'
    uint32_t data_size;   // number of valid bytes in `bytes`
    uint8_t bytes[SMC_MAX_BYTES];
} smc_value_t;

// Error codes returned in addition to kern_return_t failures.
enum {
    SMC_OK = 0,
    SMC_ERR_OPEN = -1,       // AppleSMC service not found or could not be opened
    SMC_ERR_CALL = -2,       // IOConnectCallStructMethod failed (see errno-like kr in *kr_out)
    SMC_ERR_KEY = -3,        // SMC reported an error for this key (e.g. key not found)
    SMC_ERR_SIZE = -4,       // write size does not match the key's declared size
};

int smc_open(io_connect_t *conn);
void smc_close(io_connect_t conn);

// `key` must point to exactly four characters (no terminator needed).
// On SMC_ERR_CALL / SMC_ERR_KEY, *detail_out holds the kern_return_t or SMC result byte.
int smc_read_key(io_connect_t conn, const char *key, smc_value_t *out, int *detail_out);
int smc_write_key(io_connect_t conn, const char *key, const uint8_t *bytes, uint32_t size, int *detail_out);

// Write the four-char name of the key at `index` (0 ..< value of "#KEY") into key_out[0..3].
int smc_key_at_index(io_connect_t conn, uint32_t index, char key_out[4], int *detail_out);

#endif
