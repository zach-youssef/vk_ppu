; A small SNES test ROM for tools/dump/mesen-dump.lua (assemble with ca65, built by check.sh).
;
; It sets up a Mode 1 screen whose per-scanline register changes the dump must capture:
; - BG1 (4bpp) shows a checkerboard; HDMA channel 0 writes BG1HOFS on every line (hscroll = line / 2,
;   in steps of 8 lines), so its rows shear.
; - HDMA channel 1 keeps lines 1-8 in forced blank (INIDISP = $8F) and turns the display on from
;   line 9 ($0F).
; - A frame counter c, incremented by NMI, which sets BG1VOFS = $1F00 + c (BG1 uses $300 + c, so
;   the picture moves down a line every frame). So the dump's screenshot, registers and memory
;   must all come from the same frame.
; - The NMI handler then waits until line 3 (in forced blank) and writes c to VRAM word $7000
;   (both bytes) and to colour 200 (c, then c & $7F): memory that the first displayed line must
;   already see.
; - Sprites 0-3 in OAM (8x8 and 32x32, one with the high table's x bit 9 set), though OBSEL's name
;   base points at blank tiles, so none is drawn.
; - A V-IRQ at line 112 writes TM = $01 (sprites off below it) and COLDATA, and NMI restores TM = $11.
; - Every other dumped register holds a distinctive value that doesn't change the picture (see
;   check.py): layers that aren't shown, windows that aren't used, and colour math that is
;   always prevented.
; Nothing here is copied from a commercial ROM.

.p816
.smart

INIDISP = $2100
OBSEL   = $2101
OAMADDL = $2102
OAMDATA = $2104
BGMODE  = $2105
BG1SC   = $2107
BG12NBA = $210B
BG1HOFS = $210D
BG1VOFS = $210E
VMAIN   = $2115
VMADDL  = $2116
VMDATAL = $2118
CGADD   = $2121
CGDATA  = $2122
TM      = $212C
COLDATA = $2132
NMITIMEN = $4200
VTIMEL  = $4209
HDMAEN  = $420C
RDNMI   = $4210
TIMEUP  = $4211
DMAP0   = $4300
BBAD0   = $4301
A1T0L   = $4302
A1B0    = $4304
DAS0L   = $4305
MDMAEN  = $420B
VMADDH  = $2117
WRIO    = $4201
SLHV    = $2137
OPVCT   = $213D
STAT78  = $213F
DMAP1   = $4310
BBAD1   = $4311
A1T1L   = $4312
A1B1    = $4314

counter = $10             ; the frame counter c (direct page)
vline   = $11

.segment "CODE"

reset:
	sei
	clc
	xce                   ; native mode
	rep #$38              ; 16-bit A/X/Y, binary
	ldx #$1FFF
	txs
	lda #$0000
	tcd
	sep #$20              ; 8-bit A
	.a8
	.i16
	lda #$80
	sta INIDISP           ; forced blank while loading
	stz NMITIMEN
	stz HDMAEN
	lda #$FF
	sta WRIO              ; bit 7 set: reading SLHV latches the H/V counters
	stz counter

	; Clear the PPU registers this ROM relies on.
	ldx #$2101
@clr:
	stz 0, x
	inx
	cpx #$2134
	bne @clr

	; Tiles at word $0000: tile 0 blank, tile 1 solid colour 1, tile 2 solid colour 2 (4bpp).
	lda #$80
	sta VMAIN             ; increment after the high byte
	; Clear all of VRAM and CGRAM by DMA from a zero byte, so the dump doesn't depend on the
	; emulator's power-on state.
	ldx #$0000
	stx VMADDL
	lda #$09              ; fixed source, two registers ($2118/$2119)
	sta DMAP0
	lda #<VMDATAL
	sta BBAD0
	ldx #zero
	stx A1T0L
	lda #^zero
	sta A1B0
	ldx #$0000            ; 0 = 65536 bytes
	stx DAS0L
	lda #$01
	sta MDMAEN
	stz CGADD
	lda #$08              ; fixed source, one register
	sta DMAP0
	lda #<CGDATA
	sta BBAD0
	ldx #zero
	stx A1T0L
	ldx #512
	stx DAS0L
	lda #$01
	sta MDMAEN
	ldx #$0000
	stx VMADDL
	ldx #$0000
@tile0:
	stz VMDATAL
	stz VMDATAL + 1
	inx
	cpx #16
	bne @tile0
	; tile 1: plane 0 all set
	ldx #$0000
@tile1:
	lda #$FF
	sta VMDATAL           ; plane 0
	stz VMDATAL + 1       ; plane 1
	inx
	cpx #8
	bne @tile1
	ldx #$0000
@tile1b:
	stz VMDATAL
	stz VMDATAL + 1
	inx
	cpx #8
	bne @tile1b
	; tile 2: plane 1 all set
	ldx #$0000
@tile2:
	stz VMDATAL
	lda #$FF
	sta VMDATAL + 1
	inx
	cpx #8
	bne @tile2
	ldx #$0000
@tile2b:
	stz VMDATAL
	stz VMDATAL + 1
	inx
	cpx #8
	bne @tile2b

	; BG1 tilemap at word $1000 (32x32): a checkerboard of tiles 1 and 2, palette 1 on odd rows.
	ldx #$1000
	stx VMADDL
	ldy #$0000            ; entry index
@map:
	tya
	and #$01
	sta $00
	tya
	lsr
	lsr
	lsr
	lsr
	lsr                   ; row (low bits)
	and #$01
	eor $00
	inc a                 ; tile 1 or 2
	sta VMDATAL
	tya
	lsr
	lsr
	lsr
	lsr
	lsr
	and #$01
	asl
	asl                   ; palette 1 on odd rows
	sta VMDATAL + 1
	iny
	cpy #1024
	bne @map

	; CGRAM: palette 0 and 1 for BG1, sprite palette 0 (colour 128 on).
	stz CGADD
	ldx #$0000
@pal:
	lda palette, x
	sta CGDATA
	inx
	cpx #palette_end - palette
	bne @pal
	lda #128
	sta CGADD
	ldx #$0000
@spal:
	lda sprite_palette, x
	sta CGDATA
	inx
	cpx #sprite_palette_end - sprite_palette
	bne @spal

	; OAM: every sprite off screen (y = 240), then sprites 0-3, then the high table.
	stz OAMADDL
	stz OAMADDL + 1
	ldx #$0000
@oamclr:
	stz OAMDATA           ; x
	lda #240
	sta OAMDATA           ; y
	stz OAMDATA           ; tile
	stz OAMDATA           ; attributes
	inx
	cpx #128
	bne @oamclr
	ldx #$0000
@oamhi:
	lda #$55              ; x bit 9 set for sprites 4-127, so they are off screen
	sta OAMDATA
	inx
	cpx #32
	bne @oamhi
	stz OAMADDL
	stz OAMADDL + 1
	ldx #$0000
@oam:
	lda sprites, x
	sta OAMDATA
	inx
	cpx #16
	bne @oam
	lda #$01
	sta OAMADDL + 1       ; high table (word address $100)
	stz OAMADDL
	lda #%01111000        ; sprite 0 small, 1 large, 2 large, 3 small with x bit 9
	sta OAMDATA

	; The rest of the PPU registers, from the table below.
	ldx #$0000
@regs:
	rep #$20
	.a16
	lda ppu_registers, x
	and #$00FF
	tay
	sep #$20
	.a8
	lda ppu_registers + 1, x
	sta $2100, y
	inx
	inx
	cpx #ppu_registers_end - ppu_registers
	bne @regs

	; HDMA channel 0: mode 2 (one register, written twice) to BG1HOFS.
	lda #$02
	sta DMAP0
	lda #<BG1HOFS
	sta BBAD0
	ldx #hdma_table
	stx A1T0L
	lda #^hdma_table
	sta A1B0
	; HDMA channel 1: mode 0 (one register) to INIDISP.
	stz DMAP1
	stz BBAD1
	ldx #inidisp_table
	stx A1T1L
	lda #^inidisp_table
	sta A1B1
	; Enable HDMA in vertical blank, so that both channels start from their tables' first entry
	; at the next frame (a channel enabled mid-frame runs from whatever state it was in).
	lda RDNMI
@vblank:
	lda RDNMI
	bpl @vblank
	lda #$03
	sta HDMAEN

	ldx #112
	stx VTIMEL
	lda #$A0              ; NMI and V-IRQ
	sta NMITIMEN
	lda #$0F
	sta INIDISP           ; display on, full brightness
	cli
@forever:
	wai
	bra @forever

nmi:
	sep #$20
	pha
	lda RDNMI
	lda #$11
	sta TM                ; BG1 and sprites for the top half
	lda #$E0
	sta COLDATA           ; fixed colour black
	inc counter
	lda counter
	sta BG1VOFS
	lda #$1F
	sta BG1VOFS           ; BG1VOFS = $300 + c (10 bits), M7VOFS = $1F00 + c (13 bits)
	; Wait for line 3 of the next frame: past 225-255 (low byte >= 200), 256-261 (high bit set)
	; and 0-2.
@wait:
	lda STAT78            ; reset the counters' read flip-flop
	lda SLHV
	lda OPVCT
	sta vline
	lda OPVCT
	and #$01
	bne @wait
	lda vline
	cmp #3
	bcc @wait
	cmp #200
	bcs @wait
	stz VMADDL            ; VRAM word $7000 = c, both bytes
	lda #$70
	sta VMADDH
	lda counter
	sta VMDATAL
	sta VMDATAL + 1
	lda #200              ; colour 200 = c, c & $7F
	sta CGADD
	lda counter
	sta CGDATA
	and #$7F
	sta CGDATA
	pla
	rti

irq:
	sep #$20
	pha
	lda TIMEUP
	lda #$01
	sta TM                ; BG1 only below line 112
	lda #$3F              ; fixed colour: red 31
	sta COLDATA
	pla
	rti

empty:
	rti

palette:
	.word $0000, $001F, $03E0, $7C00   ; palette 0: black, red, green, blue
	.res 24, 0
	.word $0000, $7FFF, $0210, $4210   ; palette 1: black, white, olive, grey
palette_end:
sprite_palette:
	.word $0000, $7C1F, $03FF, $7FE0   ; magenta, yellow, cyan
sprite_palette_end:

sprites:                               ; x, y, tile, attributes (palette 0, priority 3)
	.byte 40, 40, 1, $30
	.byte 80, 60, 2, $30
	.byte 120, 150, 1, $70                 ; h-flip
	.byte 200, 100, 1, $30                 ; x bit 9 set in the high table: off screen

; Register (low byte of $21xx) and value pairs, written in order. Registers written twice take
; the low byte first.
ppu_registers:
	.byte $01, $59                         ; OBSEL: 8x8/32x32, name select 3, name base $2000
	.byte $02, $05, $03, $80               ; OAMADD = $8005: priority rotation, word 5
	.byte $05, $E9                         ; BGMODE: Mode 1, BG3 priority, BG2-4 16x16 tiles
	.byte $06, $5E                         ; MOSAIC: size 6 on BG2-4
	.byte $07, $10                         ; BG1SC: tilemap at word $1000, 32x32
	.byte $08, $21, $09, $32, $0A, $43     ; BG2SC-BG4SC
	.byte $0B, $30, $0C, $54               ; BG12NBA (BG1 at $0000), BG34NBA
	.byte $0F, $23, $0F, $01               ; BG2HOFS = $123
	.byte $10, $45, $10, $00               ; BG2VOFS = $045
	.byte $11, $67, $11, $00               ; BG3HOFS = $067
	.byte $12, $89, $12, $01               ; BG3VOFS = $189
	.byte $13, $AB, $13, $00               ; BG4HOFS = $0AB
	.byte $14, $CD, $14, $01               ; BG4VOFS = $1CD
	.byte $1A, $C3                         ; M7SEL
	.byte $1B, $34, $1B, $12               ; M7A = $1234
	.byte $1C, $65, $1C, $87               ; M7B = $8765
	.byte $1D, $0F, $1D, $0F               ; M7C = $0F0F
	.byte $1E, $0D, $1E, $F0               ; M7D = $F00D
	.byte $1F, $00, $1F, $1F               ; M7X = $1F00
	.byte $20, $23, $20, $01               ; M7Y = $0123
	.byte $23, $B4, $24, $7D, $25, $E6     ; W12SEL, W34SEL, WOBJSEL
	.byte $26, $12, $27, $34, $28, $56, $29, $78 ; WH0-WH3
	.byte $2A, $1B, $2B, $09               ; WBGLOG, WOBJLOG
	.byte $2C, $11, $2D, $0A, $2E, $06, $2F, $13 ; TM (BG1, sprites), TS, TMW (not BG1), TSW
	.byte $30, $33                         ; CGWSEL: never clip, always prevent math, add subscreen, direct colour
	.byte $31, $D5                         ; CGADSUB
	.byte $33, $42                         ; SETINI: EXTBG, OBJ interlace
ppu_registers_end:

inidisp_table:
	.byte 8, $8F                           ; lines 1-8: forced blank
	.byte 1, $0F                           ; then the display on
	.byte 0

zero:
	.byte 0                                ; DMA source for clearing VRAM and CGRAM

hdma_table:
	.repeat 28, i
	.byte 8                                ; 8 lines
	.word i * 4                            ; hscroll
	.endrepeat
	.byte 0

.segment "HEADER"
	.byte "PPU DUMP TEST SNES   "          ; 21 bytes
	.byte $20                              ; LoROM, SlowROM
	.byte $00                              ; ROM only
	.byte $05                              ; 32 KB
	.byte $00                              ; no SRAM
	.byte $01                              ; region: North America
	.byte $00                              ; developer
	.byte $00                              ; version
	.word $0000                            ; checksum complement (not checked by Mesen)
	.word $0000                            ; checksum

.segment "VECTORS"
	.word 0, 0, empty, empty, empty, nmi, 0, irq         ; native: -, -, COP, BRK, ABORT, NMI, -, IRQ
	.word 0, 0, empty, 0, empty, empty, reset, empty     ; emulation: -, -, COP, -, ABORT, NMI, RESET, IRQ
