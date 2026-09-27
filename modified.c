/*
 * Codec2-mod harness: encode OR decode, never both codecs in one binary.
 *
 *   codec2_mod enc input.wav  output.bin
 *   codec2_mod dec input.bin  output.wav
 *
 * Linking Codec2-mod and libcodec2 into one executable is unsafe: they export
 * the same symbol names, so libcodec2's internal calls could silently resolve
 * to Codec2-mod functions. Cross-coding is done by exchanging .bin files.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include <sndfile.h>
#include "codec2_mod.h"

#define SAMPLE_RATE 8000

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

    FILE *out = fopen(out_bin, "wb");
    if (!out)
    {
        perror("fopen bitstream");
        sf_close(in);
        return 1;
    }

    static codec2_encoder_t enc;
    codec2_encoder_init(&enc);

    int16_t speech[CODEC2_SAMPLES_PER_FRAME];
    uint8_t bits[CODEC2_BYTES_PER_FRAME];
    int rc = 0;

    /* Partial tail frame is dropped, like c2enc. */
    while (sf_read_short(in, speech, CODEC2_SAMPLES_PER_FRAME) == CODEC2_SAMPLES_PER_FRAME)
    {
        codec2_encode(&enc, bits, speech);
        if (fwrite(bits, sizeof bits, 1, out) != 1)
        {
            perror("fwrite bitstream");
            rc = 1;
            break;
        }
    }

    if (fclose(out) != 0) { perror("fclose bitstream"); rc = 1; }
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

    SF_INFO info = {
        .samplerate = SAMPLE_RATE,
        .channels = 1,
        .format = SF_FORMAT_WAV | SF_FORMAT_PCM_16,
    };
    SNDFILE *out = sf_open(out_wav, SFM_WRITE, &info);
    if (!out)
    {
        fprintf(stderr, "Failed to open output WAV %s: %s\n", out_wav, sf_strerror(NULL));
        fclose(in);
        return 1;
    }

    static codec2_decoder_t dec;
    codec2_decoder_init(&dec);

    int16_t speech[CODEC2_SAMPLES_PER_FRAME];
    uint8_t bits[CODEC2_BYTES_PER_FRAME];
    int rc = 0;

    size_t n;
    while ((n = fread(bits, 1, sizeof bits, in)) == sizeof bits)
    {
        codec2_decode(&dec, speech, bits);
        if (sf_write_short(out, speech, CODEC2_SAMPLES_PER_FRAME) != CODEC2_SAMPLES_PER_FRAME)
        {
            fprintf(stderr, "Write error: %s\n", sf_strerror(out));
            rc = 1;
            break;
        }
    }
    if (rc == 0 && n != 0)
    {
        fprintf(stderr, "Bitstream length is not a multiple of %d bytes\n", CODEC2_BYTES_PER_FRAME);
        rc = 1;
    }
    if (ferror(in)) { perror("fread bitstream"); rc = 1; }

    fclose(in);
    sf_close(out);
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
