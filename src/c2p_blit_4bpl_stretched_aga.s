        section c2p,code

; =====================================================================
; AGA-optimized blitter-assisted Chunky-to-Planar (C2P) routine
;  - 4 bitplanes (16 colours)
;  - 2x2 mode: 160-wide chunky -> 320-wide planar (2× horizontal)
;  - Input pixels are 8-bit "stretched": %aabbccdd (00/11 pairs)
;  - Uses AGA BLTSIZV/BLTSIZH for single-pass long linear blits
;
; 10-blit blitter-only design
; ─────────────────────────────
; CPU-based plane packing (6-blit hybrid) was tried and is slower on
; chip-RAM-only A1200: the 68020 competes with active bitplane DMA on
; every chip RAM access (~280 ns/access stalled), while the blitter
; bursts the same data at ~140 ns/word.  10 blitter-only blits win.
;
; · Double-BTST WaitBlit (fat Agnus / Alice errata, HRM §6.2).
; · All four per-plane helpers inlined (no BSR/RTS overhead).
; · BSS buffers longword-aligned (cnop 0,4).
; =====================================================================

                ; -----------------------------
                ; Compile-time configuration
                ; -----------------------------
CHUNKY_W        EQU     160             ; pixels/bytes per chunky line
CHUNKY_H        EQU     160             ; visible chunky lines converted
HORIZON_Y       EQU     96              ; destination Y offset on screen
SCREEN_H        EQU     256

OUT_W           EQU     (CHUNKY_W*2)     ; 320 pixels
PLANE_BPR       EQU     (OUT_W/8)        ; 40 bytes per row per plane
BPL_SIZE        EQU     (PLANE_BPR*SCREEN_H)
CHUNKY_SIZE     EQU     (CHUNKY_W*CHUNKY_H)

; Intermediate buffers: 160 bytes/line -> 80 bytes/line
RES_BPR         EQU     (CHUNKY_W/2)     ; 80 bytes per row
RES_SIZE        EQU     (RES_BPR*CHUNKY_H)

; Linear blit row count for 1-word-wide passes (prepass AB / CD)
PASS_WORDS      EQU     (CHUNKY_SIZE/4)

; Linear blit row count for the plane-write passes
PLANE_WORDS     EQU     (CHUNKY_H*(CHUNKY_W/8))   ; 160 × 20 = 3200

; Width in words for the rectangle merge step (res0 / resCD -> res1)
MERGE_WWORDS    EQU     (RES_BPR/2)      ; 40 words

                ; -----------------------------
                ; Custom register base + offsets
                ; -----------------------------
CUSTOM          EQU     $DFF000

DMACONR         EQU     $002
DMACON          EQU     $096

BLTCON0         EQU     $040
BLTCON1         EQU     $042
BLTAFWM         EQU     $044
BLTALWM         EQU     $046
BLTBPTH         EQU     $04C
BLTAPTH         EQU     $050
BLTDPTH         EQU     $054
BLTSIZE         EQU     $058
BLTSIZV         EQU     $05C            ; AGA/ECS extended vertical size
BLTSIZH         EQU     $05E            ; AGA/ECS horizontal size + start

BLTCMOD         EQU     $060
BLTBMOD         EQU     $062
BLTAMOD         EQU     $064
BLTDMOD         EQU     $066

BLTCDAT         EQU     $070

                ; -----------------------------
                ; DMACON bits (write)
                ; -----------------------------
DMAF_SETCLR     EQU     $8000
DMAF_BLTPRI     EQU     $0400           ; blitter priority ("nasty")

                ; -----------------------------
                ; BLTCON constants
                ; -----------------------------
; LF = $E4 => D = (A & C) | (B & ~C)  (C is the constant mask in BLTCDAT)
BLT_LF_E4       EQU     $00E4

BLT_USEA        EQU     $0800
BLT_USEB        EQU     $0400
BLT_USED        EQU     $0100

; Base BLTCON0: A+B+D enabled, LF=$E4, no A-shift by default
BLT0_ABD_E4     EQU     (BLT_USEA|BLT_USEB|BLT_USED|BLT_LF_E4)  ; $0DE4

; A-shift (bits 15:12 of BLTCON0)
ASHIFT_2        EQU     $2000
ASHIFT_4        EQU     $4000

; B-shift (bits 15:12 of BLTCON1)
BSHIFT_4        EQU     $4000
BSHIFT_6        EQU     $6000
BSHIFT_8        EQU     $8000

; Descending mode (bit 1 of BLTCON1, area mode)
BLT_DESC        EQU     $0002

        xdef    _c2p_blit_4bpl_init_c
        xdef    _c2p_blit_4bpl_c
        xdef    _c2p_blit_4bpl_waitblit_c
        xdef    _c2p_blit_4bpl_stageptr_c

; void c2p_blit_4bpl_init_c(void);
_c2p_blit_4bpl_init_c:
        rts

; void c2p_blit_4bpl_waitblit_c(void);
_c2p_blit_4bpl_waitblit_c:
        move.l  a6,-(sp)
        lea     CUSTOM,a6
        bsr     WaitBlitAGA
        movea.l (sp)+,a6
        rts

; void *c2p_blit_4bpl_stageptr_c(void);
_c2p_blit_4bpl_stageptr_c:
        move.l  #stretchedChunky,d0
        rts

; void c2p_blit_4bpl_c(void *chunky, void *screenBase);
_c2p_blit_4bpl_c:
        movem.l d2-d7/a2-a6,-(sp)

        movea.l 48(sp),a0               ; chunky source
        movea.l 52(sp),a5               ; screen base

        lea     (HORIZON_Y*PLANE_BPR)(a5),a1   ; plane0 (LSB)
        movea.l a1,a2
        adda.l  #BPL_SIZE,a2            ; plane1
        movea.l a2,a3
        adda.l  #BPL_SIZE,a3            ; plane2
        movea.l a3,a4
        adda.l  #BPL_SIZE,a4            ; plane3 (MSB)

        bsr     C2P_AGA_Core

        movem.l (sp)+,d2-d7/a2-a6
        rts

; =====================================================================
; WaitBlitAGA — double-BTST idiom (fat Agnus / Alice errata)
;
; Alice asserts BLTDONE in DMACONR immediately when BLTSIZE is written,
; but the bit may appear clear on the very first read after the write
; due to bus pipeline latency.  Reading DMACONR once before the spin
; loop flushes this stale state so the subsequent reads are reliable.
; =====================================================================
WaitBlitAGA:
        btst.b  #6,DMACONR(a6)          ; dummy read — flush stale pipeline
.wba_loop:
        btst.b  #6,DMACONR(a6)          ; reliable busy check
        bne.s   .wba_loop
        rts

; =====================================================================
; C2P_AGA_Core — 10-blit blitter-only
;
; Register allocation:
;   a0 = chunky src, a1-a4 = plane0-3, a5 = scratch, a6 = CUSTOM
; =====================================================================
C2P_AGA_Core:
        lea     CUSTOM,a6

        move.w  #(DMAF_SETCLR|DMAF_BLTPRI),DMACON(a6)

        bsr     WaitBlitAGA

        move.l  #$FFFFFFFF,BLTAFWM(a6)

; =====================================================================
; Blit 1 — Prepass AB: src → res0
;   B-shift=4, C=$F0F0; separates the "ab" nibble pairs.
;   Linear (1-word-wide), PASS_WORDS rows.
; =====================================================================
        move.l  a0,BLTAPTH(a6)
        lea     2(a0),a5
        move.l  a5,BLTBPTH(a6)
        lea     res0,a5
        move.l  a5,BLTDPTH(a6)

        move.w  #2,BLTAMOD(a6)
        move.w  #2,BLTBMOD(a6)
        move.w  #0,BLTDMOD(a6)

        move.w  #(BLT0_ABD_E4),BLTCON0(a6)
        move.w  #(BSHIFT_4),BLTCON1(a6)
        move.w  #$F0F0,BLTCDAT(a6)

        bsr     WaitBlitAGA
        move.w  #PASS_WORDS,BLTSIZV(a6)
        move.w  #1,BLTSIZH(a6)

; =====================================================================
; Blit 2 — Merge plane3: res0 → res1
;   B-shift=6, C=$CCCC, descending; isolates plane3 bits in high byte.
;   Rect blit: CHUNKY_H rows × MERGE_WWORDS words.
; =====================================================================
        bsr     WaitBlitAGA

        lea     res0,a5
        lea     (RES_SIZE-2)(a5),a5
        move.l  a5,BLTAPTH(a6)
        move.l  a5,BLTBPTH(a6)
        lea     res1,a5
        lea     (RES_SIZE-2)(a5),a5
        move.l  a5,BLTDPTH(a6)

        move.w  #0,BLTAMOD(a6)
        move.w  #0,BLTBMOD(a6)
        move.w  #0,BLTDMOD(a6)

        move.w  #(BLT0_ABD_E4),BLTCON0(a6)
        move.w  #(BSHIFT_6|BLT_DESC),BLTCON1(a6)
        move.w  #$CCCC,BLTCDAT(a6)

        bsr     WaitBlitAGA
        move.w  #CHUNKY_H,BLTSIZV(a6)
        move.w  #MERGE_WWORDS,BLTSIZH(a6)

; =====================================================================
; Blit 3 — Write plane3: res1 → a4 (plane3)
;   B-shift=8, C=$FF00; packs pairs of words from res1 into plane words.
;   Linear (1-word-wide), PLANE_WORDS rows, BLTAMOD=BLTBMOD=2 (stride 4).
; =====================================================================
        bsr     WaitBlitAGA

        lea     res1,a5
        move.l  a5,BLTAPTH(a6)
        lea     2(a5),a5
        move.l  a5,BLTBPTH(a6)
        move.l  a4,BLTDPTH(a6)

        move.w  #2,BLTAMOD(a6)
        move.w  #2,BLTBMOD(a6)
        move.w  #0,BLTDMOD(a6)

        move.w  #(BLT0_ABD_E4),BLTCON0(a6)
        move.w  #(BSHIFT_8),BLTCON1(a6)
        move.w  #$FF00,BLTCDAT(a6)

        bsr     WaitBlitAGA
        move.w  #PLANE_WORDS,BLTSIZV(a6)
        move.w  #1,BLTSIZH(a6)

; =====================================================================
; Blit 4 — Merge plane2: res0 → res1
;   A-shift=2, B-shift=8, C=$CCCC, descending; isolates plane2 bits.
; =====================================================================
        bsr     WaitBlitAGA

        lea     res0,a5
        lea     (RES_SIZE-2)(a5),a5
        move.l  a5,BLTAPTH(a6)
        move.l  a5,BLTBPTH(a6)
        lea     res1,a5
        lea     (RES_SIZE-2)(a5),a5
        move.l  a5,BLTDPTH(a6)

        move.w  #0,BLTAMOD(a6)
        move.w  #0,BLTBMOD(a6)
        move.w  #0,BLTDMOD(a6)

        move.w  #(ASHIFT_2|BLT0_ABD_E4),BLTCON0(a6)
        move.w  #(BSHIFT_8|BLT_DESC),BLTCON1(a6)
        move.w  #$CCCC,BLTCDAT(a6)

        bsr     WaitBlitAGA
        move.w  #CHUNKY_H,BLTSIZV(a6)
        move.w  #MERGE_WWORDS,BLTSIZH(a6)

; =====================================================================
; Blit 5 — Write plane2: res1 → a3 (plane2)
; =====================================================================
        bsr     WaitBlitAGA

        lea     res1,a5
        move.l  a5,BLTAPTH(a6)
        lea     2(a5),a5
        move.l  a5,BLTBPTH(a6)
        move.l  a3,BLTDPTH(a6)

        move.w  #2,BLTAMOD(a6)
        move.w  #2,BLTBMOD(a6)
        move.w  #0,BLTDMOD(a6)

        move.w  #(BLT0_ABD_E4),BLTCON0(a6)
        move.w  #(BSHIFT_8),BLTCON1(a6)
        move.w  #$FF00,BLTCDAT(a6)

        bsr     WaitBlitAGA
        move.w  #PLANE_WORDS,BLTSIZV(a6)
        move.w  #1,BLTSIZH(a6)

; =====================================================================
; Blit 6 — Prepass CD: src → resCD
;   A-shift=4, descending; separates the "cd" nibble pairs.
; =====================================================================
        bsr     WaitBlitAGA

        lea     (CHUNKY_SIZE-4)(a0),a5
        move.l  a5,BLTAPTH(a6)
        lea     2(a5),a5
        move.l  a5,BLTBPTH(a6)
        lea     resCD,a5
        lea     (RES_SIZE-2)(a5),a5
        move.l  a5,BLTDPTH(a6)

        move.w  #2,BLTAMOD(a6)
        move.w  #2,BLTBMOD(a6)
        move.w  #0,BLTDMOD(a6)

        move.w  #(ASHIFT_4|BLT0_ABD_E4),BLTCON0(a6)
        move.w  #(BLT_DESC),BLTCON1(a6)
        move.w  #$F0F0,BLTCDAT(a6)

        bsr     WaitBlitAGA
        move.w  #PASS_WORDS,BLTSIZV(a6)
        move.w  #1,BLTSIZH(a6)

; =====================================================================
; Blit 7 — Merge plane1: resCD → res1
;   B-shift=6, C=$CCCC, descending; isolates plane1 bits.
; =====================================================================
        bsr     WaitBlitAGA

        lea     resCD,a5
        lea     (RES_SIZE-2)(a5),a5
        move.l  a5,BLTAPTH(a6)
        move.l  a5,BLTBPTH(a6)
        lea     res1,a5
        lea     (RES_SIZE-2)(a5),a5
        move.l  a5,BLTDPTH(a6)

        move.w  #0,BLTAMOD(a6)
        move.w  #0,BLTBMOD(a6)
        move.w  #0,BLTDMOD(a6)

        move.w  #(BLT0_ABD_E4),BLTCON0(a6)
        move.w  #(BSHIFT_6|BLT_DESC),BLTCON1(a6)
        move.w  #$CCCC,BLTCDAT(a6)

        bsr     WaitBlitAGA
        move.w  #CHUNKY_H,BLTSIZV(a6)
        move.w  #MERGE_WWORDS,BLTSIZH(a6)

; =====================================================================
; Blit 8 — Write plane1: res1 → a2 (plane1)
; =====================================================================
        bsr     WaitBlitAGA

        lea     res1,a5
        move.l  a5,BLTAPTH(a6)
        lea     2(a5),a5
        move.l  a5,BLTBPTH(a6)
        move.l  a2,BLTDPTH(a6)

        move.w  #2,BLTAMOD(a6)
        move.w  #2,BLTBMOD(a6)
        move.w  #0,BLTDMOD(a6)

        move.w  #(BLT0_ABD_E4),BLTCON0(a6)
        move.w  #(BSHIFT_8),BLTCON1(a6)
        move.w  #$FF00,BLTCDAT(a6)

        bsr     WaitBlitAGA
        move.w  #PLANE_WORDS,BLTSIZV(a6)
        move.w  #1,BLTSIZH(a6)

; =====================================================================
; Blit 9 — Merge plane0: resCD → res1
;   A-shift=2, B-shift=8, C=$CCCC, descending; isolates plane0 bits.
; =====================================================================
        bsr     WaitBlitAGA

        lea     resCD,a5
        lea     (RES_SIZE-2)(a5),a5
        move.l  a5,BLTAPTH(a6)
        move.l  a5,BLTBPTH(a6)
        lea     res1,a5
        lea     (RES_SIZE-2)(a5),a5
        move.l  a5,BLTDPTH(a6)

        move.w  #0,BLTAMOD(a6)
        move.w  #0,BLTBMOD(a6)
        move.w  #0,BLTDMOD(a6)

        move.w  #(ASHIFT_2|BLT0_ABD_E4),BLTCON0(a6)
        move.w  #(BSHIFT_8|BLT_DESC),BLTCON1(a6)
        move.w  #$CCCC,BLTCDAT(a6)

        bsr     WaitBlitAGA
        move.w  #CHUNKY_H,BLTSIZV(a6)
        move.w  #MERGE_WWORDS,BLTSIZH(a6)

; =====================================================================
; Blit 10 — Write plane0: res1 → a1 (plane0)
; =====================================================================
        bsr     WaitBlitAGA

        lea     res1,a5
        move.l  a5,BLTAPTH(a6)
        lea     2(a5),a5
        move.l  a5,BLTBPTH(a6)
        move.l  a1,BLTDPTH(a6)

        move.w  #2,BLTAMOD(a6)
        move.w  #2,BLTBMOD(a6)
        move.w  #0,BLTDMOD(a6)

        move.w  #(BLT0_ABD_E4),BLTCON0(a6)
        move.w  #(BSHIFT_8),BLTCON1(a6)
        move.w  #$FF00,BLTCDAT(a6)

        bsr     WaitBlitAGA
        move.w  #PLANE_WORDS,BLTSIZV(a6)
        move.w  #1,BLTSIZH(a6)

        move.w  #DMAF_BLTPRI,DMACON(a6)
        rts

; =====================================================================
; BSS — CHIP memory intermediate buffers
;
; Longword-aligned (cnop 0,4) for optimal chip-bus access.
; The blitter requires word alignment; 32-bit alignment satisfies
; that requirement and also keeps the chip bus controller happy
; for any future longword accesses.
; =====================================================================
        section bss_c,bss_c

        cnop    0,4
stretchedChunky:
        ds.b    CHUNKY_SIZE             ; 25 600 bytes

        cnop    0,4
res0:
        ds.b    RES_SIZE                ; 12 800 bytes

        cnop    0,4
res1:
        ds.b    RES_SIZE                ; 12 800 bytes

        cnop    0,4
resCD:
        ds.b    RES_SIZE                ; 12 800 bytes
