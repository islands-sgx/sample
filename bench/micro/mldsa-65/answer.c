#include <stddef.h>
#include <stdint.h>

const uint8_t *sample_answer(size_t *size)
{
    static const uint8_t verified = 0xa5;
    *size = sizeof(verified);
    return &verified;
}
