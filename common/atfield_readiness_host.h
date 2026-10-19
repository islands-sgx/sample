#ifndef ATFIELD_READINESS_HOST_H
#define ATFIELD_READINESS_HOST_H

#ifdef ATFIELD_PROTECT

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "atfield_readiness.h"

#ifndef ATFIELD_READY_PATH
#error "ATFIELD_READY_PATH must name the generated ReadyTable v3 file"
#endif

/* Install readiness immediately after enclave creation. Kernel mode is the
 * default; userspace mode requires an explicit environment selection. */
static inline int atfield_host_install_readiness(sgx_enclave_id_t enclave_id)
{
    const char *selection = getenv("ATFIELD_READINESS_BACKEND");
    atfield_readiness_backend_t backend = ATFIELD_READINESS_BACKEND_KERNEL;

    if (selection != NULL && selection[0] != '\0') {
        if (strcmp(selection, "userspace") == 0) {
            backend = ATFIELD_READINESS_BACKEND_USERSPACE;
        } else if (strcmp(selection, "kernel") != 0) {
            fprintf(stderr,
                    "ATFIELD_READINESS_BACKEND must be 'kernel' or 'userspace'\n");
            return 0;
        }
    }

    int system_error = 0;
    sgx_status_t status = atfield_install_readiness_file(
        enclave_id, ATFIELD_READY_PATH, backend, &system_error);
    if (status != SGX_SUCCESS) {
        fprintf(stderr,
                "atfield_install_readiness_file failed: status=0x%08x path=%s",
                (unsigned int)status, ATFIELD_READY_PATH);
        if (system_error != 0)
            fprintf(stderr, " error=%s", strerror(system_error));
        fputc('\n', stderr);
        return 0;
    }
    return 1;
}

#endif /* ATFIELD_PROTECT */

#endif /* ATFIELD_READINESS_HOST_H */
