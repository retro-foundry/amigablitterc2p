        section code,code
        xdef    _render_chunky_span_asm
        xdef    _render_chunky_span_copy2_asm

; void render_chunky_span_asm(
;     UBYTE *dst,         4(sp)
;     const UBYTE *tex,   8(sp)
;     LONG u,            12(sp)
;     LONG v,            16(sp)
;     LONG du2,          20(sp)
;     LONG dv2,          24(sp)
;     LONG count         28(sp)
; );
_render_chunky_span_asm:
        movem.l d2-d7/a2,-(sp)

        movea.l 32(sp),a0
        movea.l 36(sp),a1
        move.l  40(sp),d6
        move.l  44(sp),d7
        move.l  48(sp),d4
        move.l  52(sp),d5

        move.w  58(sp),d3
        lsr.w   #1,d3
        subq.w  #1,d3
        bmi.s   .done

.loop
        move.w  d7,d0
        lsr.w   #3,d0
        andi.w  #$03e0,d0
        move.w  d6,d1
        lsr.w   #8,d1
        andi.w  #$001f,d1
        or.w    d1,d0
        move.b  (a1,d0.w),(a0)+
        add.l   d4,d6
        add.l   d5,d7

        move.w  d7,d0
        lsr.w   #3,d0
        andi.w  #$03e0,d0
        move.w  d6,d1
        lsr.w   #8,d1
        andi.w  #$001f,d1
        or.w    d1,d0
        move.b  (a1,d0.w),(a0)+
        add.l   d4,d6
        add.l   d5,d7

        dbf     d3,.loop

.done
        movem.l (sp)+,d2-d7/a2
        rts

; void render_chunky_span_copy2_asm(
;     UBYTE *row0,         4(sp)
;     UBYTE *row1,         8(sp)
;     const UBYTE *tex,   12(sp)
;     LONG u,             16(sp)
;     LONG v,             20(sp)
;     LONG du2,           24(sp)
;     LONG dv2,           28(sp)
;     LONG count          32(sp)
; );
_render_chunky_span_copy2_asm:
        moveq   #0,d0
        move.l  sp,d1
        btst    #0,d1
        beq.s   .sp_aligned
        subq.l  #1,sp
        moveq   #1,d0
.sp_aligned
        move.l  d0,-(sp)
        movem.l d2-d7/a2-a3,-(sp)

        movea.l 40(sp),a0
        movea.l 44(sp),a2
        movea.l 48(sp),a1
        movea.l a0,a3
        move.l  52(sp),d6
        move.l  56(sp),d7
        move.l  60(sp),d4
        move.l  64(sp),d5

        move.w  70(sp),d3
        lsr.w   #1,d3
        subq.w  #1,d3
        bmi.s   .copy_only

.loop2
        move.w  d7,d0
        lsr.w   #3,d0
        andi.w  #$03e0,d0
        move.w  d6,d1
        lsr.w   #8,d1
        andi.w  #$001f,d1
        or.w    d1,d0
        move.b  (a1,d0.w),(a0)+
        add.l   d4,d6
        add.l   d5,d7

        move.w  d7,d0
        lsr.w   #3,d0
        andi.w  #$03e0,d0
        move.w  d6,d1
        lsr.w   #8,d1
        andi.w  #$001f,d1
        or.w    d1,d0
        move.b  (a1,d0.w),(a0)+
        add.l   d4,d6
        add.l   d5,d7

        dbf     d3,.loop2

.copy_only
        move.w  70(sp),d2

        move.l  a3,d0
        btst    #0,d0
        bne.s   .copy_bytes
        move.l  a2,d0
        btst    #0,d0
        bne.s   .copy_bytes

        lsr.w   #2,d2
        subq.w  #1,d2
        bmi.s   .done2

.copy_loop
        move.l  (a3)+,(a2)+
        dbf     d2,.copy_loop
        bra.s   .done2

.copy_bytes
        subq.w  #1,d2
        bmi.s   .done2

.copy_bloop
        move.b  (a3)+,(a2)+
        dbf     d2,.copy_bloop

.done2
        movem.l (sp)+,d2-d7/a2-a3
        move.l  (sp)+,d0
        tst.l   d0
        beq.s   .ret2
        addq.l  #1,sp
.ret2
        rts
