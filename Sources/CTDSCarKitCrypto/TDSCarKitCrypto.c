#include "TDSCarKitCrypto.h"
#include <CommonCrypto/CommonCryptor.h>
int tds_car_kit_aes_ctr(const uint8_t key[16], const uint8_t iv[16], const uint8_t *input, size_t count, uint8_t *output) {
    CCCryptorRef cryptor = NULL;
    CCCryptorStatus status = CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR, kCCAlgorithmAES,
        ccNoPadding, iv, key, 16, NULL, 0, 0, kCCModeOptionCTR_BE, &cryptor);
    if (status != kCCSuccess) return status;
    size_t written = 0;
    status = CCCryptorUpdate(cryptor, input, count, output, count, &written);
    CCCryptorRelease(cryptor);
    return status == kCCSuccess && written != count ? kCCDecodeError : status;
}
