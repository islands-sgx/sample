/* SQLITE_OS_OTHER=1 with a heap-backed VFS for in-memory SQL. */
#include "enclave_t.h"

#include <stdint.h>
#include <string.h>
#include <stdlib.h>

#include "sgx_trts.h"
#include "sqlite3.h"

typedef struct MemFile {
    sqlite3_file base;
    unsigned char *data;
    sqlite3_int64 size;     /* logical size */
    sqlite3_int64 capacity; /* allocated bytes */
} MemFile;

static int memClose(sqlite3_file *pFile)
{
    MemFile *p = (MemFile *)pFile;
    free(p->data);
    p->data = 0;
    p->size = 0;
    p->capacity = 0;
    return SQLITE_OK;
}

static int memRead(sqlite3_file *pFile, void *zBuf, int iAmt,
                   sqlite3_int64 iOfst)
{
    MemFile *p = (MemFile *)pFile;
    if (iOfst < 0 || iAmt < 0)
        return SQLITE_IOERR_READ;
    if (iOfst >= p->size) {
        memset(zBuf, 0, (size_t)iAmt);
        return SQLITE_IOERR_SHORT_READ;
    }
    {
        sqlite3_int64 avail = p->size - iOfst;
        int n = (avail >= (sqlite3_int64)iAmt) ? iAmt : (int)avail;
        memcpy(zBuf, p->data + iOfst, (size_t)n);
        if (n < iAmt) {
            memset((char *)zBuf + n, 0, (size_t)(iAmt - n));
            return SQLITE_IOERR_SHORT_READ;
        }
    }
    return SQLITE_OK;
}

static int memWrite(sqlite3_file *pFile, const void *zBuf, int iAmt,
                    sqlite3_int64 iOfst)
{
    MemFile *p = (MemFile *)pFile;
    sqlite3_int64 end;

    if (iOfst < 0 || iAmt < 0)
        return SQLITE_IOERR_WRITE;
    end = iOfst + (sqlite3_int64)iAmt;
    if (end > p->capacity) {
        sqlite3_int64 ncap = p->capacity ? p->capacity : 4096;
        unsigned char *nd;
        while (ncap < end)
            ncap *= 2;
        nd = (unsigned char *)realloc(p->data, (size_t)ncap);
        if (!nd)
            return SQLITE_IOERR_NOMEM;
        if (ncap > p->capacity)
            memset(nd + p->capacity, 0, (size_t)(ncap - p->capacity));
        p->data = nd;
        p->capacity = ncap;
    }
    memcpy(p->data + iOfst, zBuf, (size_t)iAmt);
    if (end > p->size)
        p->size = end;
    return SQLITE_OK;
}

static int memTruncate(sqlite3_file *pFile, sqlite3_int64 size)
{
    MemFile *p = (MemFile *)pFile;
    if (size < 0)
        return SQLITE_IOERR_TRUNCATE;
    if (size < p->size)
        p->size = size;
    return SQLITE_OK;
}

static int memSync(sqlite3_file *pFile, int flags)
{
    (void)pFile;
    (void)flags;
    return SQLITE_OK;
}

static int memFileSize(sqlite3_file *pFile, sqlite3_int64 *pSize)
{
    MemFile *p = (MemFile *)pFile;
    *pSize = p->size;
    return SQLITE_OK;
}

static int memLock(sqlite3_file *pFile, int eLock)
{
    (void)pFile;
    (void)eLock;
    return SQLITE_OK;
}

static int memUnlock(sqlite3_file *pFile, int eLock)
{
    (void)pFile;
    (void)eLock;
    return SQLITE_OK;
}

static int memCheckReservedLock(sqlite3_file *pFile, int *pResOut)
{
    (void)pFile;
    *pResOut = 0;
    return SQLITE_OK;
}

static int memFileControl(sqlite3_file *pFile, int op, void *pArg)
{
    (void)pFile;
    (void)op;
    (void)pArg;
    return SQLITE_NOTFOUND;
}

static int memSectorSize(sqlite3_file *pFile)
{
    (void)pFile;
    return 4096;
}

static int memDeviceCharacteristics(sqlite3_file *pFile)
{
    (void)pFile;
    return SQLITE_IOCAP_ATOMIC | SQLITE_IOCAP_SAFE_APPEND |
           SQLITE_IOCAP_SEQUENTIAL | SQLITE_IOCAP_POWERSAFE_OVERWRITE;
}

static const sqlite3_io_methods mem_io_methods = {
    1, /* iVersion */
    memClose,
    memRead,
    memWrite,
    memTruncate,
    memSync,
    memFileSize,
    memLock,
    memUnlock,
    memCheckReservedLock,
    memFileControl,
    memSectorSize,
    memDeviceCharacteristics,
    0, /* xShmMap */
    0, /* xShmLock */
    0, /* xShmBarrier */
    0, /* xShmUnmap */
    0, /* xFetch */
    0, /* xUnfetch */
};

static int memOpen(sqlite3_vfs *pVfs, const char *zName, sqlite3_file *pFile,
                   int flags, int *pOutFlags)
{
    MemFile *p = (MemFile *)pFile;
    (void)pVfs;
    (void)zName;

    memset(p, 0, sizeof(*p));
    p->base.pMethods = &mem_io_methods;

    if (pOutFlags)
        *pOutFlags = flags;
    return SQLITE_OK;
}

static int memDelete(sqlite3_vfs *pVfs, const char *zName, int syncDir)
{
    (void)pVfs;
    (void)zName;
    (void)syncDir;
    return SQLITE_OK;
}

static int memAccess(sqlite3_vfs *pVfs, const char *zName, int flags,
                     int *pResOut)
{
    (void)pVfs;
    (void)zName;
    (void)flags;
    /* No persistent files exist. */
    *pResOut = 0;
    return SQLITE_OK;
}

static int memFullPathname(sqlite3_vfs *pVfs, const char *zName, int nOut,
                           char *zOut)
{
    size_t n;
    (void)pVfs;
    if (!zName)
        zName = "";
    n = strlen(zName);
    if ((int)n >= nOut)
        return SQLITE_CANTOPEN;
    memcpy(zOut, zName, n + 1);
    return SQLITE_OK;
}

static void *memDlOpen(sqlite3_vfs *pVfs, const char *zFilename)
{
    (void)pVfs;
    (void)zFilename;
    return 0;
}

static void memDlError(sqlite3_vfs *pVfs, int nByte, char *zErrMsg)
{
    (void)pVfs;
    if (nByte > 0) {
        strncpy(zErrMsg, "dynamic loading disabled", (size_t)nByte - 1);
        zErrMsg[nByte - 1] = 0;
    }
}

static void (*memDlSym(sqlite3_vfs *pVfs, void *pH, const char *zSym))(void)
{
    (void)pVfs;
    (void)pH;
    (void)zSym;
    return 0;
}

static void memDlClose(sqlite3_vfs *pVfs, void *pHandle)
{
    (void)pVfs;
    (void)pHandle;
}

static int memRandomness(sqlite3_vfs *pVfs, int nByte, char *zOut)
{
    (void)pVfs;
    if (nByte <= 0)
        return 0;
    if (sgx_read_rand((unsigned char *)zOut, (size_t)nByte) != SGX_SUCCESS) {
        memset(zOut, 0, (size_t)nByte);
        return 0;
    }
    return nByte;
}

static int memSleep(sqlite3_vfs *pVfs, int microseconds)
{
    (void)pVfs;
    (void)microseconds;
    return microseconds;
}

/* Deterministic time in SQLite Julian-day milliseconds. */
static int memCurrentTimeInt64(sqlite3_vfs *pVfs, sqlite3_int64 *pTime)
{
    static const sqlite3_int64 unixEpoch = 24405875LL * 8640000LL;
    /* Fixed: 2024-01-01 00:00:00 UTC. */
    static const sqlite3_int64 fixed_unix_ms = 1704067200000LL;
    (void)pVfs;
    *pTime = unixEpoch + fixed_unix_ms;
    return SQLITE_OK;
}

static int memCurrentTime(sqlite3_vfs *pVfs, double *pTime)
{
    sqlite3_int64 i = 0;
    int rc = memCurrentTimeInt64(pVfs, &i);
    *pTime = (double)i / 86400000;
    return rc;
}

static int memGetLastError(sqlite3_vfs *pVfs, int nBuf, char *zBuf)
{
    (void)pVfs;
    if (nBuf > 0)
        zBuf[0] = 0;
    return 0;
}

static sqlite3_vfs g_mem_vfs = {
    2,                      /* v2 enables xCurrentTimeInt64 */
    sizeof(MemFile),        /* szOsFile */
    512,                    /* mxPathname */
    0,                      /* pNext */
    "enclave-mem",          /* zName */
    0,                      /* pAppData */
    memOpen,
    memDelete,
    memAccess,
    memFullPathname,
    memDlOpen,
    memDlError,
    memDlSym,
    memDlClose,
    memRandomness,
    memSleep,
    memCurrentTime,
    memGetLastError,
    memCurrentTimeInt64,
    0, /* xSetSystemCall */
    0, /* xGetSystemCall */
    0, /* xNextSystemCall */
};

/* Required OS hooks for SQLITE_OS_OTHER=1. */
int sqlite3_os_init(void)
{
    return sqlite3_vfs_register(&g_mem_vfs, /*makeDflt=*/1);
}

int sqlite3_os_end(void)
{
    return SQLITE_OK;
}

#define KAT_EXPECTED_SUM 300
#define KAT_EXPECTED_ROW_NUMBER 4
#define KAT_EXPECTED_DATE "2024-03-01"

static int exec_simple(sqlite3 *db, const char *sql)
{
    char *errmsg = 0;
    int rc = sqlite3_exec(db, sql, 0, 0, &errmsg);
    if (rc != SQLITE_OK) {
        if (errmsg)
            sqlite3_free(errmsg);
        return rc;
    }
    return SQLITE_OK;
}

static int query_int(sqlite3 *db, const char *sql, int expected)
{
    sqlite3_stmt *stmt = 0;
    int rc = sqlite3_prepare_v2(db, sql, -1, &stmt, 0);

    if (rc == SQLITE_OK && stmt) {
        rc = sqlite3_step(stmt);
        if (rc == SQLITE_ROW && sqlite3_column_int(stmt, 0) == expected)
            rc = SQLITE_OK;
        else
            rc = SQLITE_ERROR;
    }

    if (stmt) {
        int finalize_rc = sqlite3_finalize(stmt);
        if (rc == SQLITE_OK)
            rc = finalize_rc;
    }
    return rc;
}

static int query_text(sqlite3 *db, const char *sql, const char *expected)
{
    sqlite3_stmt *stmt = 0;
    int rc = sqlite3_prepare_v2(db, sql, -1, &stmt, 0);

    if (rc == SQLITE_OK && stmt) {
        const unsigned char *actual;

        rc = sqlite3_step(stmt);
        actual = rc == SQLITE_ROW ? sqlite3_column_text(stmt, 0) : 0;
        if (actual && strcmp((const char *)actual, expected) == 0)
            rc = SQLITE_OK;
        else
            rc = SQLITE_ERROR;
    }

    if (stmt) {
        int finalize_rc = sqlite3_finalize(stmt);
        if (rc == SQLITE_OK)
            rc = finalize_rc;
    }
    return rc;
}

int ecall_sql_selftest(void)
{
    sqlite3 *db = 0;
    int rc;
    int result = 1;

    rc = sqlite3_open_v2(
        ":memory:", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, 0);
    if (rc != SQLITE_OK || !db)
        goto done;

    /* Avoid journal I/O even with an in-memory VFS. */
    if (exec_simple(db, "PRAGMA journal_mode=OFF;") != SQLITE_OK)
        goto done;

    if (exec_simple(db,
                    "CREATE TABLE nums(n INTEGER PRIMARY KEY, v INTEGER);"
                    "INSERT INTO nums VALUES (1,10),(2,20),(3,30),(4,40);") !=
        SQLITE_OK)
        goto done;

    if (query_int(db, "SELECT sum(v * n) FROM nums;", KAT_EXPECTED_SUM) !=
        SQLITE_OK)
        goto done;

    if (query_int(db,
                  "SELECT row_number() OVER (ORDER BY n) "
                  "FROM nums ORDER BY n DESC LIMIT 1;",
                  KAT_EXPECTED_ROW_NUMBER) != SQLITE_OK)
        goto done;

    if (query_text(db, "SELECT date('2024-02-29', '+1 day');",
                   KAT_EXPECTED_DATE) != SQLITE_OK)
        goto done;

    result = 0;

done:
    if (db)
        sqlite3_close(db);
    return result;
}
