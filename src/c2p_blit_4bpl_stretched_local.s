        section c2p,code

; =====================================================================
; Amiga 500 (OCS) Blitter-assisted Chunky-to-Planar (C2P) routine
;  - 68000 assembly
;  - 4 bitplanes (16 colours)
;  - 2x1 horizontal expansion: 160-wide chunky -> 320-wide planar
;  - Input pixels are 8-bit "stretched": %aabbccdd (00/11 pairs)
; =====================================================================

                ; -----------------------------
                ; Compile-time configuration
                ; -----------------------------
CHUNKY_W        EQU     160             ; pixels/bytes per chunky line (must be multiple of 16)
CHUNKY_H        EQU     160             ; visible chunky lines converted
HORIZON_Y       EQU     96              ; destination Y offset on screen
SCREEN_H        EQU     256

OUT_W           EQU     (CHUNKY_W*2)     ; 320 pixels
PLANE_BPR       EQU     (OUT_W/8)        ; bytes per row per plane (40 bytes for 320)
BPL_SIZE        EQU     (PLANE_BPR*SCREEN_H)
CHUNKY_SIZE     EQU     (CHUNKY_W*CHUNKY_H)

; Intermediate buffers: 160 bytes/line -> 80 bytes/line
RES_BPR         EQU     (CHUNKY_W/2)     ; 80 bytes per row
RES_SIZE        EQU     (RES_BPR*CHUNKY_H)

; Linear blit "row counts" for width=1 word tricks:
; Pass AB/CD outputs one WORD per 4 chunky bytes => (CHUNKY_SIZE/4) rows
PASS_WORDS      EQU     (CHUNKY_SIZE/4)

; Final plane write outputs one WORD per 2 res-bytes-pairs => (CHUNKY_H * (CHUNKY_W/8)) words
PLANE_WORDS     EQU     (CHUNKY_H*(CHUNKY_W/8))

; Width in words for the rectangle merge step (res0->res1):
MERGE_WWORDS    EQU     (RES_BPR/2)      ; 80 bytes / 2 = 40 words

; Maximum BLTSIZE height is 1024 rows (0 encodes 1024). We pick 1000 to avoid 0 special-case.
SEG_H           EQU     1000

                ; -----------------------------
                ; Custom register base + offsets (OCS)
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

BLTCMOD         EQU     $060
BLTBMOD         EQU     $062
BLTAMOD         EQU     $064
BLTDMOD         EQU     $066

BLTCDAT         EQU     $070

                ; -----------------------------
                ; DMACON bits (write)
                ; -----------------------------
DMAF_SETCLR     EQU     $8000
DMAF_BLTPRI     EQU     $0400           ; BLTPRI ("blitter nasty")

                ; -----------------------------
                ; BLTCON constants used here
                ; -----------------------------
; LF = 0xE4 => D = (A & C) | (B & ~C)  (C used as constant mask, C DMA not enabled)
BLT_LF_E4       EQU     $00E4

; Channel enables in BLTCON0:
BLT_USEA        EQU     $0800
BLT_USEB        EQU     $0400
BLT_USED        EQU     $0100

; Base BLTCON0 value for A+B+D and LF=E4:
BLT0_ABD_E4     EQU     (BLT_USEA|BLT_USEB|BLT_USED|BLT_LF_E4)  ; = $0DE4

; A-shift values go in bits 15..12 of BLTCON0
ASHIFT_2        EQU     $2000
ASHIFT_4        EQU     $4000

; B-shift values go in bits 15..12 of BLTCON1
BSHIFT_4        EQU     $4000
BSHIFT_6        EQU     $6000
BSHIFT_8        EQU     $8000

; Descending (reverse) mode bit in BLTCON1 (area mode)
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
        bsr     WaitBlitOCS
        movea.l (sp)+,a6
        rts

; void *c2p_blit_4bpl_stageptr_c(void);
;   Returns CHIP staging pointer for stretched chunky pixels.
_c2p_blit_4bpl_stageptr_c:
        move.l  #stretchedChunky,d0
        rts

; void c2p_blit_4bpl_c(void *chunky, void *screenBase);
;   chunky is stretched chunky (%aabbccdd) in CHIP memory.
;   screenBase is plane0 base for an interleaved planar block (4 planes used).
_c2p_blit_4bpl_c:
        movem.l d2-d7/a2-a6,-(sp)

        movea.l 48(sp),a0
        movea.l 52(sp),a5
        lea     (HORIZON_Y*PLANE_BPR)(a5),a1
        movea.l a1,a2
        adda.l  #BPL_SIZE,a2
        movea.l a2,a3
        adda.l  #BPL_SIZE,a3
        movea.l a3,a4
        adda.l  #BPL_SIZE,a4

        bsr     C2P_2x1_4bpl_Stretched_OCS

        movem.l (sp)+,d2-d7/a2-a6
        rts

; ---------------------------------------------------------------------
; WaitBlitOCS
;   a6 = CUSTOM base ($DFF000)
;   Waits until blitter is not busy.
;   Includes the classic "double test" safety pattern for early chips.
; ---------------------------------------------------------------------
WaitBlitOCS:
        btst.b  #6,DMACONR(a6)         ; first read may be unreliable on early OCS
.wb_loop:
        btst.b  #6,DMACONR(a6)         ; bit14 == bit6 of high byte
        bne.s   .wb_loop
        rts

; ---------------------------------------------------------------------
; C2P_2x1_4bpl_Stretched_OCS
;   Blitter-assisted C2P producing 4 bitplanes from stretched chunky.
;
;   Inputs:
;     a0 = src stretched chunky (%aabbccdd), size CHUNKY_W*CHUNKY_H
;     a1 = dst plane0 (LSB)
;     a2 = dst plane1
;     a3 = dst plane2
;     a4 = dst plane3 (MSB)
;
;   Uses static CHIP buffers:
;     res0, res1, resCD
; ---------------------------------------------------------------------
C2P_2x1_4bpl_Stretched_OCS:
        lea     CUSTOM,a6

        ; Optionally enable BLTPRI ("blitter nasty") during conversion.
        move.w  #(DMAF_SETCLR|DMAF_BLTPRI),DMACON(a6)

        bsr     WaitBlitOCS

        ; Set first/last word masks for A to all 1s (no edge masking).
        move.l  #$FFFFFFFF,BLTAFWM(a6)

        ; -------------------------
        ; Prepass AB: src -> res0
        ; mask C = $F0F0, B-shift=4
        ; -------------------------
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
        move.w  #$F0F0,BLTCDAT(a6)     ; C constant mask

        ; Linear blit: width=1 word, height=PASS_WORDS split into <=SEG_H chunks
        move.w  #PASS_WORDS,d7
.ab_seg:
        move.w  #SEG_H,d0
        cmp.w   d0,d7
        bgt.s   .ab_do
        move.w  d7,d0
.ab_do:
        bsr     WaitBlitOCS
        move.w  d0,d1
        lsl.w   #6,d1
        ori.w   #1,d1                  ; width=1 word
        move.w  d1,BLTSIZE(a6)         ; START
        sub.w   d0,d7
        bne.s   .ab_seg
        bsr     WaitBlitOCS

        ; -------------------------
        ; Plane 3 from res0
        ; -------------------------
        bsr     MakePlaneFromRes0_Plane3

        ; -------------------------
        ; Plane 2 from res0
        ; -------------------------
        bsr     MakePlaneFromRes0_Plane2

        ; -------------------------
        ; Prepass CD: src -> resCD (descending, Ashift=4, mask C=$F0F0)
        ; -------------------------
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

        move.w  #PASS_WORDS,d7
.cd_seg:
        move.w  #SEG_H,d0
        cmp.w   d0,d7
        bgt.s   .cd_do
        move.w  d7,d0
.cd_do:
        bsr     WaitBlitOCS
        move.w  d0,d1
        lsl.w   #6,d1
        ori.w   #1,d1
        move.w  d1,BLTSIZE(a6)
        sub.w   d0,d7
        bne.s   .cd_seg
        bsr     WaitBlitOCS

        ; -------------------------
        ; Plane 1 from resCD
        ; -------------------------
        bsr     MakePlaneFromResCD_Plane1

        ; -------------------------
        ; Plane 0 from resCD
        ; -------------------------
        bsr     MakePlaneFromResCD_Plane0

        ; Clear BLTPRI again (cooperative mode)
        move.w  #DMAF_BLTPRI,DMACON(a6)

        rts

; ---------------------------------------------------------------------
; Helper: merge + write plane3 using res0 -> res1 -> a4
; ---------------------------------------------------------------------
MakePlaneFromRes0_Plane3:
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

        bsr     WaitBlitOCS
        move.w  #((CHUNKY_H<<6)|MERGE_WWORDS),BLTSIZE(a6)
        bsr     WaitBlitOCS

        ; write res1 to plane3 (a4) as linear words
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

        move.w  #PLANE_WORDS,d7
.p3_seg:
        move.w  #SEG_H,d0
        cmp.w   d0,d7
        bgt.s   .p3_do
        move.w  d7,d0
.p3_do:
        bsr     WaitBlitOCS
        move.w  d0,d1
        lsl.w   #6,d1
        ori.w   #1,d1
        move.w  d1,BLTSIZE(a6)
        sub.w   d0,d7
        bne.s   .p3_seg
        bsr     WaitBlitOCS
        rts

; ---------------------------------------------------------------------
; Helper: merge + write plane2 using res0 -> res1 -> a3
; ---------------------------------------------------------------------
MakePlaneFromRes0_Plane2:
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

        bsr     WaitBlitOCS
        move.w  #((CHUNKY_H<<6)|MERGE_WWORDS),BLTSIZE(a6)
        bsr     WaitBlitOCS

        ; write res1 to plane2 (a3)
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

        move.w  #PLANE_WORDS,d7
.p2_seg:
        move.w  #SEG_H,d0
        cmp.w   d0,d7
        bgt.s   .p2_do
        move.w  d7,d0
.p2_do:
        bsr     WaitBlitOCS
        move.w  d0,d1
        lsl.w   #6,d1
        ori.w   #1,d1
        move.w  d1,BLTSIZE(a6)
        sub.w   d0,d7
        bne.s   .p2_seg
        bsr     WaitBlitOCS
        rts

; ---------------------------------------------------------------------
; Helper: merge + write plane1 using resCD -> res1 -> a2
; ---------------------------------------------------------------------
MakePlaneFromResCD_Plane1:
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

        bsr     WaitBlitOCS
        move.w  #((CHUNKY_H<<6)|MERGE_WWORDS),BLTSIZE(a6)
        bsr     WaitBlitOCS

        ; write res1 to plane1 (a2)
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

        move.w  #PLANE_WORDS,d7
.p1_seg:
        move.w  #SEG_H,d0
        cmp.w   d0,d7
        bgt.s   .p1_do
        move.w  d7,d0
.p1_do:
        bsr     WaitBlitOCS
        move.w  d0,d1
        lsl.w   #6,d1
        ori.w   #1,d1
        move.w  d1,BLTSIZE(a6)
        sub.w   d0,d7
        bne.s   .p1_seg
        bsr     WaitBlitOCS
        rts

; ---------------------------------------------------------------------
; Helper: merge + write plane0 using resCD -> res1 -> a1
; ---------------------------------------------------------------------
MakePlaneFromResCD_Plane0:
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

        bsr     WaitBlitOCS
        move.w  #((CHUNKY_H<<6)|MERGE_WWORDS),BLTSIZE(a6)
        bsr     WaitBlitOCS

        ; write res1 to plane0 (a1)
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

        move.w  #PLANE_WORDS,d7
.p0_seg:
        move.w  #SEG_H,d0
        cmp.w   d0,d7
        bgt.s   .p0_do
        move.w  d7,d0
.p0_do:
        bsr     WaitBlitOCS
        move.w  d0,d1
        lsl.w   #6,d1
        ori.w   #1,d1
        move.w  d1,BLTSIZE(a6)
        sub.w   d0,d7
        bne.s   .p0_seg
        bsr     WaitBlitOCS
        rts

        section bss_c,bss_c
        even
stretchedChunky:
        ds.b    CHUNKY_SIZE
res0:
        ds.b    RES_SIZE
res1:
        ds.b    RES_SIZE
resCD:
        ds.b    RES_SIZE
        even
