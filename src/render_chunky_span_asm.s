        section code,code
        xdef    _render_chunky_span_asm
        xdef    _render_chunky_span_copy2_asm
        xdef    _render_chunky_all_asm

; 68000 variant used by ECS build.
;
; Optimisations vs the original per-span version
; ───────────────────────────────────────────────
; render_chunky_all_asm
;   · Outer scanline loop lives here, eliminating ~80 C→asm function calls per
;     frame and their movem / parameter-load / movem / rts overhead.
;   · 4× unrolled inner loop halves dbf branch cost vs the 2× variant.
;   · V and U index computations are interleaved (V move/V shift/U move/U shift
;     vs the original sequential order) so consecutive dependent instructions
;     are separated by independent work on the other coordinate.
;   · add.l (U/V stepping) is placed immediately after the indexed read so it
;     fills the bus-cycle gap before d2 is consumed by the two writes.

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
; Steps through every other entry (stride LM_STRIDE = 32 bytes) because two
; output rows share the same model (2× vertical scale).
;
; Register map after push (d2-d7/a2-a6 = 11 regs × 4 = 44 bytes):
;   a0 = row0 ptr  (advances CHUNKY_W*2 per outer iter via a0+/a2+)
;   a1 = tex       (constant)
;   a2 = row1 ptr  (= a0 + CHUNKY_W, recomputed each outer iter)
;   a3 = LineModel ptr (advances LM_STRIDE per outer iter)
;   a4 = camu      (constant; add.l An,Dn is valid on 68000)
;   a5 = camv      (constant)
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

.inner4:
        ; ── Pixel 0 ───────────────────────────────────────────────────────────
        ; V and U computations interleaved: each result-use is 1 instruction
        ; after the write that produces it, avoiding back-to-back RAW pairs.
        move.w  d7,d0                   ; d0 = V[15:0]
        move.w  d6,d1                   ; d1 = U[15:0]  (independent)
        lsr.w   #3,d0                   ; V >> 3
        lsr.w   #8,d1                   ; U >> 8
        andi.w  #$03e0,d0               ; V_row * 32 in bits[9:5]
        andi.w  #$001f,d1               ; U_col in bits[4:0]
        or.w    d1,d0                   ; tex_index
        move.b  (a1,d0.w),d2            ; fetch texel → d2
        add.l   d4,d6                   ; U += du2  (fills bus-cycle before d2)
        add.l   d5,d7                   ; V += dv2
        move.b  d2,(a0)+
        move.b  d2,(a2)+

        ; ── Pixel 1 ───────────────────────────────────────────────────────────
        move.w  d7,d0
        move.w  d6,d1
        lsr.w   #3,d0
        lsr.w   #8,d1
        andi.w  #$03e0,d0
        andi.w  #$001f,d1
        or.w    d1,d0
        move.b  (a1,d0.w),d2
        add.l   d4,d6
        add.l   d5,d7
        move.b  d2,(a0)+
        move.b  d2,(a2)+

        ; ── Pixel 2 ───────────────────────────────────────────────────────────
        move.w  d7,d0
        move.w  d6,d1
        lsr.w   #3,d0
        lsr.w   #8,d1
        andi.w  #$03e0,d0
        andi.w  #$001f,d1
        or.w    d1,d0
        move.b  (a1,d0.w),d2
        add.l   d4,d6
        add.l   d5,d7
        move.b  d2,(a0)+
        move.b  d2,(a2)+

        ; ── Pixel 3 ───────────────────────────────────────────────────────────
        move.w  d7,d0
        move.w  d6,d1
        lsr.w   #3,d0
        lsr.w   #8,d1
        andi.w  #$03e0,d0
        andi.w  #$001f,d1
        or.w    d1,d0
        move.b  (a1,d0.w),d2
        add.l   d4,d6
        add.l   d5,d7
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
        move.l  40(sp),d6
        move.l  44(sp),d7
        move.l  48(sp),d4
        move.l  52(sp),d5

        move.w  58(sp),d3
        lsr.w   #1,d3
        subq.w  #1,d3
        bmi.s   .done_s

.loop_s:
        move.w  d7,d0
        move.w  d6,d1
        lsr.w   #3,d0
        lsr.w   #8,d1
        andi.w  #$03e0,d0
        andi.w  #$001f,d1
        or.w    d1,d0
        move.b  (a1,d0.w),(a0)+
        add.l   d4,d6
        add.l   d5,d7

        move.w  d7,d0
        move.w  d6,d1
        lsr.w   #3,d0
        lsr.w   #8,d1
        andi.w  #$03e0,d0
        andi.w  #$001f,d1
        or.w    d1,d0
        move.b  (a1,d0.w),(a0)+
        add.l   d4,d6
        add.l   d5,d7

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

        movea.l 36(sp),a0
        movea.l 40(sp),a2
        movea.l 44(sp),a1
        move.l  48(sp),d6
        move.l  52(sp),d7
        move.l  56(sp),d4
        move.l  60(sp),d5

        move.w  66(sp),d3
        lsr.w   #1,d3
        subq.w  #1,d3
        bmi.s   .tail_c2

.loop_c2:
        move.w  d7,d0
        move.w  d6,d1
        lsr.w   #3,d0
        lsr.w   #8,d1
        andi.w  #$03e0,d0
        andi.w  #$001f,d1
        or.w    d1,d0
        move.b  (a1,d0.w),d2
        add.l   d4,d6
        add.l   d5,d7
        move.b  d2,(a0)+
        move.b  d2,(a2)+

        move.w  d7,d0
        move.w  d6,d1
        lsr.w   #3,d0
        lsr.w   #8,d1
        andi.w  #$03e0,d0
        andi.w  #$001f,d1
        or.w    d1,d0
        move.b  (a1,d0.w),d2
        add.l   d4,d6
        add.l   d5,d7
        move.b  d2,(a0)+
        move.b  d2,(a2)+

        dbf     d3,.loop_c2

.tail_c2:
        btst    #0,67(sp)
        beq.s   .done_c2

        move.w  d7,d0
        move.w  d6,d1
        lsr.w   #3,d0
        lsr.w   #8,d1
        andi.w  #$03e0,d0
        andi.w  #$001f,d1
        or.w    d1,d0
        move.b  (a1,d0.w),d2
        move.b  d2,(a0)+
        move.b  d2,(a2)+

.done_c2:
        movem.l (sp)+,d2-d7/a2-a3
        rts
