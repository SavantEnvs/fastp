# negative array index in Stats::statRead on a quality byte >= 0x80 (upstream fastp v1.4.0, ee125a5)

Mayhem defect #3641188 (`fastp-se`, run 1).

**Reproducer:** `high_qual_byte.fq`, one FASTQ read whose quality string holds the byte `0xD4`:
`fastp -i high_qual_byte.fq -o /dev/null -w 1 -j /dev/null -h /dev/null` with UBSan.

```
src/stats.cpp:213:9: runtime error: index -44 out of bounds for type 'long[128]'
    #0 Stats::statRead(Read*)                                src/stats.cpp:213
    #1 SingleEndProcessor::processSingleEnd(ReadPack*, ...)  src/seprocessor.cpp:211
    #2 SingleEndProcessor::processorTask(ThreadConfig*)      src/seprocessor.cpp:444
```

**Cause:** `Stats::statRead` does `mBaseQualHistogram[qual]++` with `char qual = qualstr[i]`
(`stats.cpp:213`). `char` is signed on x86-64, so any quality byte >= 0x80 is a negative index into
`long mBaseQualHistogram[128]` (`stats.h:85`). FastqReader does not validate the quality alphabet.

**Impact:** out-of-bounds write before the start of a member array (CWE-129 / CWE-787): it
increments a `long` up to 1 KiB before `mBaseQualHistogram`, corrupting other `Stats` members.
Kept out of `testsuite/` because it crashes.

**Fix:** index with `(unsigned char)qual` and size the histogram 256, or reject quality bytes
outside `!`..`~` in the reader.
