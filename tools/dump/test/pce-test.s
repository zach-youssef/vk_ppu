; A small PC Engine test ROM for tools/dump/mesen-dump.lua (assemble with ca65, built by check.sh).
;
; A 256x224 screen, from VDC scanline 28 to 251, whose per-scanline register changes the dump
; must capture:
; - The background (64x64 BAT) is a checkerboard of two tiles, rows alternating palettes 0 and 1.
; - Sprites 0-2 (16x16, 32x32 and a flipped 16x16), copied from a SAT at VRAM $7F00 every frame.
; - A frame counter c, incremented by the vertical-blank interrupt, which sets BXR = BYR = c.
;   So every frame's picture differs, and the dump's screenshot, registers and memory must all
;   come from the same frame.
; - At the start of vertical blank (scanline 252, before Mesen's frame ends at 256), the same
;   interrupt writes c to VRAM word $7002 (both bytes): an upload for the next frame, which must
;   not give a memory-changed warning.
; - Late in vertical blank (about scanline 20: after Mesen's frame has started and after the
;   first sampled line, 14, but before the first displayed line, 28), it writes c to VRAM word
;   $7000 (both bytes) and to colour 100, which the dump must hold.
; - A raster (RCR) interrupt at display line 100 writes BXR = c + 12 and BYR = 0, so the lines
;   below it scroll left and restart at background row 1. It also writes c to VRAM word $7001
;   (both bytes), so the dump warns that 2 bytes changed during the frame.
; - Every dumped register holds a distinctive value (see check.py).
; Nothing here is copied from a commercial ROM.

.setcpu "huc6280"
.smart

VDC_STATUS = $0000
VDC_DATA_L = $0002
VDC_DATA_H = $0003
VCE_CTRL   = $0400
VCE_ADDR_L = $0402
VCE_ADDR_H = $0403
VCE_DATA_L = $0404
VCE_DATA_H = $0405
IRQ_DISABLE = $1402
IRQ_STATUS  = $1403

RCR_LINE = 100
counter = $2010           ; the frame counter c

.macro vreg r, value
	st0 #r
	st1 #<(value)
	st2 #>(value)
.endmacro

.segment "CODE"

reset:
	sei
	csh                   ; 7.16 MHz
	cld
	ldx #$FF
	txs
	lda #$FF
	tam #$01              ; MPR0 = I/O
	lda #$F8
	tam #$02              ; MPR1 = RAM ($2000-$3FFF)
	lda #$05
	sta IRQ_DISABLE       ; only IRQ1 (VDC)
	stz IRQ_STATUS

	vreg $05, $0000       ; CR: display off while loading
	; MWR: CG mode 1 (only used in VRAM access mode 3), 64x64 BAT, sprite access mode 2,
	; VRAM access mode 1.
	vreg $09, $00D9
	vreg $0A, $0202       ; HSR
	vreg $0B, $031F       ; HDR: 32 tiles (256 pixels)
	vreg $0C, $1A02       ; VPR: the display starts at scanline 28
	vreg $0D, $00DF       ; VDW: 224 lines
	vreg $0E, $0003       ; VCR
	vreg $0F, $0010       ; DCR: repeat the SATB transfer every frame
	vreg $07, $0000       ; BXR
	vreg $08, $0000       ; BYR

	lda #$84
	sta VCE_CTRL          ; 5.37 MHz dot clock (256 pixels), 263 lines, grayscale
	stz counter

	; Clear all of VRAM (32K words) and all 512 colours, so the dump doesn't depend on the
	; emulator's power-on state.
	vreg $00, $0000       ; MAWR
	st0 #$02
	ldy #128
@vclr_outer:
	ldx #$00
@vclr:
	st1 #$00
	st2 #$00
	dex
	bne @vclr
	dey
	bne @vclr_outer
	stz VCE_ADDR_L
	stz VCE_ADDR_H
	ldy #2
@pclr_outer:
	ldx #$00
@pclr:
	stz VCE_DATA_L
	stz VCE_DATA_H
	dex
	bne @pclr
	dey
	bne @pclr_outer

	; Palettes: background 0 and 1, sprite palette 0 (colour 256).
	stz VCE_ADDR_L
	stz VCE_ADDR_H
	ldx #$00
@pal:
	lda palette, x
	sta VCE_DATA_L
	inx
	lda palette, x
	sta VCE_DATA_H
	inx
	cpx #palette_end - palette
	bne @pal
	stz VCE_ADDR_L
	lda #$01
	sta VCE_ADDR_H        ; colour 256
	ldx #$00
@spal:
	lda sprite_palette, x
	sta VCE_DATA_L
	inx
	lda sprite_palette, x
	sta VCE_DATA_H
	inx
	cpx #sprite_palette_end - sprite_palette
	bne @spal

	; BAT (64x64) at VRAM $0000: tile $100 or $101, palette 1 on odd rows.
	vreg $00, $0000       ; MAWR
	st0 #$02
	ldy #$00              ; row
@batrow:
	ldx #$00              ; column
@batcol:
	txa
	sta $2000
	tya
	eor $2000
	and #$01              ; checkerboard bit
	sta a:VDC_DATA_L        ; tile low byte: $00 or $01
	tya
	and #$01
	asl
	asl
	asl
	asl                   ; palette 1 on odd rows
	ora #$01              ; tile index high bits: $1xx
	sta a:VDC_DATA_H
	inx
	cpx #64
	bne @batcol
	iny
	cpy #64
	bne @batrow

	; Tiles $100 (colour 1) and $101 (colour 2) at VRAM $1000.
	vreg $00, $1000
	st0 #$02
	ldx #$00
@tile:
	lda tiles, x
	sta a:VDC_DATA_L
	inx
	lda tiles, x
	sta a:VDC_DATA_H
	inx
	cpx #tiles_end - tiles
	bne @tile

	; Sprite patterns at VRAM $2000 (pattern $100): 64 words each, plane 0 all set, then a
	; second pattern with plane 1 set.
	vreg $00, $2000
	st0 #$02
	ldx #$00
@spr0:
	st1 #$FF
	st2 #$FF              ; plane 0
	inx
	cpx #16
	bne @spr0
	ldx #$00
@spr0b:
	st1 #$00
	st2 #$00              ; planes 1-3
	inx
	cpx #48
	bne @spr0b
	ldx #$00
@spr1a:
	st1 #$00
	st2 #$00
	inx
	cpx #16
	bne @spr1a
	ldx #$00
@spr1b:
	st1 #$FF
	st2 #$FF              ; plane 1
	inx
	cpx #16
	bne @spr1b
	ldx #$00
@spr1c:
	st1 #$00
	st2 #$00
	inx
	cpx #32
	bne @spr1c

	; SAT at VRAM $7F00: sprites 0-2, the rest off screen (y = 0).
	vreg $00, $7F00
	st0 #$02
	ldx #$00
@sat:
	lda sat, x
	sta a:VDC_DATA_L
	inx
	lda sat, x
	sta a:VDC_DATA_H
	inx
	cpx #sat_end - sat
	bne @sat
	ldy #61 * 4
@satclr:
	st1 #$00
	st2 #$00
	dey
	bne @satclr
	vreg $13, $7F00       ; DVSSR: SATB source

	vreg $06, (RCR_LINE + 64) ; RCR
	; CR: background, sprites, all four interrupts (no sprites collide or overflow), EX = 1 and
	; a VRAM address increment of 64 (the interrupts write one word at a time).
	vreg $05, $10DF
	cli
@forever:
	bra @forever

irq1:
	pha
	lda a:VDC_STATUS      ; acknowledge (absolute: zero page is $2000 on the HuC6280)
	sta $2011
	and #$04              ; raster compare?
	beq @not_raster
	st0 #$07              ; BXR = c + 12
	lda counter
	clc
	adc #12
	sta a:VDC_DATA_L
	lda #$00
	adc #$00
	sta a:VDC_DATA_H
	vreg $08, 0           ; BYR: restart at row 1 of the background on the next line
	vreg $00, $7001       ; VRAM $7001 = c, both bytes
	st0 #$02
	lda counter
	sta a:VDC_DATA_L
	sta a:VDC_DATA_H
@not_raster:
	lda $2011
	and #$20              ; vertical blank?
	beq @done
	inc counter
	st0 #$07              ; BXR = c
	lda counter
	sta a:VDC_DATA_L
	st2 #$00
	st0 #$08              ; BYR = c
	sta a:VDC_DATA_L
	st2 #$00
	vreg $00, $7002       ; VRAM $7002 = c, both bytes
	st0 #$02
	lda counter
	sta a:VDC_DATA_L
	sta a:VDC_DATA_H
	; Wait about 31 lines (each pass of the outer loop is about 3.1), from scanline 252 to about
	; 20 of the next frame, then write memory that its first displayed line must already see.
	; With Mesen 2.1.1, 8 to 11 passes land between the first sampled line (14) and the first
	; displayed line (28).
	phx
	phy
	ldy #10
@wait_outer:
	ldx #$00
@wait:
	dex
	bne @wait
	dey
	bne @wait_outer
	ply
	plx
	vreg $00, $7000       ; VRAM $7000 = c, both bytes
	st0 #$02
	lda counter
	sta a:VDC_DATA_L
	sta a:VDC_DATA_H
	lda #100              ; colour 100 = c
	sta VCE_ADDR_L
	stz VCE_ADDR_H
	lda counter
	sta VCE_DATA_L
	stz VCE_DATA_H
@done:
	st0 #$02              ; leave the register select on VRAM data
	pla
	rti

empty:
	rti

palette:                  ; GRB333: green << 6 | red << 3 | blue
	.word $0000, $0038, $01C0, $0007   ; palette 0: black, red, green, blue
	.res 24, 0
	.word $0000, $01FF, $00B8, $0092   ; palette 1: black, white, brownish, grey
palette_end:
sprite_palette:
	.word $0000, $003F, $01F8, $01C7   ; magenta, yellow, cyan
sprite_palette_end:

tiles:
	.repeat 8
	.byte $FF, $00                     ; tile $100: plane 0 (colour 1)
	.endrepeat
	.repeat 8
	.byte $00, $00
	.endrepeat
	.repeat 8
	.byte $00, $FF                     ; tile $101: plane 1 (colour 2)
	.endrepeat
	.repeat 8
	.byte $00, $00
	.endrepeat
tiles_end:

sat:                                   ; y + 64, x + 32, pattern (VRAM address >> 5), attributes
	.word 64 + 40, 32 + 40, $100, $0080             ; 16x16, in front of the background
	.word 64 + 60, 32 + 120, $102, $1180            ; 32x32 (CGX = 1, CGY = 1), pattern $102
	.word 64 + 150, 32 + 200, $100, $0880           ; 16x16, x-flipped
sat_end:

.segment "VECTORS"
	.word empty, irq1, empty, empty, reset         ; IRQ2, IRQ1, timer, NMI, reset
