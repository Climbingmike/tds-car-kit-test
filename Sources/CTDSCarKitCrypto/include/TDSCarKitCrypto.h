#ifndef TDS_CAR_KIT_CRYPTO_H
#define TDS_CAR_KIT_CRYPTO_H
#include <stddef.h>
#include <stdint.h>
int tds_car_kit_aes_ctr(const uint8_t key[16], const uint8_t iv[16], const uint8_t *input, size_t count, uint8_t *output);
#endif
