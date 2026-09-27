/*
 * Vanilla Codec2 harness (system libcodec2, 3200 mode): encode OR decode.
 *
 *   codec2_ref enc input.wav  output.bin
 *   codec2_ref dec input.bin  output.wav
 *
 * Kept separate from the Codec2-mod harness on purpose: both codecs export
 * the same symbol names, so they must never be linked into one executable.
 * Cross-coding is done by exchanging .bin files.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include <codec2.h>
#include <sndfile.h>

#define SAMPLE_RATE 8000
#define FRAME_SAMPLES 160   /* 3200 mode: 20 ms at 8 kHz */
#define FRAME_BYTES 8       /* 3200 mode: 64 bits */

/* Create a 3200-mode codec and check it matches the frame sizes we expect. */
static struct CODEC2 *create_codec(void)
{
    struct CODEC2 *c2 = codec2_create(CODEC2_MODE_3200);
    if (!c2)
    {
        fprintf(stderr, "codec2_create failed\n");
        return NULL;
    }
    if (codec2_samples_per_frame(c2) != FRAME_SAMPLES ||
        codec2_bytes_per_frame(c2) != FRAME_BYTES)
    {
        fprintf(stderr, "Unexpected libcodec2 frame size: %d samples, %d bytes\n",
                codec2_samples_per_frame(c2), codec2_bytes_per_frame(c2));
        codec2_destroy(c2);
        return NULL;
    }
    return c2;
}

static int encode(const char *in_wav, const char *out_bin)
{
    SF_INFO info = {0};
    SNDFILE *in = sf_open(in_wav, SFM_READ, &info);
    if (!in)
    {
        fprintf(stderr, "Failed to open input WAV %s: %s\n", in_wav, sf_strerror(NULL));
        return 1;
    }
    if (info.channels != 1 || info.samplerate != SAMPLE_RATE ||
        (info.format & SF_FORMAT_SUBMASK) != SF_FORMAT_PCM_16)
    {
        fprintf(stderr, "Unsupported WAV format: must be mono, 8 kHz, 16-bit PCM\n");
        sf_close(in);
        return 1;
    }

    struct CODEC2 *c2 = create_codec();
    if (!c2)
    {
        sf_close(in);
        return 1;
    }

    FILE *out = fopen(out_bin, "wb");
    if (!out)
    {
        perror("fopen bitstream");
        codec2_destroy(c2);
        sf_close(in);
        return 1;
    }

    short speech[FRAME_SAMPLES];
    unsigned char bits[FRAME_BYTES];
    int rc = 0;

    /* Partial tail frame is dropped, like c2enc. */
    while (sf_read_short(in, speech, FRAME_SAMPLES) == FRAME_SAMPLES)
    {
        codec2_encode(c2, bits, speech);
        if (fwrite(bits, sizeof bits, 1, out) != 1)
        {
            perror("fwrite bitstream");
            rc = 1;
            break;
        }
    }

    if (fclose(out) != 0) { perror("fclose bitstream"); rc = 1; }
    codec2_destroy(c2);
    sf_close(in);
    return rc;
}

static int decode(const char *in_bin, const char *out_wav)
{
    FILE *in = fopen(in_bin, "rb");
    if (!in)
    {
        perror("fopen bitstream");
        return 1;
    }

    struct CODEC2 *c2 = create_codec();
    if (!c2)
    {
        fclose(in);
        return 1;
    }

    SF_INFO info = {
        .samplerate = SAMPLE_RATE,
        .channels = 1,
        .format = SF_FORMAT_WAV | SF_FORMAT_PCM_16,
    };
    SNDFILE *out = sf_open(out_wav, SFM_WRITE, &info);
    if (!out)
    {
        fprintf(stderr, "Failed to open output WAV %s: %s\n", out_wav, sf_strerror(NULL));
        codec2_destroy(c2);
        fclose(in);
        return 1;
    }

    short speech[FRAME_SAMPLES];
    unsigned char bits[FRAME_BYTES];
    int rc = 0;

    size_t n;
    while ((n = fread(bits, 1, sizeof bits, in)) == sizeof bits)
    {
        codec2_decode(c2, speech, bits);
        if (sf_write_short(out, speech, FRAME_SAMPLES) != FRAME_SAMPLES)
        {
            fprintf(stderr, "Write error: %s\n", sf_strerror(out));
            rc = 1;
            break;
        }
    }
    if (rc == 0 && n != 0)
    {
        fprintf(stderr, "Bitstream length is not a multiple of %d bytes\n", FRAME_BYTES);
        rc = 1;
    }
    if (ferror(in)) { perror("fread bitstream"); rc = 1; }

    fclose(in);
    sf_close(out);
    codec2_destroy(c2);
    return rc;
}

int main(int argc, char *argv[])
{
    if (argc == 4 && strcmp(argv[1], "enc") == 0)
        return encode(argv[2], argv[3]);
    if (argc == 4 && strcmp(argv[1], "dec") == 0)
        return decode(argv[2], argv[3]);

    fprintf(stderr, "Usage: %s enc input.wav output.bin\n"
                    "       %s dec input.bin output.wav\n", argv[0], argv[0]);
    return 1;
}
