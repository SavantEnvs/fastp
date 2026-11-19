# heap-buffer-overflow in Stats::summarize when no read is parsed (upstream fastp v1.4.0, ee125a5)

**Reproducer:** `empty.fq` (an empty file; any input yielding zero reads does it, SE or PE):
`fastp -i empty.fq -o /dev/null -w 1 -j /dev/null -h /dev/null` with ASan.

```
ERROR: AddressSanitizer: heap-buffer-overflow
    #0 Stats::summarize(bool) src/stats.cpp:114
    #1 Stats::merge(...)       src/stats.cpp:952
    #2 SingleEndProcessor::process() src/seprocessor.cpp:129   (PairEndProcessor::process() peprocessor.cpp:231 for PE)
```

**Cause:** `Stats::summarize` reads `mCycleTotalBase[mBufLen-1]` unconditionally (`stats.cpp:114`);
when no read was counted the per-cycle buffer is never grown, so the index lands outside it.

**Impact:** out-of-bounds heap read (CWE-125) on empty or fully-unparseable input. Kept out of
`testsuite/` because it crashes.

**Fix:** guard the `mBufLen-1` read (`if(mBufLen > 0 && ...)`) / return early when no reads were counted.
