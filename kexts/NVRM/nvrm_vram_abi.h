/*
 * NullMoth NVIDIA driver for macOS
 * Copyright (c) 2026 NullMoth Systems.
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#define NVRM_VRAM_ABI_VERSION 2u
#define NVRM_VRAM_FN_ALLOC    "nvAllocVram"
#define NVRM_VRAM_FN_FREE     "nvFreeVram"

#define NVRM_VRAM_FN_SCANOUT  "nvScanoutInfo"

#define NVRM_VRAM_BAR1_BUDGET (192ull * 1024ull * 1024ull)

/* flags on nvAllocVram / nvFreeVram. UNMAPPED_OK (in): the caller can hold VRAM that has no BAR1 mapping (kva NULL,
   phys 0); it reaches the memory only through its RM handle (zero-copy share, flips, copy-engine page-off). UNMAPPED
   (out on a grant, in on a free): this allocation has no BAR1 mapping. A 256 MB BAR1 holds about ten window surfaces;
   VRAM itself holds thousands. */
#define NVRM_VRAM_FLAG_UNMAPPED_OK 0x1u
#define NVRM_VRAM_FLAG_UNMAPPED    0x2u

struct NVRMVramRequest {
    unsigned int       version;
    unsigned int       flags;
    unsigned long long size;
    unsigned long long actualSize;
    unsigned long long phys;
    void              *kva;
    void              *handle;
    unsigned long long mappedTotal;
    unsigned int width, height, pitch;
    unsigned long long allocationCookie;
};
