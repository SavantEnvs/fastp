# alloc-dealloc-mismatch on every run (upstream fastp v1.4.0, ee125a5)

**Reproducer:** `any_input.fq` (any FASTQ at all) with an ASan build of upstream's plain `fastp`
(without `mayhem/new_delete_malloc.cc`): `fastp -i any_input.fq -o /dev/null -w 1 -j /dev/null -h /dev/null`.

**Cause:** arrays allocated with `new[]` are freed with scalar `delete`:
- `src/seprocessor.cpp:319` `delete pack->data;` — allocated `new Read*[PACK_SIZE]` at `:336`/`:381`
  (once per read pack, every single-end run). `src/peprocessor.cpp` already uses `delete[]`.
- `src/stats.cpp:92`/`:95` `delete iter->second;` on the quality/content curves allocated
  `new double[mCycles]` in `Stats::summarize` (`:147`) — at the end of every SE and PE run.

**Impact:** undefined behaviour (CWE-762); harmless with glibc for these POD arrays, but ASan aborts on
it, which made every fastp input an ASan crash. The fuzz binaries link `mayhem/new_delete_malloc.cc`
(global new/delete → malloc/free, which ASan still fully checks) so fuzzing can proceed.

**Fix:** `delete[]` at those three sites.
