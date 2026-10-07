/* transient.c for Windows targets, under its own name: nimony caches
 * compiled C objects by file name (~/.cache/nimony/nimcache_static), so a
 * file compiled for both the host and a cross target would hand one
 * toolchain's object to the other's link. */
#include "transient.c"
