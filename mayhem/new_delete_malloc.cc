// mayhem/new_delete_malloc.cc — global operator new/delete forwarding to malloc/free, linked into
// every fuzz binary (never into the functional-test build).
//
// Why: upstream fastp allocates arrays with new[] and frees them with scalar delete on EVERY run —
// SingleEndProcessor::processSingleEnd (`delete pack->data`, src/seprocessor.cpp, once per read pack)
// and Stats::~Stats (`delete iter->second` on the quality/content curves, src/stats.cpp, at the end of
// every SE and PE run). Under the fleet's halting ASan that is an alloc-dealloc-mismatch abort on every
// input, including the empty one, so no fastp target could fuzz at all. The mismatch is recorded as a
// finding (mayhem/fastp-se/known-findings/alloc-dealloc-mismatch/).
//
// These are the C++ standard's replaceable allocation functions; they are not fastp code. ASan
// intercepts malloc/free, so every new'd object keeps its redzones and quarantine: heap-buffer-overflow,
// use-after-free and double-free stay fully detected and halting. Only the new[]-vs-delete pairing check
// is lost. No ASan runtime option is set.
#include <cstdlib>
#include <new>

static void* fuzz_alloc(std::size_t n) {
    void* p = std::malloc(n ? n : 1);
    if (!p) throw std::bad_alloc();
    return p;
}

void* operator new(std::size_t n) { return fuzz_alloc(n); }
void* operator new[](std::size_t n) { return fuzz_alloc(n); }
void* operator new(std::size_t n, const std::nothrow_t&) noexcept { return std::malloc(n ? n : 1); }
void* operator new[](std::size_t n, const std::nothrow_t&) noexcept { return std::malloc(n ? n : 1); }
void operator delete(void* p) noexcept { std::free(p); }
void operator delete[](void* p) noexcept { std::free(p); }
void operator delete(void* p, const std::nothrow_t&) noexcept { std::free(p); }
void operator delete[](void* p, const std::nothrow_t&) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }
void operator delete[](void* p, std::size_t) noexcept { std::free(p); }
