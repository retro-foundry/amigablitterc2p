#include <stdio.h>
#include <string.h>
#include <stdarg.h>

#include <hardware/custom.h>
#include <hardware/dmabits.h>
#include <clib/exec_protos.h>
#include <clib/intuition_protos.h>
#include <clib/graphics_protos.h>
#include <clib/timer_protos.h>
#include <graphics/gfxbase.h>
#include <graphics/gfx.h>
#include <exec/memory.h>
#include <devices/timer.h>

#define CREGS ((volatile struct Custom *)0xDFF000)

#define TASK_PRIORITY 20
#define PRA_FIR0_BIT  (1 << 6)

/* Copper register offsets */
#define COPJMP1   0x088
#define DIWSTRT   0x08E
#define DIWSTOP   0x090
#define DDFSTRT   0x092
#define DDFSTOP   0x094
#define BPL1PTH   0x0E0
#define BPL1PTL   0x0E2
#define BPLCON0   0x100
#define BPLCON1   0x102
#define BPLCON2   0x104
#define BPL1MOD   0x108
#define BPL2MOD   0x10A
#define COLOR00   0x180
#define COLOR_REG(n) (COLOR00 + ((n) << 1))

#ifndef SCREEN_W
#define SCREEN_W             320
#endif
#ifndef SCREEN_H
#define SCREEN_H             256
#endif
#ifndef DEPTH
#define DEPTH                4
#endif
#ifndef HORIZON
#define HORIZON              96
#endif
#define VISIBLE_LINES        (SCREEN_H - HORIZON)
#define ROW_BYTES            (SCREEN_W / 8)          /* 40 */
#define BPL_SIZE             ((ULONG)ROW_BYTES * SCREEN_H)
#define SCREEN_BYTES         (BPL_SIZE * DEPTH)

#define CHUNKY_W             (SCREEN_W / 2)          /* 160, for 2x1 c2p */
#define CHUNKY_H             VISIBLE_LINES
#define CHUNKY_BYTES         ((ULONG)CHUNKY_W * CHUNKY_H)

#ifndef TEX_W
#define TEX_W                32
#endif
#ifndef TEX_H
#define TEX_H                32
#endif
#define TEX_BYTES            (TEX_W * TEX_H)

#ifndef NUM_ANGLES
#define NUM_ANGLES           64
#endif

/* 24.8-ish fixed point */
#ifndef FLOOR_SCALE
#define FLOOR_SCALE          (192L << 8)
#endif
#ifndef STEP_SHIFT
#define STEP_SHIFT           5
#endif

/* PAL low-res pixel aspect (height/width); ~1.25 so we scale v to avoid vertical stretch. */
#ifndef ASPECT_NUM
#define ASPECT_NUM           5
#endif
#ifndef ASPECT_DEN
#define ASPECT_DEN           4
#endif

#ifndef S2P_BENCH_ONLY
#define S2P_BENCH_ONLY       1
#endif

#if defined(AMIGA_CHIPSET_AGA)
#define CHIPSET_NAME "AGA"
#define C2P_BACKEND_NAME "AGA blitter-assisted 2x1 4bpl (extended BLTSIZV/H)"
#elif defined(AMIGA_CHIPSET_ECS)
#define CHIPSET_NAME "ECS"
#define C2P_BACKEND_NAME "ECS blitter-assisted 2x1 4bpl"
#else
#define CHIPSET_NAME "UNSPECIFIED"
#define C2P_BACKEND_NAME "blitter-assisted 2x1 4bpl"
#endif

struct GfxBase *GfxBase = NULL;
struct IntuitionBase *IntuitionBase = NULL;
struct Device *TimerBase = NULL;
static FILE *g_log = NULL;
static const char *g_stage_render_label = "R";
static const char *g_stage_convert_label = "C2P";

typedef struct CopperState
{
    UWORD *list;
    ULONG bytes;
    UWORD *bpl_hi[DEPTH];
    UWORD *bpl_lo[DEPTH];
} CopperState;

typedef struct LineModel
{
    LONG u0;
    LONG v0;
    LONG du2;
    LONG dv2;
} LineModel;

typedef struct FpsCounter
{
    struct EClockVal window_start;
    struct EClockVal run_start;
    ULONG hz;
    ULONG window_frames;
    ULONG total_frames;
    ULONG window_frame_ticks;
    ULONG total_frame_ticks;
    ULONG window_render_ticks;
    ULONG window_c2p_ticks;
    ULONG window_sync_ticks;
    ULONG total_render_ticks;
    ULONG total_c2p_ticks;
    ULONG total_sync_ticks;
} FpsCounter;

typedef struct TimerState
{
    struct MsgPort *port;
    struct IORequest *req;
} TimerState;

static const char *mem_type_name(APTR p)
{
    ULONG t = TypeOfMem(p);
    if (t & MEMF_FAST) return "FAST";
    if (t & MEMF_CHIP) return "CHIP";
    if (t & MEMF_PUBLIC) return "PUBLIC";
    return "UNKNOWN";
}

static void print_both(const char *fmt, ...)
{
    va_list ap1;
    va_list ap2;

    va_start(ap1, fmt);
    va_copy(ap2, ap1);

    vprintf(fmt, ap1);
    if (g_log)
    {
        vfprintf(g_log, fmt, ap2);
        fflush(g_log);
    }

    va_end(ap2);
    va_end(ap1);
}

static ULONG pct_of(ULONG part, ULONG whole)
{
    if (!whole)
    {
        return 0;
    }
    return (part * 100UL + (whole >> 1)) / whole;
}

static ULONG ticks_to_ms_window(ULONG ticks, ULONG hz)
{
    if (!hz)
    {
        return 0;
    }
    return (ticks * 1000UL + (hz >> 1)) / hz;
}

static ULONG ticks_to_ms_per_frame(ULONG ticks, ULONG hz, ULONG frames)
{
    ULONG denom;

    if (!hz || !frames)
    {
        return 0;
    }

    denom = hz * frames;
    if (!denom)
    {
        return 0;
    }
    return (ticks * 1000UL + (denom >> 1)) / denom;
}

/* C-callable wrapper for the local OCS blitter-assisted 2x1 4bpl c2p path. */
extern void c2p_blit_4bpl_init_c(void);
extern void c2p_blit_4bpl_c(void *chunky, void *screenBase);
extern void c2p_blit_4bpl_waitblit_c(void);
extern void *c2p_blit_4bpl_stageptr_c(void);
extern void render_chunky_span_copy2_asm(UBYTE *row0, UBYTE *row1, const UBYTE *tex, LONG u, LONG v, LONG du2, LONG dv2, LONG count);
extern void render_chunky_all_asm(UBYTE *chunky, const UBYTE *tex, LONG camu, LONG camv, const LineModel *lm_base, WORD num_pairs);

/* Allocated in FAST RAM at startup so the render hot-path never touches chip RAM. */
static LineModel (*g_line_model)[VISIBLE_LINES] = NULL;
static LONG g_camu = 0;
static LONG g_camv = 0;

/* 16-colour palette */
static const UWORD g_palette[16] =
{
    0x000, 0x112, 0x224, 0x336,
    0x448, 0x55A, 0x66C, 0x77E,
    0x88F, 0xAAF, 0xCCF, 0xFEE,
    0xFCA, 0xF84, 0xF40, 0xFFF
};

static const UBYTE g_stretch_lut[16] =
{
    0x00, 0x03, 0x0C, 0x0F,
    0x30, 0x33, 0x3C, 0x3F,
    0xC0, 0xC3, 0xCC, 0xCF,
    0xF0, 0xF3, 0xFC, 0xFF
};

/* Direction vectors (fx,fy) per angle: 256*cos(2*PI*i/NUM_ANGLES), 256*sin(...).
 * Filled at startup from sin_table_64 so we don't need floating point. */
static LONG g_dir[NUM_ANGLES][2];

/* sin(2*PI*i/64)*256 for i=0..63 (one full circle). cos(i) = sin((i+16)&63).
 * Entry 63 must be -25 (not 0) so angle 63 differs from angle 0 and there's
 * no stutter when the frame counter wraps. */
static const short sin_table_64[64] =
{
      0,  25,  50,  74,  98, 121, 142, 163, 181, 198, 212, 226, 237, 246, 253, 256,
    256, 253, 246, 237, 226, 212, 198, 181, 163, 142, 121,  98,  74,  50,  25,   0,
      0, -25, -50, -74, -98,-121,-142,-163,-181,-198,-212,-226,-237,-246,-253,-256,
   -256,-253,-246,-237,-226,-212,-198,-181,-163,-142,-121, -98, -74, -50, -25, -25
};

static void init_angle_dirs(void)
{
    WORD i;
    for (i = 0; i < NUM_ANGLES; ++i)
    {
        g_dir[i][0] = (LONG)sin_table_64[(i + NUM_ANGLES/4) % NUM_ANGLES];
        g_dir[i][1] = (LONG)sin_table_64[i];
    }
}

static APTR alloc_fast_or_public(ULONG bytes)
{
    APTR p;

    p = AllocMem(bytes, MEMF_FAST | MEMF_CLEAR);
    if (!p)
    {
        p = AllocMem(bytes, MEMF_PUBLIC | MEMF_CLEAR);
    }
    return p;
}

BOOL init_display(void)
{
    LoadView(NULL);
    WaitTOF();
    WaitTOF();

    /* Kill all DMA except blitter (we re-enable what we need after copper setup).
     * This removes sprite/disk/audio DMA bus contention from previous OS state.
     * DMAF_ALL without SETCLR clears all DMA enable bits. */
    CREGS->dmacon = DMAF_ALL;

    return ((((struct GfxBase *)GfxBase)->DisplayFlags & PAL) == PAL);
}

void reset_display(void)
{
    LoadView(((struct GfxBase *)GfxBase)->ActiView);
    WaitTOF();
    WaitTOF();
    CREGS->cop1lc = (ULONG)((struct GfxBase *)GfxBase)->copinit;
    RethinkDisplay();
}

static BOOL left_mouse_down(void)
{
    volatile UBYTE *ciaa_pra = (volatile UBYTE *)0xBFE001;
    return ((*ciaa_pra & PRA_FIR0_BIT) == 0);
}

static void build_texture(UBYTE *tex)
{
    WORD x, y;
    UBYTE c;

    for (y = 0; y < TEX_H; ++y)
    {
        for (x = 0; x < TEX_W; ++x)
        {
            WORD dx = x - (TEX_W / 2);
            WORD dy = y - (TEX_H / 2);
            WORD ring = (WORD)(((dx * dx) + (dy * dy)) >> 4) & 15;
            WORD xorv = (WORD)(((x ^ y) >> 1) & 7);
            WORD checker = ((((x >> 2) ^ (y >> 2)) & 1) ? 4 : 0);

            c = (UBYTE)((ring ^ xorv ^ checker) & 15);
            tex[y * TEX_W + x] = g_stretch_lut[c];
        }
    }
}

/*
 * Precompute angle/scanline floor setup.
 * du2/dv2 are doubled because the renderer samples once for every 2 screen pixels.
 * v (and dv_dx) are scaled by ASPECT so the texture looks square on PAL (tall pixels).
 */
static void build_line_model(void)
{
    WORD ang, ly;

    for (ang = 0; ang < NUM_ANGLES; ++ang)
    {
        LONG fx = g_dir[ang][0];
        LONG fy = g_dir[ang][1];
        LONG rx = -fy;
        LONG ry =  fx;

        for (ly = 0; ly < VISIBLE_LINES; ++ly)
        {
            LONG dist;
            LONG step;
            LONG du_dx, dv_dx;
            LONG u0, v0;
            WORD y = (WORD)(HORIZON + ly);

            dist = FLOOR_SCALE / (LONG)(y - HORIZON + 1);
            step = dist >> STEP_SHIFT;

            du_dx = (rx * step) >> 8;
            dv_dx = (ry * step) >> 8;
            dv_dx = (dv_dx * (LONG)ASPECT_NUM) / (LONG)ASPECT_DEN;

            u0 = ((fx * dist) >> 8) - du_dx * (SCREEN_W / 2);
            v0 = (((fy * dist) >> 8) * (LONG)ASPECT_NUM) / (LONG)ASPECT_DEN - dv_dx * (SCREEN_W / 2);

            g_line_model[ang][ly].u0  = u0;
            g_line_model[ang][ly].v0  = v0;
            g_line_model[ang][ly].du2 = du_dx * 2;
            g_line_model[ang][ly].dv2 = dv_dx * 2;
        }
    }

}

static BOOL build_copper_list(CopperState *cs)
{
    UWORD *cop;
    UWORD *p;
    ULONG words;
    WORD i;

    /* Extra 4 words: wait for line $FF then disable bitplanes + black border. */
    words = 2 + 8 + 6 + 4 + (DEPTH * 4) + 32 + 4 + 2 + 2;

    cop = (UWORD *)AllocMem(words * sizeof(UWORD), MEMF_CHIP | MEMF_CLEAR);
    if (!cop)
    {
        return FALSE;
    }

    cs->list = cop;
    cs->bytes = words * sizeof(UWORD);
    p = cop;

    *p++ = (UWORD)((0x20 << 8) | 0x07);
    *p++ = 0xFFFE;

    *p++ = DIWSTRT; *p++ = 0x2C81;
    *p++ = DIWSTOP; *p++ = 0x2CC1;
    *p++ = DDFSTRT; *p++ = 0x0038;
    *p++ = DDFSTOP; *p++ = 0x00D0;

    *p++ = BPLCON0; *p++ = (UWORD)(0x0200 | (DEPTH << 12));
    *p++ = BPLCON1; *p++ = 0x0000;
    *p++ = BPLCON2; *p++ = 0x0000;

    *p++ = BPL1MOD; *p++ = 0;
    *p++ = BPL2MOD; *p++ = 0;

    for (i = 0; i < DEPTH; ++i)
    {
        *p++ = (UWORD)(BPL1PTH + (i * 4));
        cs->bpl_hi[i] = p;
        *p++ = 0;

        *p++ = (UWORD)(BPL1PTL + (i * 4));
        cs->bpl_lo[i] = p;
        *p++ = 0;
    }

    for (i = 0; i < 16; ++i)
    {
        *p++ = COLOR_REG(i);
        *p++ = g_palette[i];
    }

    /* Wait for raster line $FF (last line before wrap), then kill bitplane DMA
     * and set border to black.  This prevents the hardware fetching past the
     * end of our 256-line buffer and showing garbage on lines 257-312 (PAL). */
    *p++ = (UWORD)((0xFF << 8) | 0x07);
    *p++ = 0xFFFE;
    *p++ = BPLCON0;
    *p++ = 0x0000;
    *p++ = COLOR00;
    *p++ = 0x0000;

    *p++ = 0xFFFF;
    *p++ = 0xFFFE;

    return TRUE;
}

static void patch_copper_bplptrs(CopperState *cs, UBYTE *screen)
{
    WORD i;
    ULONG addr;

    for (i = 0; i < DEPTH; ++i)
    {
        addr = (ULONG)screen + (ULONG)i * BPL_SIZE;
        *(cs->bpl_hi[i]) = (UWORD)(addr >> 16);
        *(cs->bpl_lo[i]) = (UWORD)(addr & 0xFFFF);
    }
}

static BOOL open_eclock_timer(TimerState *ts)
{
    memset(ts, 0, sizeof(*ts));

    ts->port = CreateMsgPort();
    if (!ts->port)
    {
        return FALSE;
    }

    ts->req = (struct IORequest *)CreateIORequest(ts->port, sizeof(struct timerequest));
    if (!ts->req)
    {
        DeleteMsgPort(ts->port);
        ts->port = NULL;
        return FALSE;
    }

    if (OpenDevice((UBYTE *)TIMERNAME, UNIT_ECLOCK, (struct IORequest *)ts->req, 0) != 0)
    {
        DeleteIORequest(ts->req);
        DeleteMsgPort(ts->port);
        ts->req = NULL;
        ts->port = NULL;
        return FALSE;
    }

    TimerBase = ts->req->io_Device;
    return TRUE;
}

static void close_eclock_timer(TimerState *ts)
{
    if (ts->req)
    {
        if (ts->req->io_Device)
        {
            CloseDevice((struct IORequest *)ts->req);
        }
        DeleteIORequest(ts->req);
        ts->req = NULL;
    }

    if (ts->port)
    {
        DeleteMsgPort(ts->port);
        ts->port = NULL;
    }

    TimerBase = NULL;
}

static BOOL fps_counter_init(FpsCounter *fps)
{
    memset(fps, 0, sizeof(*fps));
    fps->hz = ReadEClock(&fps->window_start);
    fps->run_start = fps->window_start;
    return (fps->hz != 0);
}

static void fps_counter_tick(FpsCounter *fps, ULONG frame_ticks, ULONG c2p_ticks, ULONG sync_ticks)
{
    struct EClockVal now;
    ULONG elapsed;
    ULONG fps_x10;
    ULONG render_ticks;
    ULONG render_ms;
    ULONG c2p_ms;
    ULONG sync_ms;
    ULONG render_pf_ms;
    ULONG c2p_pf_ms;
    ULONG sync_pf_ms;
    ULONG render_pct;
    ULONG c2p_pct;
    ULONG sync_pct;

    if (!fps->hz)
    {
        return;
    }

    if (frame_ticks > (c2p_ticks + sync_ticks))
    {
        render_ticks = frame_ticks - c2p_ticks - sync_ticks;
    }
    else
    {
        render_ticks = 0;
    }

    ++fps->window_frames;
    ++fps->total_frames;
    fps->window_frame_ticks += frame_ticks;
    fps->total_frame_ticks += frame_ticks;
    fps->window_render_ticks += render_ticks;
    fps->window_c2p_ticks += c2p_ticks;
    fps->window_sync_ticks += sync_ticks;
    fps->total_render_ticks += render_ticks;
    fps->total_c2p_ticks += c2p_ticks;
    fps->total_sync_ticks += sync_ticks;

    ReadEClock(&now);
    elapsed = now.ev_lo - fps->window_start.ev_lo;
    if (elapsed < fps->hz)
    {
        return;
    }

    fps_x10 = (ULONG)(((fps->window_frames * fps->hz * 10UL) + (elapsed >> 1)) / elapsed);
    render_ms = ticks_to_ms_window(fps->window_render_ticks, fps->hz);
    c2p_ms = ticks_to_ms_window(fps->window_c2p_ticks, fps->hz);
    sync_ms = ticks_to_ms_window(fps->window_sync_ticks, fps->hz);
    render_pf_ms = ticks_to_ms_per_frame(fps->window_render_ticks, fps->hz, fps->window_frames);
    c2p_pf_ms = ticks_to_ms_per_frame(fps->window_c2p_ticks, fps->hz, fps->window_frames);
    sync_pf_ms = ticks_to_ms_per_frame(fps->window_sync_ticks, fps->hz, fps->window_frames);
    render_pct = pct_of(fps->window_render_ticks, fps->window_frame_ticks);
    c2p_pct = pct_of(fps->window_c2p_ticks, fps->window_frame_ticks);
    sync_pct = pct_of(fps->window_sync_ticks, fps->window_frame_ticks);

    printf("\rFPS: %lu.%lu | %s:%lums(%lums/f) %lu%% %s:%lums(%lums/f) %lu%% S:%lums(%lums/f) %lu%%   ",
           fps_x10 / 10UL, fps_x10 % 10UL,
           g_stage_render_label,
           render_ms, render_pf_ms, render_pct,
           g_stage_convert_label,
           c2p_ms, c2p_pf_ms, c2p_pct,
           sync_ms, sync_pf_ms, sync_pct);
    fflush(stdout);
    if (g_log)
    {
        fprintf(g_log, "FPS: %lu.%lu | %s:%lums(%lums/f) %lu%% %s:%lums(%lums/f) %lu%% S:%lums(%lums/f) %lu%%\n",
                fps_x10 / 10UL, fps_x10 % 10UL,
                g_stage_render_label,
                render_ms, render_pf_ms, render_pct,
                g_stage_convert_label,
                c2p_ms, c2p_pf_ms, c2p_pct,
                sync_ms, sync_pf_ms, sync_pct);
        fflush(g_log);
    }

    fps->window_frames = 0;
    fps->window_frame_ticks = 0;
    fps->window_render_ticks = 0;
    fps->window_c2p_ticks = 0;
    fps->window_sync_ticks = 0;
    fps->window_start = now;
}

static void fps_counter_shutdown(const FpsCounter *fps)
{
    struct EClockVal now;
    ULONG elapsed;
    ULONG avg_x10;
    ULONG render_pct;
    ULONG c2p_pct;
    ULONG sync_pct;

    if (!fps->hz || !fps->total_frames)
    {
        print_both("\n");
        return;
    }

    ReadEClock(&now);
    elapsed = now.ev_lo - fps->run_start.ev_lo;
    if (!elapsed)
    {
        print_both("\n");
        return;
    }

    avg_x10 = (ULONG)(((fps->total_frames * fps->hz * 10UL) + (elapsed >> 1)) / elapsed);
    render_pct = pct_of(fps->total_render_ticks, fps->total_frame_ticks);
    c2p_pct = pct_of(fps->total_c2p_ticks, fps->total_frame_ticks);
    sync_pct = pct_of(fps->total_sync_ticks, fps->total_frame_ticks);
    print_both("\rFPS avg: %lu.%lu | %s:%lu%% %s:%lu%% S:%lu%%\n",
               avg_x10 / 10UL, avg_x10 % 10UL,
               g_stage_render_label,
               render_pct,
               g_stage_convert_label,
               c2p_pct,
               sync_pct);
}

static void render_chunky(UBYTE *chunky, const UBYTE *tex, ULONG frame)
{
    WORD ang = (WORD)(frame & (NUM_ANGLES - 1));

    /* Running counters avoid two 32-bit multiplies per frame.
     * g_camu/g_camv are updated here so the first call (frame=0) correctly
     * uses 0 and subsequent calls advance by 48/24 each frame. */
    render_chunky_all_asm(chunky, tex, g_camu, g_camv,
                          g_line_model[ang], (WORD)(CHUNKY_H / 2));
    g_camu += 48;
    g_camv += 24;
}

int main(int argc, char **argv)
{
    const char *log_path = (argc > 1 && argv[1] && argv[1][0]) ? argv[1] : "demo.log";
    const BOOL s2p_bench_only = (S2P_BENCH_ONLY != 0);
    BOOL is_pal;
    BOOL fps_enabled = FALSE;
    UBYTE *screen[2] = { NULL, NULL };
    UBYTE *chunky = NULL;
    UBYTE *tex = NULL;
    UBYTE *c2p_stage = NULL;
    UBYTE *c2p_static_src = NULL;
    struct BitMap bm[2];
    CopperState cop;
    FpsCounter fps;
    TimerState timer;
    ULONG frame = 0;
    WORD show_idx = 0;
    WORD draw_idx = 1;
    BOOL chunky_in_chip = FALSE;
    BOOL wb_was_open = FALSE;

    memset(&cop, 0, sizeof(cop));
    memset(bm, 0, sizeof(bm));
    memset(&timer, 0, sizeof(timer));

    GfxBase = (struct GfxBase *)OpenLibrary("graphics.library", 0);
    if (!GfxBase)
    {
        return 20;
    }

    IntuitionBase = (struct IntuitionBase *)OpenLibrary("intuition.library", 0);
    if (!IntuitionBase)
    {
        CloseLibrary((struct Library *)GfxBase);
        return 20;
    }

    SetTaskPri(FindTask(NULL), TASK_PRIORITY);

    /* Close the Workbench screen so Intuition stops maintaining its view.
     * Without this the OS re-enables Workbench bitplane DMA on every VBL,
     * consuming chip bus bandwidth proportional to the WB screen resolution. */
    wb_was_open = CloseWorkBench();

    g_log = fopen(log_path, "w");
    if (g_log)
    {
        print_both("Logging to %s\n", log_path);
    }
    else
    {
        printf("Log open failed: %s\n", log_path);
    }

    is_pal = init_display();
    print_both("PAL display: %d\n", is_pal);
    print_both("Chipset build: %s\n", CHIPSET_NAME);

    if (!is_pal)
    {
        print_both("This version assumes PAL timings.\n");
        reset_display();
        if (g_log)
        {
            fclose(g_log);
            g_log = NULL;
        }
        CloseLibrary((struct Library *)IntuitionBase);
        CloseLibrary((struct Library *)GfxBase);
        return 20;
    }

    screen[0] = (UBYTE *)AllocMem(SCREEN_BYTES, MEMF_CHIP | MEMF_CLEAR);
    screen[1] = (UBYTE *)AllocMem(SCREEN_BYTES, MEMF_CHIP | MEMF_CLEAR);
    chunky    = (UBYTE *)alloc_fast_or_public(CHUNKY_BYTES);
    tex       = (UBYTE *)alloc_fast_or_public(TEX_BYTES);
    g_line_model = (LineModel (*)[VISIBLE_LINES])alloc_fast_or_public(
                       (ULONG)sizeof(LineModel) * NUM_ANGLES * VISIBLE_LINES);
    c2p_stage = (UBYTE *)c2p_blit_4bpl_stageptr_c();
    if (!screen[0] || !screen[1] || !chunky || !tex || !g_line_model)
    {
        print_both("AllocMem failed\n");

        if (screen[0])    FreeMem(screen[0], SCREEN_BYTES);
        if (screen[1])    FreeMem(screen[1], SCREEN_BYTES);
        if (chunky)       FreeMem(chunky, CHUNKY_BYTES);
        if (tex)          FreeMem(tex, TEX_BYTES);
        if (g_line_model) FreeMem(g_line_model,
                              (ULONG)sizeof(LineModel) * NUM_ANGLES * VISIBLE_LINES);

        reset_display();
        if (g_log)
        {
            fclose(g_log);
            g_log = NULL;
        }
        CloseLibrary((struct Library *)IntuitionBase);
        CloseLibrary((struct Library *)GfxBase);
        return 20;
    }
    chunky_in_chip = ((TypeOfMem((APTR)chunky) & MEMF_CHIP) != 0);

    print_both("Path: chunky + c2p\n");
    print_both("Chunky source: %s\n", mem_type_name((APTR)chunky));
    print_both("Line model: %s\n", mem_type_name((APTR)g_line_model));
    print_both("C2P backend: %s\n", C2P_BACKEND_NAME);
    print_both("S2P bench mode: %s\n", s2p_bench_only ? "ON (no per-frame CPU draw)" : "OFF");
    if (s2p_bench_only)
    {
        print_both("C2P source mode: %s\n", chunky_in_chip ? "direct CHIP static buffer" : "FAST->CHIP staged once");
    }
    else
    {
        print_both("C2P source mode: %s\n", chunky_in_chip ? "direct CHIP" : "FAST->CHIP staging copy");
    }

    build_texture(tex);
    init_angle_dirs();
    build_line_model();
    c2p_blit_4bpl_init_c();
    if (s2p_bench_only)
    {
        render_chunky(chunky, tex, 0);
        if (!chunky_in_chip)
        {
            CopyMemQuick((APTR)chunky, (APTR)c2p_stage, CHUNKY_BYTES);
            c2p_static_src = c2p_stage;
        }
        else
        {
            c2p_static_src = chunky;
        }
    }

    InitBitMap(&bm[0], DEPTH, SCREEN_W, SCREEN_H);
    InitBitMap(&bm[1], DEPTH, SCREEN_W, SCREEN_H);
    {
        WORD i;
        for (i = 0; i < DEPTH; ++i)
        {
            bm[0].Planes[i] = (PLANEPTR)(screen[0] + (ULONG)i * BPL_SIZE);
            bm[1].Planes[i] = (PLANEPTR)(screen[1] + (ULONG)i * BPL_SIZE);
        }
    }

    if (!build_copper_list(&cop))
    {
        print_both("AllocMem(copper) failed\n");
        FreeMem(tex, TEX_BYTES);
        FreeMem(chunky, CHUNKY_BYTES);
        FreeMem(screen[0], SCREEN_BYTES);
        FreeMem(screen[1], SCREEN_BYTES);
        reset_display();
        if (g_log)
        {
            fclose(g_log);
            g_log = NULL;
        }
        CloseLibrary((struct Library *)IntuitionBase);
        CloseLibrary((struct Library *)GfxBase);
        return 20;
    }

    CREGS->dmacon = DMAF_SETCLR | DMAF_MASTER | DMAF_RASTER | DMAF_COPPER | DMAF_BLITTER;

    if (open_eclock_timer(&timer))
    {
        fps_enabled = fps_counter_init(&fps);
        if (!fps_enabled)
        {
            print_both("ReadEClock unavailable; FPS counter disabled.\n");
        }
    }
    else
    {
        print_both("timer.device open failed; FPS counter disabled.\n");
    }

    {
        UBYTE *c2p_src = chunky;
        if (!s2p_bench_only)
        {
            render_chunky(chunky, tex, frame++);
            if (!chunky_in_chip)
            {
                CopyMemQuick((APTR)chunky, (APTR)c2p_stage, CHUNKY_BYTES);
                c2p_src = c2p_stage;
            }
        }
        else
        {
            c2p_src = c2p_static_src;
        }
        c2p_blit_4bpl_c(c2p_src, screen[0]);
        c2p_blit_4bpl_waitblit_c();
    }
    patch_copper_bplptrs(&cop, screen[0]);

    CREGS->cop1lc = (ULONG)cop.list;
    CREGS->copjmp1 = 0;

    while (!left_mouse_down())
    {
        ULONG frame_ticks = 0;
        ULONG c2p_ticks = 0;
        ULONG sync_ticks = 0;
        struct EClockVal tf0;
        struct EClockVal tf1;
        struct EClockVal t0;
        struct EClockVal t1;

        if (fps_enabled) ReadEClock(&tf0);
        if (!s2p_bench_only)
        {
            render_chunky(chunky, tex, frame++);
        }

        {
            UBYTE *c2p_src = chunky;
            if (fps_enabled) ReadEClock(&t0);
            if (s2p_bench_only)
            {
                c2p_src = c2p_static_src;
            }
            else if (!chunky_in_chip)
            {
                CopyMemQuick((APTR)chunky, (APTR)c2p_stage, CHUNKY_BYTES);
                c2p_src = c2p_stage;
            }
            c2p_blit_4bpl_c(c2p_src, screen[draw_idx]);
            if (fps_enabled)
            {
                ReadEClock(&t1);
                c2p_ticks = t1.ev_lo - t0.ev_lo;
                ReadEClock(&t0);
            }
        }

        WaitTOF();
        c2p_blit_4bpl_waitblit_c();
        patch_copper_bplptrs(&cop, screen[draw_idx]);
        if (fps_enabled)
        {
            ReadEClock(&t1);
            sync_ticks = t1.ev_lo - t0.ev_lo;
            ReadEClock(&tf1);
            frame_ticks = tf1.ev_lo - tf0.ev_lo;
        }
        if (fps_enabled)
        {
            fps_counter_tick(&fps, frame_ticks, c2p_ticks, sync_ticks);
        }

        show_idx = draw_idx;
        draw_idx = (WORD)(show_idx ^ 1);
    }

    if (fps_enabled)
    {
        fps_counter_shutdown(&fps);
    }

    c2p_blit_4bpl_waitblit_c();

    close_eclock_timer(&timer);

    reset_display();

    if (wb_was_open)
    {
        OpenWorkBench();
    }

    FreeMem(cop.list, cop.bytes);
    FreeMem(tex, TEX_BYTES);
    FreeMem(chunky, CHUNKY_BYTES);
    FreeMem(g_line_model, (ULONG)sizeof(LineModel) * NUM_ANGLES * VISIBLE_LINES);
    FreeMem(screen[0], SCREEN_BYTES);
    FreeMem(screen[1], SCREEN_BYTES);
    if (g_log)
    {
        fclose(g_log);
        g_log = NULL;
    }

    CloseLibrary((struct Library *)IntuitionBase);
    CloseLibrary((struct Library *)GfxBase);

    return 0;
}
