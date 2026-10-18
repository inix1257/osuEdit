#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <windows.h>
#define DR_MP3_IMPLEMENTATION
#define DR_MP3_FLOAT_OUTPUT
#include "dr_mp3.h"

/* Report where each click (source: exactly 1000/2000/3000 ms) lands in decoded mono data. */
static void report(const char *tag, const float *x, long n, int sr) {
  printf("%-28s", tag);
  for (int c = 1; c <= 3; c++) {
    long lo = (long)(sr * (c - 0.3)), hi = (long)(sr * (c + 0.3));
    if (hi > n) hi = n;
    float peak = 0; long pi = -1;
    for (long i = lo; i < hi; i++) if (fabsf(x[i]) > peak) { peak = fabsf(x[i]); pi = i; }
    long on = -1;
    for (long i = lo; i < hi; i++) if (fabsf(x[i]) > peak * 0.3f) { on = i; break; }
    printf("  click%d onset %+7.3fms peak %+7.3fms", c, (on - (double)sr * c) * 1000.0 / sr, (pi - (double)sr * c) * 1000.0 / sr);
  }
  printf("   (len %.3fms)\n", n * 1000.0 / sr);
}

/* Same steps as SoLoud Wav::loadmp3. */
static int soloud_mp3(const char *path) {
  FILE *f = fopen(path, "rb"); if (!f) return 1;
  fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
  unsigned char *mem = malloc(len); fread(mem, 1, len, f); fclose(f);
  drmp3 d;
  if (!drmp3_init_memory(&d, mem, len, NULL)) return 2;
  drmp3_uint64 frames = drmp3_get_pcm_frame_count(&d);
  float *all = malloc(sizeof(float) * frames * d.channels);
  drmp3_seek_to_pcm_frame(&d, 0);
  drmp3_uint64 got = 0;
  for (drmp3_uint64 i = 0; i < frames; i += 512) {
    drmp3_uint64 b = frames - i > 512 ? 512 : frames - i;
    got += drmp3_read_pcm_frames_f32(&d, b, all + i * d.channels);
  }
  float *mono = malloc(sizeof(float) * frames);
  for (drmp3_uint64 i = 0; i < frames; i++) mono[i] = all[i * d.channels];
  char tag[64]; snprintf(tag, sizeof tag, "soloud dr_mp3 (delay %u)", d.delayInPCMFrames);
  report(tag, mono, (long)frames, d.sampleRate);
  return 0;
}

typedef int (WINAPI *Init_t)(int, DWORD, DWORD, void *, void *);
typedef int (WINAPI *SetConfig_t)(DWORD, DWORD);
typedef DWORD (WINAPI *Create_t)(int, const void *, unsigned long long, unsigned long long, DWORD);
typedef DWORD (WINAPI *GetData_t)(DWORD, void *, DWORD);
typedef int (WINAPI *GetInfo_t)(DWORD, void *);
typedef DWORD (WINAPI *GetVersion_t)(void);
typedef int (WINAPI *ErrorGetCode_t)(void);
typedef struct { DWORD freq, chans, flags, ctype, origres, plugin, sample; const char *filename; } ChanInfo;

static int bass(const char *dll, int oldgaps, const char *path) {
  HMODULE h = LoadLibraryA(dll); if (!h) { printf("load %s failed\n", dll); return 1; }
  GetVersion_t ver = (GetVersion_t)GetProcAddress(h, "BASS_GetVersion");
  SetConfig_t setc = (SetConfig_t)GetProcAddress(h, "BASS_SetConfig");
  Init_t init = (Init_t)GetProcAddress(h, "BASS_Init");
  Create_t create = (Create_t)GetProcAddress(h, "BASS_StreamCreateFile");
  GetData_t getdata = (GetData_t)GetProcAddress(h, "BASS_ChannelGetData");
  GetInfo_t info = (GetInfo_t)GetProcAddress(h, "BASS_ChannelGetInfo");
  ErrorGetCode_t err = (ErrorGetCode_t)GetProcAddress(h, "BASS_ErrorGetCode");
  int okc = -1;
  if (oldgaps >= 0) okc = setc(68, oldgaps);
  init(0, 44100, 0, NULL, NULL);
  DWORD s = create(0, path, 0, 0, 0x200000 | 256); /* DECODE | FLOAT */
  if (!s) { printf("create failed %d\n", err()); return 2; }
  ChanInfo ci; info(s, &ci);
  long cap = ci.freq * 10, n = 0;
  float *all = malloc(sizeof(float) * cap * ci.chans);
  for (;;) {
    DWORD r = getdata(s, all + n * ci.chans, 4096 * sizeof(float) * ci.chans);
    if (r == (DWORD)-1 || r == 0) break;
    n += r / sizeof(float) / ci.chans;
    if (n + 4096 > cap) break;
  }
  float *mono = malloc(sizeof(float) * n);
  for (long i = 0; i < n; i++) mono[i] = all[i * ci.chans];
  char tag[64]; snprintf(tag, sizeof tag, "bass %x oldgaps=%d(set %d)", ver(), oldgaps, okc);
  report(tag, mono, n, ci.freq);
  return 0;
}

int main(int argc, char **argv) {
  if (!strcmp(argv[1], "drmp3")) return soloud_mp3(argv[2]);
  return bass(argv[2], atoi(argv[3]), argv[4]);
}
