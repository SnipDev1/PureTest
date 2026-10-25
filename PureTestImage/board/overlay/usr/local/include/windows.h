/**
 * windows.h - Lightweight Windows/MSVC compatibility shim for PureTest bare-metal Linux.
 * Allows C/C++ programs written in Visual Studio to compile and run with g++ without code modifications.
 */
#ifndef _PURETEST_WINDOWS_COMPAT_H_
#define _PURETEST_WINDOWS_COMPAT_H_

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>
#include <math.h>

#ifdef __cplusplus
extern "C" {
#endif

/* -------------------------------------------------------------------------
 * Basic Windows Type Definitions
 * ------------------------------------------------------------------------- */
typedef double             DOUBLE;
typedef float              FLOAT;
typedef char               CHAR;
typedef unsigned char      UCHAR;
typedef unsigned char      BYTE;
typedef short              SHORT;
typedef unsigned short     USHORT;
typedef unsigned short     WORD;
typedef int                INT;
typedef unsigned int       UINT;
typedef int                BOOL;
typedef long               LONG;
typedef unsigned long      ULONG;
typedef uint32_t           DWORD;
typedef long long          LONGLONG;
typedef unsigned long long ULONGLONG;
typedef int64_t            INT64;
typedef uint64_t           UINT64;
typedef void*              HANDLE;
typedef void*              LPVOID;
typedef const void*        LPCVOID;
typedef char*              LPSTR;
typedef const char*        LPCSTR;
typedef void               VOID;

#ifndef TRUE
#define TRUE  1
#endif
#ifndef FALSE
#define FALSE 0
#endif

typedef union _LARGE_INTEGER {
    struct {
        DWORD LowPart;
        LONG  HighPart;
    };
    struct {
        DWORD LowPart;
        LONG  HighPart;
    } u;
    LONGLONG QuadPart;
} LARGE_INTEGER, *PLARGE_INTEGER;

/* -------------------------------------------------------------------------
 * Secure CRT Function Shims (printf_s, scanf_s, etc.)
 * ------------------------------------------------------------------------- */
#ifndef printf_s
#define printf_s printf
#endif

#ifndef scanf_s
#define scanf_s scanf
#endif

#ifndef sprintf_s
#define sprintf_s(buf, ...) snprintf((buf), sizeof(buf), __VA_ARGS__)
#endif

#ifndef sscanf_s
#define sscanf_s sscanf
#endif

#ifndef fprintf_s
#define fprintf_s fprintf
#endif

#ifndef fscanf_s
#define fscanf_s fscanf
#endif

#ifndef _stricmp
#define _stricmp strcasecmp
#endif

#ifndef stricmp
#define stricmp strcasecmp
#endif

#ifndef _strnicmp
#define _strnicmp strncasecmp
#endif

/* -------------------------------------------------------------------------
 * Memory and Utility Macros
 * ------------------------------------------------------------------------- */
#ifndef ZeroMemory
#define ZeroMemory(Destination, Length) memset((Destination), 0, (Length))
#endif

#ifndef CopyMemory
#define CopyMemory(Destination, Source, Length) memcpy((Destination), (Source), (Length))
#endif

#ifndef MoveMemory
#define MoveMemory(Destination, Source, Length) memmove((Destination), (Source), (Length))
#endif

#ifndef FillMemory
#define FillMemory(Destination, Length, Fill) memset((Destination), (Fill), (Length))
#endif

#ifndef min
#define min(a,b) (((a) < (b)) ? (a) : (b))
#endif

#ifndef max
#define max(a,b) (((a) > (b)) ? (a) : (b))
#endif

/* -------------------------------------------------------------------------
 * Windows API Emulation Functions (Sleep, Performance Counters, TickCount)
 * ------------------------------------------------------------------------- */
static inline void Sleep(DWORD dwMilliseconds) {
    struct timespec req;
    req.tv_sec = (time_t)(dwMilliseconds / 1000);
    req.tv_nsec = (long)((dwMilliseconds % 1000) * 1000000L);
    nanosleep(&req, NULL);
}

static inline DWORD GetTickCount(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (DWORD)(((ULONGLONG)ts.tv_sec * 1000ULL) + ((ULONGLONG)ts.tv_nsec / 1000000ULL));
}

static inline ULONGLONG GetTickCount64(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (ULONGLONG)((ts.tv_sec * 1000ULL) + (ts.tv_nsec / 1000000ULL));
}

static inline BOOL QueryPerformanceFrequency(LARGE_INTEGER *lpFrequency) {
    if (!lpFrequency) return FALSE;
    lpFrequency->QuadPart = 1000000000ULL; // Nanosecond resolution
    return TRUE;
}

static inline BOOL QueryPerformanceCounter(LARGE_INTEGER *lpPerformanceCount) {
    if (!lpPerformanceCount) return FALSE;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    lpPerformanceCount->QuadPart = (LONGLONG)(ts.tv_sec * 1000000000LL + ts.tv_nsec);
    return TRUE;
}

#ifdef __cplusplus
}
#endif

#endif /* _PURETEST_WINDOWS_COMPAT_H_ */
