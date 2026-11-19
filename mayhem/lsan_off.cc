// Leak detection is not the bug class this integration fuzzes for (ASan memory errors + UBSan are);
// fastp keeps per-run buffers alive until exit. Linked into every fuzz binary (SPEC §6.2 item 15).
extern "C" int __lsan_is_turned_off() { return 1; }
