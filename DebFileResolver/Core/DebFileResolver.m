//
//  DebFileResolver.m
//  DebFileResolver
//
//  Created by hy on 2023/11/7.
//

#import "DebFileResolver.h"
#import <zlib.h>
#import <bzlib.h>
#import "dpkg/deb-version.h"
#import "dpkg/compress.h"
#import "dpkg/ar.h"
#import "dpkg/ehandle.h"
#import "dpkg/buffer.h"
#import "dpkg/fdio.h"
#import "lzma/lzma.h"
#import "NSFileManager+Tar.h"

#define ARCHIVEVERSION        "2.0"
#define BUILDCONTROLDIR        "DEBIAN"
#define EXTRACTCONTROLDIR    BUILDCONTROLDIR
#define OLDARCHIVEVERSION    "0.939000"
#define OLDDEBDIR        "DEBIAN"
#define OLDOLDDEBDIR        ".DEBIAN"
#define DEBMAGIC        "debian-binary"
#define ADMINMEMBER        "control.tar"
#define DATAMEMBER        "data.tar"
#define DPKG_AR_MAGIC "!<arch>\n"
#define DPKG_AR_FMAG  "`\n"

struct compress_params default_compress_params = {
    .type = COMPRESSOR_TYPE_GZIP,
    .strategy = COMPRESSOR_STRATEGY_NONE,
    .level = -1,
};

static void my_ohshit(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    printf(fmt, args);
    va_end(args);
    printf("\n");
}

static void my_ohshite(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    printf(fmt, args);
    va_end(args);
    printf("\n");
}

static inline void *
must_alloc(void *ptr)
{
    if (ptr)
        return ptr;
    my_ohshite("failed to allocate memory");
    return NULL;
}

void *m_malloc(size_t amount) {
    return must_alloc(malloc(amount));
}

void
m_output(FILE *f, const char *name)
{
    fflush(f);
    if (ferror(f) && errno != EPIPE)
        my_ohshite("error writing to '%s'", name);
}

int
m_vasprintf(char **strp, const char *fmt, va_list args)
{
    int n;
    
    n = vasprintf(strp, fmt, args);
    if (n >= 0)
        return n;
    my_ohshite("failed to allocate memory");
    return -1;
}

static ssize_t
read_line(int fd, char *buf, size_t min_size, size_t max_size)
{
    ssize_t line_size = 0;
    size_t n = min_size;
    
    while (line_size < (ssize_t)max_size) {
        ssize_t r;
        char *nl;
        
        r = fd_read(fd, buf + line_size, n);
        if (r <= 0)
            return r;
        
        nl = memchr(buf + line_size, '\n', r);
        line_size += r;
        
        if (nl != NULL) {
            nl[1] = '\0';
            return line_size;
        }
        
        n = 1;
    }
    
    buf[line_size] = '\0';
    return line_size;
}

static void read_fail(ssize_t rc, const char *filename, const char *what)
{
    if (rc >= 0)
        my_ohshit("unexpected end of file in %s in %.255s",what,filename);
    else
        my_ohshite("error reading %s from file %.255s", what, filename);
}


struct compressor {
    const char *name;
    const char *extension;
    int default_level;
    void (*fixup_params)(struct compress_params *params);
    void (*compress)(struct compress_params *params,
                     int fd_in, int fd_out, const char *desc);
    void (*decompress)(struct compress_params *params,
                       int fd_in, int fd_out, const char *desc, unsigned long datalength);
};

static void
fixup_none_params(struct compress_params *params)
{
}
static void
compress_none(struct compress_params *params, int fd_in, int fd_out,
              const char *desc)
{
    struct dpkg_error err;

    if (fd_fd_copy(fd_in, fd_out, -1, &err) < 0)
        my_ohshit("%s: pass-through copy error: %s", desc, err.str);
}
static void
decompress_none(struct compress_params *params, int fd_in, int fd_out,
                const char *desc, unsigned long datalength)
{
    struct dpkg_error err;

    if (fd_fd_copy(fd_in, fd_out, -1, &err) < 0)
        my_ohshit("%s: pass-through copy error: %s", desc, err.str);
}
static const struct compressor compressor_none = {
    .name = "none",
    .extension = "",
    .default_level = 0,
    .fixup_params = fixup_none_params,
    .compress = compress_none,
    .decompress = decompress_none,
};


static void
fixup_gzip_params(struct compress_params *params)
{
    /* Normalize compression level. */
    if (params->level == 0)
        params->type = COMPRESSOR_TYPE_NONE;
}

static void
compress_gzip(struct compress_params *params, int fd_in, int fd_out,
              const char *desc)
{
    char *buffer;
    char combuf[6];
    size_t bufsize = DPKG_BUFFER_SIZE;
    int strategy;
    int z_errnum;
    gzFile gzfile;

    if (params->strategy == COMPRESSOR_STRATEGY_FILTERED)
        strategy = 'f';
    else if (params->strategy == COMPRESSOR_STRATEGY_HUFFMAN)
        strategy = 'h';
    else if (params->strategy == COMPRESSOR_STRATEGY_RLE)
        strategy = 'R';
    else if (params->strategy == COMPRESSOR_STRATEGY_FIXED)
        strategy = 'F';
    else
        strategy = ' ';

    snprintf(combuf, sizeof(combuf), "w%d%c", params->level, strategy);
    gzfile = gzdopen(fd_out, combuf);
    if (gzfile == NULL)
        my_ohshit("%s: error binding output to gzip stream", desc);

    buffer = m_malloc(bufsize);

    for (;;) {
        int actualread, actualwrite;

        actualread = (int)fd_read(fd_in, buffer, bufsize);
        if (actualread < 0)
            my_ohshite("%s: internal gzip read error", desc);
        if (actualread == 0) /* EOF. */
            break;

        actualwrite = gzwrite(gzfile, buffer, actualread);
        if (actualwrite != actualread) {
            const char *errmsg = gzerror(gzfile, &z_errnum);

            if (z_errnum == Z_ERRNO)
                errmsg = strerror(errno);
            my_ohshit("%s: internal gzip write error: '%s'", desc,
                   errmsg);
        }
    }

    free(buffer);

    z_errnum = gzclose(gzfile);
    if (z_errnum) {
        const char *errmsg;

        if (z_errnum == Z_ERRNO)
            errmsg = strerror(errno);
        else
            errmsg = zError(z_errnum);
        my_ohshit("%s: internal gzip write error: %s", desc, errmsg);
    }
}

static void
decompress_gzip(struct compress_params *params, int fd_in, int fd_out,
                const char *desc, unsigned long datalength)
{
    char *buffer;
    unsigned int bufsize = DPKG_BUFFER_SIZE;
    int z_errnum;
    gzFile gzfile = gzdopen(fd_in, "r");

    if (gzfile == NULL)
        my_ohshit("%s: error binding input to gzip stream", desc);

    buffer = m_malloc(bufsize);

    for (;;) {
        int actualread, actualwrite;

        actualread = gzread(gzfile, buffer, bufsize);
        if (actualread < 0) {
            const char *errmsg = gzerror(gzfile, &z_errnum);

            if (z_errnum == Z_ERRNO)
                errmsg = strerror(errno);
            my_ohshit("%s: internal gzip read error: '%s'", desc,
                   errmsg);
        }
        if (actualread == 0) /* EOF. */
            break;
        actualwrite = (int)fd_write(fd_out, buffer, actualread);
        if (actualwrite != actualread)
            my_ohshite("%s: internal gzip write error", desc);
    }

    free(buffer);

    z_errnum = gzclose(gzfile);
    if (z_errnum) {
        const char *errmsg;

        if (z_errnum == Z_ERRNO)
            errmsg = strerror(errno);
        else
            errmsg = zError(z_errnum);
        my_ohshit("%s: internal gzip read error: %s", desc, errmsg);
    }

    if (close(fd_out))
        my_ohshite("%s: internal gzip write error", desc);
}
static const struct compressor compressor_gzip = {
    .name = "gzip",
    .extension = ".gz",
    .default_level = 9,
    .fixup_params = fixup_gzip_params,
    .compress = compress_gzip,
    .decompress = decompress_gzip,
};

enum dpkg_stream_filter {
    DPKG_STREAM_COMPRESS    = 1,
    DPKG_STREAM_DECOMPRESS    = 2,
};

enum dpkg_stream_action {
    DPKG_STREAM_INIT    = 0,
    DPKG_STREAM_RUN        = 1,
    DPKG_STREAM_FINISH    = 2,
};

enum dpkg_stream_status {
    DPKG_STREAM_OK,
    DPKG_STREAM_END,
    DPKG_STREAM_ERROR,
};


struct io_lzma {
    const char *desc;

    struct compress_params *params;

    enum dpkg_stream_filter filter;
    enum dpkg_stream_action action;
    enum dpkg_stream_status status;

    void (*init)(struct io_lzma *io, lzma_stream *s);
    void (*code)(struct io_lzma *io, lzma_stream *s);
    void (*done)(struct io_lzma *io, lzma_stream *s);
};

static void
filter_lzma(struct io_lzma *io, int fd_in, int fd_out)
{
    uint8_t *buf_in;
    uint8_t *buf_out;
    size_t buf_size = DPKG_BUFFER_SIZE;
    lzma_stream s = LZMA_STREAM_INIT;

    buf_in = m_malloc(buf_size);
    buf_out = m_malloc(buf_size);

    s.next_out = buf_out;
    s.avail_out = buf_size;

    io->status = DPKG_STREAM_OK;
    io->action = DPKG_STREAM_INIT;
    io->init(io, &s);
    io->action = DPKG_STREAM_RUN;

    do {
        ssize_t len;

        if (s.avail_in == 0 && io->action != DPKG_STREAM_FINISH) {
            len = fd_read(fd_in, buf_in, buf_size);
            if (len < 0)
                my_ohshite("%s: lzma read error", io->desc);
            if (len == 0)
                io->action = DPKG_STREAM_FINISH;
            s.next_in = buf_in;
            s.avail_in = len;
        }

        io->code(io, &s);

        if (s.avail_out == 0 || io->status == DPKG_STREAM_END) {
            len = fd_write(fd_out, buf_out, s.next_out - buf_out);
            if (len < 0)
                my_ohshite("%s: lzma write error", io->desc);
            s.next_out = buf_out;
            s.avail_out = buf_size;
        }
    } while (io->status != DPKG_STREAM_END);

    io->done(io, &s);

    free(buf_in);
    free(buf_out);

    if (close(fd_out))
        my_ohshite("%s: lzma close error", io->desc);
}

static const char *
dpkg_lzma_strerror(struct io_lzma *io, lzma_ret code)
{
    const char *const impossible = "internal error (bug)";

    switch (code) {
    case LZMA_MEM_ERROR:
        return strerror(ENOMEM);
    case LZMA_MEMLIMIT_ERROR:
        if (io->action == DPKG_STREAM_RUN)
            return "memory usage limit reached";
        return impossible;
    case LZMA_OPTIONS_ERROR:
        if (io->filter == DPKG_STREAM_COMPRESS &&
            io->action == DPKG_STREAM_INIT)
            return "unsupported compression preset";
        if (io->filter == DPKG_STREAM_DECOMPRESS &&
            io->action == DPKG_STREAM_RUN)
            return "unsupported options in file header";
        return impossible;
    case LZMA_DATA_ERROR:
        if (io->action == DPKG_STREAM_RUN)
            return "compressed data is corrupt";
        return impossible;
    case LZMA_BUF_ERROR:
        if (io->action == DPKG_STREAM_RUN)
            return "unexpected end of input";
        return impossible;
    case LZMA_FORMAT_ERROR:
        if (io->filter == DPKG_STREAM_DECOMPRESS &&
            io->action == DPKG_STREAM_RUN)
            return "file format not recognized";
        return impossible;
    case LZMA_UNSUPPORTED_CHECK:
        if (io->filter == DPKG_STREAM_COMPRESS &&
            io->action == DPKG_STREAM_INIT)
            return "unsupported type of integrity check";
        return impossible;
    default:
        return impossible;
    }
}

static void filter_lzma_error(struct io_lzma *io, lzma_ret ret)
{
    my_ohshit("%s: lzma error: %s", io->desc,
           dpkg_lzma_strerror(io, ret));
}

static void
filter_xz_init(struct io_lzma *io, lzma_stream *s)
{
    uint32_t preset;
    lzma_check check = LZMA_CHECK_CRC64;
#ifdef HAVE_LZMA_MT_ENCODER
    uint64_t mt_memlimit;
    lzma_mt mt_options = {
        .flags = 0,
        .block_size = 0,
        .timeout = 0,
        .filters = NULL,
        .check = check,
    };
#endif
    lzma_ret ret;

    io->filter = DPKG_STREAM_COMPRESS;

    preset = io->params->level;
    if (io->params->strategy == COMPRESSOR_STRATEGY_EXTREME)
        preset |= LZMA_PRESET_EXTREME;

#ifdef HAVE_LZMA_MT_ENCODER
    mt_options.preset = preset;
    mt_memlimit = filter_xz_get_memlimit();
    mt_options.threads = filter_xz_get_cputhreads(io->params);

    /* Guess whether we have enough RAM to use the multi-threaded encoder,
     * and decrease them up to single-threaded to reduce memory usage. */
    for (; mt_options.threads > 1; mt_options.threads--) {
        uint64_t mt_memusage;

        mt_memusage = lzma_stream_encoder_mt_memusage(&mt_options);
        if (mt_memusage < mt_memlimit)
            break;
    }

    ret = lzma_stream_encoder_mt(s, &mt_options);
#else
    ret = lzma_easy_encoder(s, preset, check);
#endif

    if (ret != LZMA_OK)
        filter_lzma_error(io, ret);
}

static void
filter_lzma_code(struct io_lzma *io, lzma_stream *s)
{
    lzma_ret ret;
    lzma_action action;

    if (io->action == DPKG_STREAM_RUN)
        action = LZMA_RUN;
    else if (io->action == DPKG_STREAM_FINISH)
        action = LZMA_FINISH;
    else
        internerr("unknown stream filter action %d\n", io->action);

    ret = lzma_code(s, action);

    if (ret == LZMA_STREAM_END)
        io->status = DPKG_STREAM_END;
    else if (ret != LZMA_OK)
        filter_lzma_error(io, ret);
}

static void
filter_lzma_done(struct io_lzma *io, lzma_stream *s)
{
    lzma_end(s);
}

static void
compress_xz(struct compress_params *params, int fd_in, int fd_out,
            const char *desc)
{
    struct io_lzma io;

    io.init = filter_xz_init;
    io.code = filter_lzma_code;
    io.done = filter_lzma_done;
    io.desc = desc;
    io.params = params;

    filter_lzma(&io, fd_in, fd_out);
}

static void
filter_unxz_init(struct io_lzma *io, lzma_stream *s)
{
#ifdef HAVE_LZMA_MT_DECODER
    lzma_mt mt_options = {
        .flags = 0,
        .block_size = 0,
        .timeout = 0,
        .filters = NULL,
    };
#else
    uint64_t memlimit = UINT64_MAX;
#endif
    lzma_ret ret;

    io->filter = DPKG_STREAM_DECOMPRESS;

#ifdef HAVE_LZMA_MT_DECODER
    mt_options.memlimit_stop = UINT64_MAX;
    mt_options.memlimit_threading = filter_xz_get_memlimit();
    mt_options.threads = filter_xz_get_cputhreads(io->params);

    ret = lzma_stream_decoder_mt(s, &mt_options);
#else
    ret = lzma_stream_decoder(s, memlimit, 0);
#endif
    if (ret != LZMA_OK)
        filter_lzma_error(io, ret);
}

static void
decompress_xz(struct compress_params *params, int fd_in, int fd_out,
              const char *desc, unsigned long datalength)
{
    struct io_lzma io;

    io.init = filter_unxz_init;
    io.code = filter_lzma_code;
    io.done = filter_lzma_done;
    io.desc = desc;
    io.params = params;

    filter_lzma(&io, fd_in, fd_out);
}

static const struct compressor compressor_xz = {
    .name = "xz",
    .extension = ".xz",
    .default_level = 6,
    .fixup_params = fixup_none_params,
    .compress = compress_xz,
    .decompress = decompress_xz,
};


static void
fixup_bzip2_params(struct compress_params *params)
{
    /* Normalize compression level. */
    if (params->level == 0)
        params->level = 1;
}

static void
compress_bzip2(struct compress_params *params, int fd_in, int fd_out,
               const char *desc)
{
    char *buffer;
    char combuf[6];
    size_t bufsize = DPKG_BUFFER_SIZE;
    int bz_errnum;
    BZFILE *bzfile;

    snprintf(combuf, sizeof(combuf), "w%d", params->level);
    bzfile = BZ2_bzdopen(fd_out, combuf);
    if (bzfile == NULL)
        my_ohshit("%s: error binding output to bzip2 stream", desc);

    buffer = m_malloc(bufsize);

    for (;;) {
        int actualread, actualwrite;

        actualread = (int)fd_read(fd_in, buffer, bufsize);
        if (actualread < 0)
            my_ohshite("%s: internal bzip2 read error", desc);
        if (actualread == 0) /* EOF. */
            break;

        actualwrite = BZ2_bzwrite(bzfile, buffer, actualread);
        if (actualwrite != actualread) {
            const char *errmsg = BZ2_bzerror(bzfile, &bz_errnum);

            if (bz_errnum == BZ_IO_ERROR)
                errmsg = strerror(errno);
            my_ohshit("%s: internal bzip2 write error: '%s'", desc,
                   errmsg);
        }
    }

    free(buffer);

    BZ2_bzWriteClose(&bz_errnum, bzfile, 0, NULL, NULL);
    if (bz_errnum != BZ_OK) {
        const char *errmsg = "unexpected bzip2 error";

        if (bz_errnum == BZ_IO_ERROR)
            errmsg = strerror(errno);
        my_ohshit("%s: internal bzip2 write error: '%s'", desc,
               errmsg);
    }

    /* Because BZ2_bzWriteClose has done a fflush on the file handle,
     * doing a close on the file descriptor associated with it should
     * be safe™. */
    if (close(fd_out))
        my_ohshite("%s: internal bzip2 write error", desc);
}

static void
decompress_bzip2(struct compress_params *params, int fd_in, int fd_out,
                 const char *desc, unsigned long datalength)
{
    char *buffer;
    int bufsize = DPKG_BUFFER_SIZE;
    BZFILE *bzfile = BZ2_bzdopen(fd_in, "r");

    if (bzfile == NULL)
        my_ohshit("%s: error binding input to bzip2 stream", desc);

    buffer = m_malloc(bufsize);

    for (;;) {
        ssize_t actualread, actualwrite;

        actualread = BZ2_bzread(bzfile, buffer, bufsize > datalength ? (int)datalength : bufsize);
        if (actualread < 0) {
            int bz_errnum = 0;
            const char *errmsg = BZ2_bzerror(bzfile, &bz_errnum);

            if (bz_errnum == BZ_IO_ERROR)
                errmsg = strerror(errno);
            my_ohshit("%s: internal bzip2 read error: '%s'", desc,
                   errmsg);
        }
        if (actualread == 0) /* EOF. */
            break;

        actualwrite = fd_write(fd_out, buffer, actualread);
        if (actualwrite != actualread)
            my_ohshite("%s: internal bzip2 write error", desc);
    }

    free(buffer);

    BZ2_bzclose(bzfile);

    if (close(fd_out))
        my_ohshite("%s: internal bzip2 write error", desc);
}

static const struct compressor compressor_bzip2 = {
    .name = "bzip2",
    .extension = ".bz2",
    .default_level = 9,
    .fixup_params = fixup_bzip2_params,
    .compress = compress_bzip2,
    .decompress = decompress_bzip2,
};

static void
filter_lzma_init(struct io_lzma *io, lzma_stream *s)
{
    uint32_t preset;
    lzma_options_lzma options;
    lzma_ret ret;

    io->filter = DPKG_STREAM_COMPRESS;

    preset = io->params->level;
    if (io->params->strategy == COMPRESSOR_STRATEGY_EXTREME)
        preset |= LZMA_PRESET_EXTREME;
    if (lzma_lzma_preset(&options, preset))
        filter_lzma_error(io, LZMA_OPTIONS_ERROR);

    ret = lzma_alone_encoder(s, &options);
    if (ret != LZMA_OK)
        filter_lzma_error(io, ret);
}

static void
compress_lzma(struct compress_params *params, int fd_in, int fd_out,
              const char *desc)
{
    struct io_lzma io;

    io.init = filter_lzma_init;
    io.code = filter_lzma_code;
    io.done = filter_lzma_done;
    io.desc = desc;
    io.params = params;

    filter_lzma(&io, fd_in, fd_out);
}

static void
filter_unlzma_init(struct io_lzma *io, lzma_stream *s)
{
    uint64_t memlimit = UINT64_MAX;
    lzma_ret ret;

    io->filter = DPKG_STREAM_DECOMPRESS;

    ret = lzma_alone_decoder(s, memlimit);
    if (ret != LZMA_OK)
        filter_lzma_error(io, ret);
}

static void
decompress_lzma(struct compress_params *params, int fd_in, int fd_out,
                const char *desc, unsigned long datalength)
{
    struct io_lzma io;

    io.init = filter_unlzma_init;
    io.code = filter_lzma_code;
    io.done = filter_lzma_done;
    io.desc = desc;
    io.params = params;

    filter_lzma(&io, fd_in, fd_out);
}

static const struct compressor compressor_lzma = {
    .name = "lzma",
    .extension = ".lzma",
    .default_level = 6,
    .fixup_params = fixup_none_params,
    .compress = compress_lzma,
    .decompress = decompress_lzma,
};

static const struct compressor *compressor_array[] = {
    [COMPRESSOR_TYPE_NONE] = &compressor_none,
    [COMPRESSOR_TYPE_GZIP] = &compressor_gzip,
    [COMPRESSOR_TYPE_XZ] = &compressor_xz,
    [COMPRESSOR_TYPE_BZIP2] = &compressor_bzip2,
    [COMPRESSOR_TYPE_LZMA] = &compressor_lzma,
};

static const struct compressor *
compressor(enum compressor_type type)
{
    const enum compressor_type max_type = array_count(compressor_array);

    if (type < 0 || type >= max_type)
        internerr("compressor_type %d is out of range", type);

    return compressor_array[type];
}



@implementation DebFileResolver


+ (void)decompressDeb:(NSString *)filePath
            isControl:(BOOL)isControl
           completion:(nullable decompressFinished)completion {
    const char *debar = filePath.UTF8String;
    int admininfo = isControl ? 1 : 0;
    struct dpkg_error err;
    const char *errstr;
    struct dpkg_ar *ar;
    char versionbuf[40];
    struct deb_version version;
    off_t ctrllennum = 0, memberlen = 0;
    ssize_t r;
    int dummy;
    char nlc;
    void (^handleError)(void) = ^ {
        if(completion) completion(NO, @"", @[]);
    };
    struct compress_params decompress_params = {
        .type = COMPRESSOR_TYPE_GZIP,
    };
    
    ar = dpkg_ar_open(debar);
    r = read_line(ar->fd, versionbuf, strlen(DPKG_AR_MAGIC), sizeof(versionbuf) - 1);
    if (r <= 0) {
        read_fail(r, debar, "archive magic version number");
        handleError();
        return;
    }
    
    if (strcmp(versionbuf, DPKG_AR_MAGIC) == 0) {
        int adminmember = -1;
        bool header_done = false;
        ctrllennum = 0;
        for (;;) {
            struct dpkg_ar_hdr arh;
            
            r = fd_read(ar->fd, &arh, sizeof(arh));
            if (r != sizeof(arh)) {
                read_fail(r, debar, "archive member header");
                handleError();
                return;
            }
                
            
            if (dpkg_ar_member_is_illegal(&arh)) {
                my_ohshit("file '%.250s' is corrupt - bad archive header magic", debar);
                handleError();
                return;
            }
            
            dpkg_ar_normalize_name(&arh);
            
            memberlen = dpkg_ar_member_get_size(ar, &arh);
            if (!header_done) {
                char *infobuf;
                
                if (strncmp(arh.ar_name, DEBMAGIC, sizeof(arh.ar_name)) != 0) {
                    my_ohshit("file '%.250s' is not a Debian binary archive (try dpkg-split?)",
                              debar);
                    handleError();
                    return;
                }
                infobuf= m_malloc(memberlen+1);
                r = fd_read(ar->fd, infobuf, memberlen + (memberlen & 1));
                if (r != (memberlen + (memberlen & 1))) {
                    read_fail(r, debar, "archive information header member");
                    handleError();
                    return;
                }
                    
                infobuf[memberlen] = '\0';
            
                if (strchr(infobuf, '\n') == NULL) {
                    my_ohshit("archive has no newlines in header");
                    handleError();
                    return;
                }
                    
                errstr = deb_version_parse(&version, infobuf);
                if (errstr) {
                    my_ohshit("archive has invalid format version: %s", errstr);
                    handleError();
                    return;
                }
                    
                if (version.major != 2) {
                    my_ohshit("archive is format version %d.%d; get a newer dpkg-deb",
                           version.major, version.minor);
                    handleError();
                    return;
                }
                    
                
                free(infobuf);
                
                header_done = true;
            } else if (arh.ar_name[0] == '_') {
                /* Members with ‘_’ are noncritical, and if we don't understand
                 * them we skip them. */
                if (fd_skip(ar->fd, memberlen + (memberlen & 1), &err) < 0) {
                    my_ohshit("cannot skip archive member from '%s': %s", ar->name, err.str);
                    handleError();
                    return;
                }
                    
            } else {
                if (strncmp(arh.ar_name, ADMINMEMBER, strlen(ADMINMEMBER)) == 0) {
                    const char *extension = arh.ar_name + strlen(ADMINMEMBER);
                    
                    adminmember = 1;
                    decompress_params.type = compressor_find_by_extension(extension);
                    if (decompress_params.type != COMPRESSOR_TYPE_NONE &&
                        decompress_params.type != COMPRESSOR_TYPE_GZIP &&
                        decompress_params.type != COMPRESSOR_TYPE_XZ) {
                        my_ohshit("archive '%s' uses unknown compression for member '%.*s', "
                               "giving up",
                               debar, (int)sizeof(arh.ar_name), arh.ar_name);
                        handleError();
                        return;
                    
                    }
                        
                    if (ctrllennum != 0) {
                        my_ohshit("archive '%.250s' contains two control members, giving up",
                               debar);
                        handleError();
                        return;
                    }
                        
                    ctrllennum = memberlen;
                } else {
                    if (adminmember != 1) {
                        my_ohshit("archive '%s' has premature member '%.*s' before '%s', "
                               "giving up",
                               debar, (int)sizeof(arh.ar_name), arh.ar_name, ADMINMEMBER);
                        handleError();
                        return;
                    }
                       
                    
                    if (strncmp(arh.ar_name, DATAMEMBER, strlen(DATAMEMBER)) == 0) {
                        
                        adminmember = 0;
                        // fix libdpkg bug
                        const char *extensionname = arh.ar_name + strlen(DATAMEMBER) + 1;
                        if (strncmp(extensionname, "lzma", strlen("lzma")) == 0) {
                            decompress_params.type = COMPRESSOR_TYPE_LZMA;
                        }else{
                            const char *extension = arh.ar_name + strlen(DATAMEMBER);
                            decompress_params.type = compressor_find_by_extension(extension);
                        }
                        if (decompress_params.type == COMPRESSOR_TYPE_UNKNOWN) {
                            my_ohshit("archive '%s' uses unknown compression for member '%.*s', "
                                   "giving up",
                                   debar, (int)sizeof(arh.ar_name), arh.ar_name);
                            handleError();
                            return;
                        }
                            
                    } else {
                        my_ohshit("archive '%s' has premature member '%.*s' before '%s', "
                               "giving up",
                               debar, (int)sizeof(arh.ar_name), arh.ar_name, DATAMEMBER);
                        handleError();
                        return;
                    }
                }
                if (!adminmember != !admininfo) {
                    if (fd_skip(ar->fd, memberlen + (memberlen & 1), &err) < 0) {
                        my_ohshit("cannot skip archive member from '%s': %s", ar->name, err.str);
                        handleError();
                        return;
                    }
                } else {
                    /* Yes! - found it. */
                    break;
                }
            }
        }
    
        do_decompress(filePath, ar, decompress_params, admininfo ? ADMINMEMBER : DATAMEMBER, admininfo ? ctrllennum : memberlen, completion);
        close(ar->fd);
        
        if (admininfo >= 2) {
            printf("new Debian package, version %d.%d.\n"
                   "size %jd bytes: control archive=%jd bytes.\n",
                   version.major, version.minor,
                   (intmax_t)ar->size, (intmax_t)ctrllennum);
            m_output(stdout, "<standard output>");
        }
    } else if (strncmp(versionbuf, "0.93", 4) == 0) {
        char ctrllenbuf[40];
        size_t l;
        l = strlen(versionbuf);
        if (strchr(versionbuf, '\n') == NULL) {
            my_ohshit("archive has no newlines in header");
            handleError();
            return;
        }
            
        errstr = deb_version_parse(&version, versionbuf);
        if (errstr) {
            my_ohshit("archive has invalid format version: %s", errstr);
            handleError();
            return;
        }
            
        r = read_line(ar->fd, ctrllenbuf, 1, sizeof(ctrllenbuf) - 1);
        if (r <= 0) {
            read_fail(r, debar, "archive control member size");
            handleError();
            return;
        }
            
        if (sscanf(ctrllenbuf, "%jd%c%d", (intmax_t *)&ctrllennum, &nlc, &dummy) != 2 ||
            nlc != '\n') {
            my_ohshit("archive has malformed control member size '%s'", ctrllenbuf);
            handleError();
            return;
        }
        if (admininfo) {
            memberlen = ctrllennum;
        } else {
            memberlen = ar->size - ctrllennum - strlen(ctrllenbuf) - l;
            if (fd_skip(ar->fd, ctrllennum, &err) < 0) {
                my_ohshit("cannot skip archive control member from '%s': %s", ar->name,
                          err.str);
                handleError();
                return;
            }
        }
        if (admininfo >= 2) {
            printf(" old Debian package, version %d.%d.\n"
                   " size %jd bytes: control archive=%jd, main archive=%jd.\n",
                   version.major, version.minor,
                   (intmax_t)ar->size, (intmax_t)ctrllennum,
                   (intmax_t)(ar->size - ctrllennum - strlen(ctrllenbuf) - l));
            m_output(stdout, "<standard output>");
        }
    } else {
        if (strncmp(versionbuf, "!<arch>", 7) == 0) {
            printf("file looks like it might be an archive which has been\n"
                   " corrupted by being downloaded in ASCII mode");
        }
        my_ohshit("'%.255s' is not a Debian format archive", debar);
        handleError();
        return;
    }
}


static void do_decompress(NSString *filePath, 
                          struct dpkg_ar *ar,
                          struct compress_params decompress_params,
                          char *itemname,
                          unsigned long datalength,
                          decompressFinished completionHandle) {
    void (^handleError)(void) = ^ {
        if(completionHandle) completionHandle(NO, @"", @[]);
    };
    // substring  /xxx/yyyyy.deb ~> /xxx/yyyyy
    NSString *debFileNamePath = [filePath substringToIndex:filePath.length - 4];
    NSError *error;
    NSFileManager *defaultManager = [NSFileManager defaultManager];
    // create dir /xxx/yyyyy
    [defaultManager createDirectoryAtPath:debFileNamePath withIntermediateDirectories:YES attributes:nil error:&error];
    if (error) {
        handleError();
        return;
    }
    NSString *tarPath = [debFileNamePath stringByAppendingFormat:@"/%s",itemname];
    // create tar file /xxx/yyyyy/data.tar or  /xxx/yyyyy/control.tar
    int p2_out = open(tarPath.UTF8String, O_CREAT | O_WRONLY, S_IREAD | S_IWRITE);
    // decompress deb to tar file
    compressor(decompress_params.type)->decompress(&decompress_params, ar->fd, p2_out, itemname, datalength);
    close(p2_out);
    [defaultManager createFilesAndDirectoriesAtPath:debFileNamePath withTarPath:tarPath error:&error progress:nil];
    if (error) {
        handleError();
        return;
    }
    NSArray *dirs = [defaultManager subpathsOfDirectoryAtPath:debFileNamePath error:&error];
    if (error) {
        handleError();
    }else{
        if (completionHandle) completionHandle(YES, debFileNamePath, dirs);
    }
    
}
@end
