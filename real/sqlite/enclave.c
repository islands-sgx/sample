/* SQLITE_OS_OTHER=1 with a heap-backed VFS for in-memory SQL. */
#include "sqlite_enclave_t.h"

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


static sqlite3 *g_db = 0;
static int g_db_id = 0;

static int exec_sql(sqlite3 *db, const char *sql)
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

sgx_status_t ecall_db_open(int page_mode, int *out_db_id)
{
    if (!out_db_id || page_mode < 0 || page_mode > 2)
        return SGX_ERROR_INVALID_PARAMETER;

    if (g_db) {
        sqlite3_close(g_db);
        g_db = 0;
    }

    int rc = sqlite3_open_v2(
        ":memory:", &g_db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, 0);
    if (rc != SQLITE_OK || !g_db)
        return SGX_ERROR_UNEXPECTED;

    if (exec_sql(g_db,
                 "PRAGMA journal_mode=MEMORY;"
                 "PRAGMA synchronous=OFF;"
                 "PRAGMA temp_store=MEMORY;"
                 "CREATE TABLE accounts(id INTEGER PRIMARY KEY, grp INTEGER, balance INTEGER, tag TEXT);"
                 "CREATE TABLE audit_log(seq INTEGER PRIMARY KEY AUTOINCREMENT, acct_id INTEGER, delta INTEGER);") != SQLITE_OK) {
        sqlite3_close(g_db);
        g_db = 0;
        return SGX_ERROR_UNEXPECTED;
    }

    g_db_id = 1;
    *out_db_id = g_db_id;
    return SGX_SUCCESS;
}

ATFIELD sgx_status_t sqlite_exec_batch_field(
    int op_mode,
    const int *row_ids,
    const int *row_vals,
    size_t row_count,
    int *out_affected)
{
    if (op_mode == 0) {
        sqlite3_stmt *stmt_acc = 0;
        sqlite3_stmt *stmt_log = 0;
        if (exec_sql(g_db, "BEGIN IMMEDIATE;") != SQLITE_OK)
            return SGX_ERROR_UNEXPECTED;
        if (sqlite3_prepare_v2(
                g_db,
                "INSERT OR REPLACE INTO accounts(id, grp, balance, tag) "
                "VALUES(?1, ?2, ?3, printf('acct-%06d', ?1));",
                -1, &stmt_acc, 0) != SQLITE_OK) {
            exec_sql(g_db, "ROLLBACK;");
            return SGX_ERROR_UNEXPECTED;
        }
        if (sqlite3_prepare_v2(
                g_db,
                "INSERT INTO audit_log(acct_id, delta) VALUES(?1, ?2);",
                -1, &stmt_log, 0) != SQLITE_OK) {
            sqlite3_finalize(stmt_acc);
            exec_sql(g_db, "ROLLBACK;");
            return SGX_ERROR_UNEXPECTED;
        }
        int affected = 0;
        for (size_t i = 0; i < row_count; i++) {
            int id = (int)((unsigned int)row_ids[i] & 0x7fffU) + (int)i + 1;
            int grp = id & 3;
            int bal = (row_vals[i] % 10000);
            if (bal < 0) bal = -bal;
            sqlite3_bind_int(stmt_acc, 1, id);
            sqlite3_bind_int(stmt_acc, 2, grp);
            sqlite3_bind_int(stmt_acc, 3, bal);
            if (sqlite3_step(stmt_acc) != SQLITE_DONE) {
                sqlite3_finalize(stmt_acc);
                sqlite3_finalize(stmt_log);
                exec_sql(g_db, "ROLLBACK;");
                return SGX_ERROR_UNEXPECTED;
            }
            sqlite3_reset(stmt_acc);

            sqlite3_bind_int(stmt_log, 1, id);
            sqlite3_bind_int(stmt_log, 2, bal);
            if (sqlite3_step(stmt_log) != SQLITE_DONE) {
                sqlite3_finalize(stmt_acc);
                sqlite3_finalize(stmt_log);
                exec_sql(g_db, "ROLLBACK;");
                return SGX_ERROR_UNEXPECTED;
            }
            sqlite3_reset(stmt_log);
            affected++;
        }
        sqlite3_finalize(stmt_acc);
        sqlite3_finalize(stmt_log);
        if (exec_sql(g_db, "COMMIT;") != SQLITE_OK)
            return SGX_ERROR_UNEXPECTED;
        *out_affected = affected;
        return SGX_SUCCESS;
    } else if (op_mode == 1) {
        sqlite3_stmt *stmt_upd = 0;
        if (exec_sql(g_db,
                     "BEGIN IMMEDIATE;"
                     "CREATE INDEX IF NOT EXISTS idx_accounts_grp_bal ON accounts(grp, balance);") != SQLITE_OK)
            return SGX_ERROR_UNEXPECTED;
        if (sqlite3_prepare_v2(
                g_db,
                "UPDATE accounts SET balance = balance + ?2 WHERE id = ?1;",
                -1, &stmt_upd, 0) != SQLITE_OK) {
            exec_sql(g_db, "ROLLBACK;");
            return SGX_ERROR_UNEXPECTED;
        }
        int affected = 0;
        for (size_t i = 0; i < row_count; i++) {
            int id = (int)((unsigned int)row_ids[i] & 0x7fffU) + (int)i + 1;
            int delta = (row_vals[i] % 500);
            sqlite3_bind_int(stmt_upd, 1, id);
            sqlite3_bind_int(stmt_upd, 2, delta);
            if (sqlite3_step(stmt_upd) != SQLITE_DONE) {
                sqlite3_finalize(stmt_upd);
                exec_sql(g_db, "ROLLBACK;");
                return SGX_ERROR_UNEXPECTED;
            }
            affected += sqlite3_changes(g_db);
            sqlite3_reset(stmt_upd);
        }
        sqlite3_finalize(stmt_upd);
        if (exec_sql(g_db, "COMMIT;") != SQLITE_OK)
            return SGX_ERROR_UNEXPECTED;
        *out_affected = affected;
        return SGX_SUCCESS;
    } else if (op_mode == 2) {
        if (exec_sql(g_db,
                     "SAVEPOINT sp_audit;"
                     "DELETE FROM audit_log WHERE (seq % 7) == 0;"
                     "RELEASE sp_audit;") != SQLITE_OK)
            return SGX_ERROR_UNEXPECTED;
        *out_affected = sqlite3_changes(g_db);
        return SGX_SUCCESS;
    }
    return SGX_ERROR_INVALID_PARAMETER;
}

sgx_status_t ecall_db_exec_batch(
    int db_id,
    int op_mode,
    const int *row_ids,
    const int *row_vals,
    size_t row_count,
    int *out_affected)
{
    if (!g_db || db_id != g_db_id || !row_ids || !row_vals || !out_affected)
        return SGX_ERROR_INVALID_PARAMETER;
    if (row_count == 0 || row_count > 16384 || op_mode < 0 || op_mode > 2)
        return SGX_ERROR_INVALID_PARAMETER;
    return sqlite_exec_batch_field(op_mode, row_ids, row_vals, row_count, out_affected);
}

ATFIELD sgx_status_t sqlite_query_stats_field(
    int query_mode,
    int filter_grp,
    int *out_count,
    long *out_sum,
    long *out_metric)
{
    sqlite3_stmt *stmt = 0;
    int rc = SQLITE_ERROR;

    if (query_mode == 0) {
        rc = sqlite3_prepare_v2(
            g_db,
            "SELECT count(*), coalesce(sum(balance), 0), coalesce(max(balance) - min(balance), 0) "
            "FROM accounts WHERE (?1 == 0 OR grp == (?1 - 1));",
            -1, &stmt, 0);
        if (rc != SQLITE_OK || !stmt)
            return SGX_ERROR_UNEXPECTED;
        sqlite3_bind_int(stmt, 1, filter_grp);
    } else if (query_mode == 1) {
        rc = sqlite3_prepare_v2(
            g_db,
            "SELECT count(*), coalesce(sum(sub.bal), 0), coalesce(max(sub.rnk), 0) FROM ("
            "  SELECT a.id AS id, a.balance AS bal, coalesce(sum(l.delta), 0) AS dsum, "
            "         row_number() OVER (PARTITION BY a.grp ORDER BY a.balance DESC, a.id ASC) AS rnk "
            "  FROM accounts a LEFT JOIN audit_log l ON a.id = l.acct_id "
            "  GROUP BY a.id ORDER BY a.balance DESC, a.id ASC"
            ") sub;",
            -1, &stmt, 0);
        if (rc != SQLITE_OK || !stmt)
            return SGX_ERROR_UNEXPECTED;
    } else if (query_mode == 2) {
        sqlite3_stmt *chk = 0;
        if (sqlite3_prepare_v2(g_db, "PRAGMA integrity_check;", -1, &chk, 0) != SQLITE_OK || !chk)
            return SGX_ERROR_UNEXPECTED;
        int chk_ok = 0;
        if (sqlite3_step(chk) == SQLITE_ROW) {
            const unsigned char *txt = sqlite3_column_text(chk, 0);
            if (txt && strcmp((const char *)txt, "ok") == 0)
                chk_ok = 1;
        }
        sqlite3_finalize(chk);
        if (!chk_ok)
            return SGX_ERROR_UNEXPECTED;

        rc = sqlite3_prepare_v2(
            g_db,
            "SELECT count(*), coalesce(sum(balance), 0), coalesce(length(group_concat(tag, ',')), 0) "
            "FROM accounts WHERE balance >= (SELECT coalesce(avg(balance), 0) FROM accounts);",
            -1, &stmt, 0);
        if (rc != SQLITE_OK || !stmt)
            return SGX_ERROR_UNEXPECTED;
    } else {
        return SGX_ERROR_INVALID_PARAMETER;
    }

    if (sqlite3_step(stmt) != SQLITE_ROW) {
        sqlite3_finalize(stmt);
        return SGX_ERROR_UNEXPECTED;
    }
    *out_count = sqlite3_column_int(stmt, 0);
    *out_sum = (long)sqlite3_column_int64(stmt, 1);
    *out_metric = (long)sqlite3_column_int64(stmt, 2);
    sqlite3_finalize(stmt);
    return SGX_SUCCESS;
}

sgx_status_t ecall_db_query_stats(
    int db_id,
    int query_mode,
    int filter_grp,
    int *out_count,
    long *out_sum,
    long *out_metric)
{
    if (!g_db || db_id != g_db_id || !out_count || !out_sum || !out_metric)
        return SGX_ERROR_INVALID_PARAMETER;
    if (query_mode < 0 || query_mode > 2 || filter_grp < 0 || filter_grp > 4)
        return SGX_ERROR_INVALID_PARAMETER;
    return sqlite_query_stats_field(query_mode, filter_grp, out_count, out_sum, out_metric);
}
