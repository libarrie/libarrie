/*
 * Libarrie image decoder (DESIGN.md section 7).
 *
 * Runs only inside the OS-level sandbox (minijail plus launcher limits).
 * It never runs as a NIF: a crash on malicious input kills only this
 * process. Links libjpeg-turbo (IJG/BSD-style), libpng (libpng license)
 * and zlib (zlib license) statically against musl, built with clang and
 * compiler-rt. No GPL-family code.
 *
 *   decoder validate INPUT OUTPUT MAX_PIXELS
 *       Fully decodes the image and writes {"format","width","height"}.
 *   decoder resize INPUT OUTPUT MAX_PIXELS MAX_DIMENSION QUALITY
 *       Decodes, applies EXIF orientation, downsizes to fit MAX_DIMENSION
 *       with an area-average filter and writes a baseline JPEG with no
 *       metadata (location data is never copied into derived images).
 *
 * Exit codes: 0 ok, 2 unsupported or corrupt image, 3 limits exceeded,
 * 4 I/O or usage error. Any signal (for example a limit breach) is also
 * treated by the caller as an unsupported image.
 */
#include <errno.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jpeglib.h>
#include <jerror.h>
#include <png.h>

#define EXIT_OK 0
#define EXIT_UNSUPPORTED 2
#define EXIT_LIMITS 3
#define EXIT_IO 4

#define MAX_INPUT_BYTES (25L * 1024 * 1024)

typedef struct {
  unsigned char *pixels; /* RGB, 3 bytes per pixel */
  uint32_t width;
  uint32_t height;
  const char *format;
} image;

static void fail(int code, const char *message) {
  fprintf(stderr, "decoder: %s\n", message);
  exit(code);
}

static unsigned char *read_file(const char *path, size_t *size) {
  FILE *f = fopen(path, "rb");
  if (!f) fail(EXIT_IO, "cannot open input");
  if (fseek(f, 0, SEEK_END) != 0) fail(EXIT_IO, "cannot seek input");
  long n = ftell(f);
  if (n < 0) fail(EXIT_IO, "cannot size input");
  if (n > MAX_INPUT_BYTES) fail(EXIT_LIMITS, "input too large");
  rewind(f);
  unsigned char *buf = malloc((size_t)n + 1);
  if (!buf) fail(EXIT_LIMITS, "out of memory");
  if (fread(buf, 1, (size_t)n, f) != (size_t)n) fail(EXIT_IO, "short read");
  fclose(f);
  *size = (size_t)n;
  return buf;
}

static void check_pixels(uint32_t w, uint32_t h, uint64_t max_pixels) {
  if (w == 0 || h == 0) fail(EXIT_UNSUPPORTED, "empty image");
  if (w > 20000 || h > 20000) fail(EXIT_LIMITS, "dimension limit");
  if ((uint64_t)w * (uint64_t)h > max_pixels) fail(EXIT_LIMITS, "pixel limit");
}

/* ---- JPEG ---------------------------------------------------------------- */

struct jpeg_failure {
  struct jpeg_error_mgr base;
  jmp_buf jump;
};

static void jpeg_error_exit(j_common_ptr info) {
  struct jpeg_failure *failure = (struct jpeg_failure *)info->err;
  longjmp(failure->jump, 1);
}

/* Warnings are ignored except premature end of data: a truncated file is
 * corrupt, not a valid page with grey padding. */
static void jpeg_quiet(j_common_ptr info, int level) {
  if (level < 0 && info->err->msg_code == JWRN_JPEG_EOF) {
    struct jpeg_failure *failure = (struct jpeg_failure *)info->err;
    longjmp(failure->jump, 1);
  }
}

/* EXIF orientation (1..8) from the APP1 segment, or 1. Bounded parsing. */
static int exif_orientation(const unsigned char *data, size_t size) {
  size_t i = 2;
  while (i + 4 <= size && data[i] == 0xFF) {
    unsigned marker = data[i + 1];
    size_t length = ((size_t)data[i + 2] << 8) | data[i + 3];
    if (marker == 0xDA || length < 2 || i + 2 + length > size) break;
    if (marker == 0xE1 && length >= 16 && memcmp(data + i + 4, "Exif\0\0", 6) == 0) {
      const unsigned char *t = data + i + 10;
      size_t tlen = length - 8;
      int little = t[0] == 'I';
      #define U16(p) (little ? (unsigned)((p)[0] | ((p)[1] << 8)) : (unsigned)(((p)[0] << 8) | (p)[1]))
      #define U32(p) (little ? (uint32_t)((p)[0] | ((p)[1] << 8) | ((p)[2] << 16) | ((uint32_t)(p)[3] << 24)) \
                             : (uint32_t)(((uint32_t)(p)[0] << 24) | ((p)[1] << 16) | ((p)[2] << 8) | (p)[3]))
      if (tlen < 8) return 1;
      uint32_t ifd = U32(t + 4);
      if (ifd + 2 > tlen) return 1;
      unsigned count = U16(t + ifd);
      for (unsigned e = 0; e < count; e++) {
        size_t entry = ifd + 2 + (size_t)e * 12;
        if (entry + 12 > tlen) break;
        if (U16(t + entry) == 0x0112) {
          unsigned value = U16(t + entry + 8);
          return value >= 1 && value <= 8 ? (int)value : 1;
        }
      }
      #undef U16
      #undef U32
      return 1;
    }
    i += 2 + length;
  }
  return 1;
}

static image decode_jpeg(const unsigned char *data, size_t size, uint64_t max_pixels) {
  struct jpeg_decompress_struct info;
  struct jpeg_failure failure;
  image out = {0};
  info.err = jpeg_std_error(&failure.base);
  failure.base.error_exit = jpeg_error_exit;
  failure.base.emit_message = jpeg_quiet;
  if (setjmp(failure.jump)) {
    jpeg_destroy_decompress(&info);
    fail(EXIT_UNSUPPORTED, "corrupt jpeg");
  }
  jpeg_create_decompress(&info);
  jpeg_mem_src(&info, data, (unsigned long)size);
  jpeg_read_header(&info, TRUE);
  check_pixels(info.image_width, info.image_height, max_pixels);
  info.out_color_space = JCS_RGB;
  jpeg_start_decompress(&info);
  out.width = info.output_width;
  out.height = info.output_height;
  out.pixels = malloc((size_t)out.width * out.height * 3);
  if (!out.pixels) fail(EXIT_LIMITS, "out of memory");
  while (info.output_scanline < info.output_height) {
    JSAMPROW row = out.pixels + (size_t)info.output_scanline * out.width * 3;
    jpeg_read_scanlines(&info, &row, 1);
  }
  jpeg_finish_decompress(&info);
  jpeg_destroy_decompress(&info);
  out.format = "jpeg";
  return out;
}

/* ---- PNG ----------------------------------------------------------------- */

static image decode_png(const unsigned char *data, size_t size, uint64_t max_pixels) {
  png_image png;
  image out = {0};
  memset(&png, 0, sizeof png);
  png.version = PNG_IMAGE_VERSION;
  if (!png_image_begin_read_from_memory(&png, data, size))
    fail(EXIT_UNSUPPORTED, "corrupt png");
  check_pixels(png.width, png.height, max_pixels);
  png.format = PNG_FORMAT_RGB;
  out.width = png.width;
  out.height = png.height;
  out.pixels = malloc(PNG_IMAGE_SIZE(png));
  if (!out.pixels) fail(EXIT_LIMITS, "out of memory");
  if (!png_image_finish_read(&png, NULL, out.pixels, 0, NULL)) {
    png_image_free(&png);
    fail(EXIT_UNSUPPORTED, "corrupt png");
  }
  out.format = "png";
  return out;
}

/* ---- transforms ------------------------------------------------------------ */

static image orient(image in, int orientation) {
  if (orientation <= 1 || orientation > 8) return in;
  int swap = orientation >= 5;
  image out = in;
  out.width = swap ? in.height : in.width;
  out.height = swap ? in.width : in.height;
  out.pixels = malloc((size_t)out.width * out.height * 3);
  if (!out.pixels) fail(EXIT_LIMITS, "out of memory");
  for (uint32_t y = 0; y < in.height; y++) {
    for (uint32_t x = 0; x < in.width; x++) {
      uint32_t nx = x, ny = y;
      switch (orientation) {
        case 2: nx = in.width - 1 - x; break;
        case 3: nx = in.width - 1 - x; ny = in.height - 1 - y; break;
        case 4: ny = in.height - 1 - y; break;
        case 5: nx = y; ny = x; break;
        case 6: nx = in.height - 1 - y; ny = x; break;
        case 7: nx = in.height - 1 - y; ny = in.width - 1 - x; break;
        case 8: nx = y; ny = in.width - 1 - x; break;
      }
      memcpy(out.pixels + ((size_t)ny * out.width + nx) * 3,
             in.pixels + ((size_t)y * in.width + x) * 3, 3);
    }
  }
  free(in.pixels);
  return out;
}

/* Area-average downscale so the longer side is at most max_dim. */
static image shrink(image in, uint32_t max_dim) {
  uint32_t longest = in.width > in.height ? in.width : in.height;
  if (longest <= max_dim) return in;
  double scale = (double)max_dim / longest;
  image out = in;
  out.width = (uint32_t)(in.width * scale);
  out.height = (uint32_t)(in.height * scale);
  if (out.width < 1) out.width = 1;
  if (out.height < 1) out.height = 1;
  out.pixels = malloc((size_t)out.width * out.height * 3);
  if (!out.pixels) fail(EXIT_LIMITS, "out of memory");
  for (uint32_t oy = 0; oy < out.height; oy++) {
    uint32_t y0 = (uint32_t)((uint64_t)oy * in.height / out.height);
    uint32_t y1 = (uint32_t)((uint64_t)(oy + 1) * in.height / out.height);
    if (y1 <= y0) y1 = y0 + 1;
    for (uint32_t ox = 0; ox < out.width; ox++) {
      uint32_t x0 = (uint32_t)((uint64_t)ox * in.width / out.width);
      uint32_t x1 = (uint32_t)((uint64_t)(ox + 1) * in.width / out.width);
      if (x1 <= x0) x1 = x0 + 1;
      uint64_t sum[3] = {0, 0, 0};
      for (uint32_t y = y0; y < y1; y++)
        for (uint32_t x = x0; x < x1; x++)
          for (int c = 0; c < 3; c++)
            sum[c] += in.pixels[((size_t)y * in.width + x) * 3 + c];
      uint64_t n = (uint64_t)(y1 - y0) * (x1 - x0);
      for (int c = 0; c < 3; c++)
        out.pixels[((size_t)oy * out.width + ox) * 3 + c] = (unsigned char)(sum[c] / n);
    }
  }
  free(in.pixels);
  return out;
}

static void write_jpeg(const char *path, image img, int quality) {
  FILE *f = fopen(path, "wb");
  if (!f) fail(EXIT_IO, "cannot open output");
  struct jpeg_compress_struct info;
  struct jpeg_error_mgr err;
  info.err = jpeg_std_error(&err);
  jpeg_create_compress(&info);
  jpeg_stdio_dest(&info, f);
  info.image_width = img.width;
  info.image_height = img.height;
  info.input_components = 3;
  info.in_color_space = JCS_RGB;
  jpeg_set_defaults(&info);
  jpeg_set_quality(&info, quality, TRUE);
  jpeg_start_compress(&info, TRUE);
  while (info.next_scanline < info.image_height) {
    JSAMPROW row = img.pixels + (size_t)info.next_scanline * img.width * 3;
    jpeg_write_scanlines(&info, &row, 1);
  }
  jpeg_finish_compress(&info);
  jpeg_destroy_compress(&info);
  if (fclose(f) != 0) fail(EXIT_IO, "cannot write output");
}

static uint64_t parse_number(const char *text) {
  char *end = NULL;
  errno = 0;
  unsigned long long value = strtoull(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0') fail(EXIT_IO, "bad numeric argument");
  return (uint64_t)value;
}

int main(int argc, char **argv) {
  if (argc < 5) fail(EXIT_IO, "usage: decoder validate|resize INPUT OUTPUT MAX_PIXELS [MAX_DIM QUALITY]");
  const char *mode = argv[1];
  size_t size = 0;
  unsigned char *data = read_file(argv[2], &size);
  uint64_t max_pixels = parse_number(argv[4]);
  image img;
  if (size >= 8 && memcmp(data, "\x89PNG\r\n\x1a\n", 8) == 0)
    img = decode_png(data, size, max_pixels);
  else if (size >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF)
    img = decode_jpeg(data, size, max_pixels);
  else
    fail(EXIT_UNSUPPORTED, "unrecognized format");

  if (strcmp(mode, "validate") == 0) {
    FILE *f = fopen(argv[3], "wb");
    if (!f) fail(EXIT_IO, "cannot open output");
    fprintf(f, "{\"format\":\"%s\",\"width\":%u,\"height\":%u}", img.format, img.width, img.height);
    if (fclose(f) != 0) fail(EXIT_IO, "cannot write output");
    return EXIT_OK;
  }
  if (strcmp(mode, "resize") == 0 && argc >= 7) {
    uint32_t max_dim = (uint32_t)parse_number(argv[5]);
    int quality = (int)parse_number(argv[6]);
    if (max_dim < 16 || max_dim > 8192 || quality < 30 || quality > 95)
      fail(EXIT_IO, "bad resize arguments");
    if (strcmp(img.format, "jpeg") == 0) img = orient(img, exif_orientation(data, size));
    img = shrink(img, max_dim);
    write_jpeg(argv[3], img, quality);
    return EXIT_OK;
  }
  fail(EXIT_IO, "unknown mode");
  return EXIT_IO;
}
