// Tiny atomic helpers for Swift: Swift's own Atomic type needs macOS 15, and Couchwire runs on 14.
// Used by the audio rings, whose real-time read side must never wait on a lock.
#pragma once

#include <stdint.h>

/// Loads a counter written by another thread (acquire: what was written before its store is visible).
static inline int64_t cw_atomic_load(const int64_t *p)
{
	return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}

/// Publishes a counter to another thread (release: everything written before it is visible there).
static inline void cw_atomic_store(int64_t *p, int64_t value)
{
	__atomic_store_n(p, value, __ATOMIC_RELEASE);
}
