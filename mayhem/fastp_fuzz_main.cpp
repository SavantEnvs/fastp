// mayhem/fastp_fuzz_main.cpp — file-input wrapper around fastp's own CLI `main`.
//
// fastp is a command-line tool only (no library API), and it exit()s on malformed input and runs
// reader/worker/writer threads with process-global state, so every target runs one fastp process per
// input. Three input shapes cannot be expressed as a single `@@` argument; this wrapper stages them and
// then calls upstream's unmodified main (src/main.cpp compiled with -Dmain=fastp_main):
//
//   FASTP_FUZZ_MODE_GZ       the input is a gzip/BGZF FASTQ. fastp picks its decompressor from the file
//                            NAME (ends_with(".gz"), fastqreader.cpp), so the bytes are staged in a
//                            $TMPDIR file named *.fq.gz.
//   FASTP_FUZZ_MODE_PE       the input is "R1 FASTQ \0 R2 FASTQ" (split at the first NUL byte; no NUL
//                            means an empty R2) and fastp runs paired-end on the two files (-i/-I).
//   FASTP_FUZZ_MODE_ADAPTER  the input is "adapter FASTA \0 reads FASTQ" (split at the first NUL; no
//                            NUL means the reads below) for --adapter_fasta trimming.
//
// The FASTQ/FASTA parts are handed to fastp as memfds (/proc/self/fd/N — re-opening one starts at
// offset 0, which fastp's evaluator relies on when it opens an input a second time), so nothing but the
// .gz file touches the filesystem; that file is removed at exit. All output goes to /dev/null, spelled
// differently per output (/dev/null, //dev/null, ...) because fastp refuses two outputs with the same
// name. No timers: Mayhem owns timeouts, and a
// hang (several of fastp's fixed bugs are reader/writer hangs) is a finding.
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <string>
#include <vector>

#if defined(__has_feature)
#if __has_feature(address_sanitizer)
#include <sanitizer/common_interface_defs.h>
#define FASTP_FUZZ_HAVE_ASAN 1
#endif
#endif

int fastp_main(int argc, char* argv[]);

static std::string g_tmpfile;

static void cleanup() {
    if (!g_tmpfile.empty()) unlink(g_tmpfile.c_str());
}

static std::string read_input(const char* path) {
    std::string data;
    FILE* f = fopen(path, "rb");
    if (!f) {
        perror(path);
        exit(2);
    }
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) data.append(buf, n);
    fclose(f);
    return data;
}

static void write_all(int fd, const std::string& s) {
    size_t off = 0;
    while (off < s.size()) {
        ssize_t w = write(fd, s.data() + off, s.size() - off);
        if (w <= 0) {
            perror("write");
            exit(2);
        }
        off += (size_t)w;
    }
}

// An in-memory file reachable by path; it stays open for the life of the process.
static std::string memfile(const char* name, const std::string& data) {
    int fd = memfd_create(name, 0);
    if (fd < 0) {
        perror("memfd_create");
        exit(2);
    }
    write_all(fd, data);
    lseek(fd, 0, SEEK_SET);
    return "/proc/self/fd/" + std::to_string(fd);
}

static std::string tmpfile_with_suffix(const char* suffix, const std::string& data) {
    const char* dir = getenv("TMPDIR");
    if (!dir || !*dir) dir = "/tmp";
    std::string tmpl = std::string(dir) + "/fastp-fuzz-XXXXXX" + suffix;
    std::vector<char> path(tmpl.begin(), tmpl.end());
    path.push_back('\0');
    int fd = mkstemps(path.data(), (int)strlen(suffix));
    if (fd < 0) {
        perror("mkstemps");
        exit(2);
    }
    g_tmpfile = path.data();
    atexit(cleanup);
#ifdef FASTP_FUZZ_HAVE_ASAN
    __sanitizer_set_death_callback(cleanup);
#endif
    write_all(fd, data);
    close(fd);
    return g_tmpfile;
}

static void split_nul(const std::string& in, std::string& a, std::string& b, bool& had_nul) {
    size_t p = in.find('\0');
    had_nul = p != std::string::npos;
    if (!had_nul) {
        a = in;
        b.clear();
    } else {
        a = in.substr(0, p);
        b = in.substr(p + 1);
    }
}

// Reads for the adapter target when the input carries none: records 2-3 of upstream testdata/R1.fq.
static const char kDefaultReads[] =
    "@AS500713:64:HFKJJBGXY:1:11101:17113:1101 1:A:0:TATAGCCT+GTTTCTTA\n"
    "TACAAAATGCACATCGCTGAAAGGGGTAAAGGAGAGAAATCGCTTTATAAAACCTTGAAAAGGAATATTCAAATATAAGCTGGGAAGGTATAAAAAACTCTGTACATCACAAGTAAACAAATGGAACCTGCAAAATATTAAACAAAGGATT\n"
    "+\n"
    "AAAAAEEEEE6EEAAAEEEEE6EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEAEEEEAEEEEEEEEEEEEEEEEECFE####EEEE6EE<AAEEEAEEEEEEEEEEEEAEEEEEEEA<E/AAEEEAEEEEE/EEEEAAEEE\n"
    "@AS500713:64:HFKJJBGXY:1:11101:1675:1101 1:A:0:TATAGCCT+GACCCCCA\n"
    "TAGGAGGCTTGGAGTACCAATAATAAAGTGAGCCCACCTTCCTGGTACCCAGACATTTCAGGAGGTCGGGAAATTTTTAAACCCAGGCAGCTTCCTGGCAGTGACATTTGGAGCATCAAAGTGGTAAATAAAATTTCATTTACATTAATAT\n"
    "+\n"
    "6AAAAAEEEEE/E/EA/E/AEA6EE//AEE66/AAE//EEE/E//E/AA/EEE/A/AEE/EEA//EEEEEEEE6EEAAA/E###6E/6//6<EAAEEE/EEEA/EA/EEEEEE/<<EEEE//A/EE<AEEEEE/</AA</E<AAAE/E<E/\n";

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <input file>\n", argv[0]);
        return 2;
    }
    std::string in = read_input(argv[1]);
    std::vector<std::string> args = {"fastp"};

#if defined(FASTP_FUZZ_MODE_GZ)
    std::string fq = tmpfile_with_suffix(".fq.gz", in);
    args.insert(args.end(), {"-i", fq, "-o", "/dev/null", "--failed_out", "//dev/null", "-y", "-p",
                             "--dont_eval_duplication", "-w", "1", "-j", "/dev/null", "-h", "/dev/null"});
#elif defined(FASTP_FUZZ_MODE_PE)
    std::string r1, r2;
    bool had_nul;
    split_nul(in, r1, r2, had_nul);
    args.insert(args.end(), {"-i", memfile("R1.fq", r1), "-I", memfile("R2.fq", r2),
                             "-o", "/dev/null", "-O", "//dev/null", "-m", "--merged_out", "/dev//null",
                             "--overlapped_out", "/dev/./null",
                             "--unpaired1", "///dev/null", "--unpaired2", "/dev///null",
                             "--detect_adapter_for_pe", "-c", "-p", "-y", "-g", "-x",
                             "--dont_eval_duplication", "-w", "1", "-j", "/dev/null", "-h", "/dev/null"});
#elif defined(FASTP_FUZZ_MODE_ADAPTER)
    std::string fa, fq;
    bool had_nul;
    split_nul(in, fa, fq, had_nul);
    if (!had_nul) fq = kDefaultReads;
    args.insert(args.end(), {"-i", memfile("reads.fq", fq), "--adapter_fasta", memfile("adapters.fa", fa),
                             "-o", "/dev/null", "--dont_eval_duplication", "-w", "1",
                             "-j", "/dev/null", "-h", "/dev/null"});
#else
#error "define one of FASTP_FUZZ_MODE_GZ, FASTP_FUZZ_MODE_PE, FASTP_FUZZ_MODE_ADAPTER"
#endif

    std::vector<char*> cargv;
    for (auto& a : args) cargv.push_back(const_cast<char*>(a.c_str()));
    cargv.push_back(nullptr);
    return fastp_main((int)args.size(), cargv.data());
}
