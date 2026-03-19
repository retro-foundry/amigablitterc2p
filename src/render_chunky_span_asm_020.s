        section code,code
        xdef    _render_chunky_span_asm
        xdef    _render_chunky_span_copy2_asm
        xdef    _render_chunky_all_asm

; 68020-tuned variant used by AGA build.
; Requires -cpu=68020 (set automatically by CMakeLists.txt for the AGA target).
;
; Optimisations vs the 68000 version
; ───────────────────────────────────
; render_chunky_all_asm
;   · Outer scanline loop lives here, eliminating ~80 C→asm function calls per
;     frame and their full movem / parameter-load / movem / rts overhead.
;   · BFEXTU reduces the texture-index calculation from 7 instructions to 4
;     per pixel  (bfextu×2 + lsl + or  vs  move+lsr+and+move+lsr+and+or).
;   · (An,Dn.l) extended index addressing avoids the 68020 sign-extension
;     pipeline stall that (An,Dn.w) causes.
;   · 4× unrolled inner loop halves dbf branch overhead vs the 2× variant.
;   · add.l (U/V stepping) interleaved with the next pixel's bfextu to cover
;     indexed-read memory latency without wasting cycles.
;
; Per-span helpers (_render_chunky_span_asm, _render_chunky_span_copy2_asm)
;   · Same bfextu + .l addressing improvements; 2× unroll retained.

CHUNKY_W    EQU     160             ; must match CHUNKY_W  in main.c
CHUNKY_H    EQU     160             ; must match VISIBLE_LINES in main.c
CHUNKY_BYTES EQU    CHUNKY_W*CHUNKY_H   ; 25 600 — fits in 16-bit displacement
LM_STRIDE   EQU     32              ; 2 * sizeof(LineModel): skip odd entries

; ─────────────────────────────────────────────────────────────────────────────
; void render_chunky_all_asm(
;   UBYTE            *chunky,      4(sp)  output buffer in FAST RAM
;   const UBYTE      *tex,         8(sp)  32×32 texture in FAST RAM
;   LONG              camu,       12(sp)  camera U offset
;   LONG              camv,       16(sp)  camera V offset
;   const LineModel  *lm_base,   20(sp)  &g_line_model[ang][0]
;   WORD              num_pairs,  24(sp)  CHUNKY_H/2=80 (int-promoted on stack)
; )
;
; LineModel = { LONG u0(+0), v0(+4), du2(+8), dv2(+12) }  — 16 bytes each.
; Caller supplies the base for the current angle; the asm steps by LM_STRIDE
; (32 bytes) per outer iteration, using every other entry because two output
; rows share the same model (2× vertical scale).
;
; Register map after push (d2-d7/a2-a6 = 11 regs × 4 = 44 bytes):
;   a0 = row0 ptr   (advances CHUNKY_W*2 per outer iter, auto via a0+/a2+)
;   a1 = tex        (constant)
;   a2 = row1 ptr   (= a0 + CHUNKY_W, recomputed each outer iter)
;   a3 = LineModel ptr (advances LM_STRIDE per outer iter)
;   a4 = camu       (constant held in address reg; add.l a4,Dn is valid 68020)
;   a5 = camv       (constant)
;   a6 = end-of-chunky sentinel (= chunky + CHUNKY_BYTES, constant)
;   d3 = inner loop counter (reinit to CHUNKY_W/4-1 = 39 each outer iter)
;   d4 = du2, d5 = dv2  (reloaded from LineModel each outer iter)
;   d6 = U current, d7 = V current
;   d0, d1 = scratch for index calc
;   d2 = fetched texel byte
; ─────────────────────────────────────────────────────────────────────────────
_render_chunky_all_asm:
        movem.l d2-d7/a2-a6,-(sp)       ; 44 bytes — params now at base+44

        movea.l 48(sp),a0               ; chunky
        movea.l 52(sp),a1               ; tex
        movea.l 56(sp),a4               ; camu
        movea.l 60(sp),a5               ; camv
        movea.l 64(sp),a3               ; lm_base
        lea     CHUNKY_BYTES(a0),a6     ; end sentinel

.outer:
        ; ── Load line model + apply camera offsets ────────────────────────────
        move.l  0(a3),d6
        add.l   a4,d6                   ; u = u0 + camu
        move.l  4(a3),d7
        add.l   a5,d7                   ; v = v0 + camv
        move.l  8(a3),d4                ; du2
        move.l  12(a3),d5               ; dv2

        lea     CHUNKY_W(a0),a2         ; row1 = row0 + CHUNKY_W

        ; ── Inner pixel loop: CHUNKY_W pixels, 4 per dbf iteration ───────────
        ; CHUNKY_W/4 = 40 → counter = 39
        move.w  #(CHUNKY_W/4-1),d3
        cnop    0,4

.inner4:
        ; ── Pixel 0 ───────────────────────────────────────────────────────────
        bfextu  d7{#19:#5},d0           ; V_row  = d7[12:8]  → d0[4:0]
        bfextu  d6{#19:#5},d1           ; U_col  = d6[12:8]  → d1[4:0]
        lsl.w   #5,d0                   ; V_row * 32
        add.l   d5,d7                   ; V += dv2  (covers lsl dep on d0)
        or.w    d1,d0                   ; tex_index = V_row*32 | U_col
        add.l   d4,d6                   ; U += du2
        move.b  (a1,d0.l),d2            ; fetch texel → d2

        ; ── Pixel 1 early — runs during pix-0 memory read latency ────────────
        bfextu  d7{#19:#5},d0
        bfextu  d6{#19:#5},d1

        ; ── Pixel 0 write — d2 is ready after the two bfextu gap insns ───────
        move.b  d2,(a0)+
        move.b  d2,(a2)+

        ; ── Pixel 1 late ──────────────────────────────────────────────────────
        lsl.w   #5,d0
        add.l   d5,d7
        or.w    d1,d0
        add.l   d4,d6
        move.b  (a1,d0.l),d2

        ; ── Pixel 2 early ─────────────────────────────────────────────────────
        bfextu  d7{#19:#5},d0
        bfextu  d6{#19:#5},d1

        ; ── Pixel 1 write ─────────────────────────────────────────────────────
        move.b  d2,(a0)+
        move.b  d2,(a2)+

        ; ── Pixel 2 late ──────────────────────────────────────────────────────
        lsl.w   #5,d0
        add.l   d5,d7
        or.w    d1,d0
        add.l   d4,d6
        move.b  (a1,d0.l),d2

        ; ── Pixel 3 early ─────────────────────────────────────────────────────
        bfextu  d7{#19:#5},d0
        bfextu  d6{#19:#5},d1

        ; ── Pixel 2 write ─────────────────────────────────────────────────────
        move.b  d2,(a0)+
        move.b  d2,(a2)+

        ; ── Pixel 3 late ──────────────────────────────────────────────────────
        lsl.w   #5,d0
        add.l   d5,d7
        or.w    d1,d0
        add.l   d4,d6
        move.b  (a1,d0.l),d2

        ; ── Pixel 3 write ─────────────────────────────────────────────────────
        move.b  d2,(a0)+
        move.b  d2,(a2)+

        dbf     d3,.inner4

        ; a0 now points to start of row1; advance to row2
        lea     CHUNKY_W(a0),a0
        lea     LM_STRIDE(a3),a3
        cmpa.l  a6,a0
        blt     .outer                  ; 16-bit disp: inner loop is >127 bytes

.all_done:
        movem.l (sp)+,d2-d7/a2-a6
        rts


; ─────────────────────────────────────────────────────────────────────────────
; void render_chunky_span_asm(
;     UBYTE *dst,         4(sp)
;     const UBYTE *tex,   8(sp)
;     LONG u,            12(sp)
;     LONG v,            16(sp)
;     LONG du2,          20(sp)
;     LONG dv2,          24(sp)
;     LONG count         28(sp)
; )
; ─────────────────────────────────────────────────────────────────────────────
_render_chunky_span_asm:
        movem.l d2-d7/a2,-(sp)          ; 7 regs × 4 = 28 bytes

        movea.l 32(sp),a0
        movea.l 36(sp),a1
        move.l  40(sp),d6               ; u
        move.l  44(sp),d7               ; v
        move.l  48(sp),d4               ; du2
        move.l  52(sp),d5               ; dv2

        move.w  58(sp),d3               ; count (low word of promoted int)
        lsr.w   #1,d3
        subq.w  #1,d3
        bmi.s   .done_s

.loop_s:
        bfextu  d7{#19:#5},d0
        bfextu  d6{#19:#5},d1
        lsl.w   #5,d0
        add.l   d5,d7
        or.w    d1,d0
        add.l   d4,d6
        move.b  (a1,d0.l),(a0)+

        bfextu  d7{#19:#5},d0
        bfextu  d6{#19:#5},d1
        lsl.w   #5,d0
        add.l   d5,d7
        or.w    d1,d0
        add.l   d4,d6
        move.b  (a1,d0.l),(a0)+

        dbf     d3,.loop_s

.done_s:
        movem.l (sp)+,d2-d7/a2
        rts


; ─────────────────────────────────────────────────────────────────────────────
; void render_chunky_span_copy2_asm(
;     UBYTE *row0,         4(sp)
;     UBYTE *row1,         8(sp)
;     const UBYTE *tex,   12(sp)
;     LONG u,             16(sp)
;     LONG v,             20(sp)
;     LONG du2,           24(sp)
;     LONG dv2,           28(sp)
;     LONG count          32(sp)
; )
; ─────────────────────────────────────────────────────────────────────────────
_render_chunky_span_copy2_asm:
        movem.l d2-d7/a2-a3,-(sp)       ; 8 regs × 4 = 32 bytes

        movea.l 36(sp),a0               ; row0
        movea.l 40(sp),a2               ; row1
        movea.l 44(sp),a1               ; tex
        move.l  48(sp),d6               ; u
        move.l  52(sp),d7               ; v
        move.l  56(sp),d4               ; du2
        move.l  60(sp),d5               ; dv2

        move.w  66(sp),d3               ; count (low word)
        lsr.w   #1,d3
        subq.w  #1,d3
        bmi.s   .tail_c2

.loop_c2:
        ; ── Pixel 0 ───────────────────────────────────────────────────────────
        bfextu  d7{#19:#5},d0
        bfextu  d6{#19:#5},d1
        lsl.w   #5,d0
        add.l   d5,d7
        or.w    d1,d0
        add.l   d4,d6
        move.b  (a1,d0.l),d2

        ; ── Pixel 1 early ─────────────────────────────────────────────────────
        bfextu  d7{#19:#5},d0
        bfextu  d6{#19:#5},d1

        ; ── Pixel 0 write ─────────────────────────────────────────────────────
        move.b  d2,(a0)+
        move.b  d2,(a2)+

        ; ── Pixel 1 late ──────────────────────────────────────────────────────
        lsl.w   #5,d0
        add.l   d5,d7
        or.w    d1,d0
        add.l   d4,d6
        move.b  (a1,d0.l),d2

        ; ── Pixel 1 write ─────────────────────────────────────────────────────
        move.b  d2,(a0)+
        move.b  d2,(a2)+

        dbf     d3,.loop_c2

.tail_c2:
        btst    #0,67(sp)               ; odd count remainder?
        beq.s   .done_c2

        bfextu  d7{#19:#5},d0
        bfextu  d6{#19:#5},d1
        lsl.w   #5,d0
        or.w    d1,d0
        move.b  (a1,d0.l),d2
        move.b  d2,(a0)+
        move.b  d2,(a2)+

.done_c2:
        movem.l (sp)+,d2-d7/a2-a3
        rts
