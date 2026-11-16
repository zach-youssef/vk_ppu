#lang racket/base
;; Extracts the Mega Drive (Genesis) VDP's memory and registers from an emulator savestate, in the
;; VDP's own big-endian order, for a Genesis game program to load. See genesis.md beside this file
;; for the formats, the output files' layout and how to take a savestate.
;;
;;   racket tools/dump/genesis-savestate.rkt <savestate> <out-dir>
;;
;; writes <out-dir>/vram.bin (65536 bytes), cram.bin (128), vsram.bin (80) and registers.bin (24),
;; plus wordram.bin (262144) and asic.bin (56) for a Genesis Plus GX Mega-CD state, and exits
;; non-zero, writing nothing, when the savestate isn't one it can read.

(require racket/list)

(provide extract-savestate output-files megacd-output-files)

;; The output files, in the order they're written, with their sizes
(define output-files
  '((vram "vram.bin" 65536)
    (cram "cram.bin" 128)
    (vsram "vsram.bin" 80)
    (registers "registers.bin" 24)))

;; Written as well for a Mega-CD state (Genesis Plus GX only; GST has no Mega-CD part)
(define megacd-output-files
  '((wordram "wordram.bin" 262144)
    (asic "asic.bin" 56)))

;; ---------------------------------------------------------------------------------------------
;; Gens, Kega Fusion, Genecyst and BlastEm (ui.state_format gst): the GST layout, at fixed offsets.
;; VRAM is in VDP address order; CRAM and VSRAM are little-endian words; the 68K and Z80 parts
;; aren't read.
(define gst-registers #xFA)
(define gst-cram #x112)
(define gst-vsram #x192)
(define gst-vram #x12478)
(define gst-min-size #x22478) ; Genecyst, Kega and BlastEm; Gens appends more after it

;; Genesis Plus GX 1.7.5 and 1.7.6 (2013 to now, as in OpenEmu and RetroArch), Mega Drive mode:
;; the core's state_save(), in the host's (little-endian) byte order. VRAM is stored as host
;; words, so each pair of bytes is swapped; CRAM is packed to 9 bits, BBBGGGRRR; VSRAM is 64
;; little-endian words, of which the VDP has 40.
(define gpgx-versions '(#"GENPLUS-GX 1.7.5" #"GENPLUS-GX 1.7.6"))
;; version (16), 68K RAM (0x10000), Z80 RAM (0x2000), zstate (1), zbank (4), io_reg (0x10)
(define gpgx-sat (+ 16 #x10000 #x2000 1 4 #x10))
(define gpgx-vram (+ gpgx-sat #x400))
(define gpgx-cram (+ gpgx-vram #x10000))
(define gpgx-vsram (+ gpgx-cram #x80))
(define gpgx-registers (+ gpgx-vsram #x80))
(define gpgx-min-size (+ gpgx-registers #x20))

;; Mega-CD (Genesis Plus GX only). state_save() keeps the Mega Drive prefix above, then after the
;; VDP comes the sound, 68K and Z80 contexts, the marker "SCD!" and the CD hardware
;; (scd_context_save in cd_hw/scd.c). The sound and Z80 contexts are host structs saved whole
;; (the YM2612's and the Z80's hold pointers), so the marker's offset depends on the host and the
;; build. These are the offsets on 64-bit hosts, worked out from GPGX's sources and checked
;; against the Mega Drive fixture, whose Z80 context ends at 0x234C6 (see genesis.md):
;;   VDP end 0x2256B; config.ym3438 (1 byte, only in builds with the Nuked YM3438 core);
;;   MAME YM2612 (3576 + 48) or Nuked YM3438 (1252 + 96 + 8 + 4); PSG (124); fm_cycles_start
;;   (4); 68K (90); Z80_Regs (88).
(define gpgx-scd-markers
  '(#x234C6   ; MAME YM2612 in a build with the Nuked YM3438 core (RetroArch's default)
    #x234C5   ; MAME YM2612 in a build without it (OpenEmu)
    #x22BEE)) ; Nuked YM3438 (RetroArch's "nuked" FM option)
(define gpgx-scd-marker #"SCD!")
;; Where to look for a marker at an offset not listed above (a 32-bit host, another build), to
;; say so instead of treating a Mega-CD state as a Mega Drive one
(define gpgx-scd-search (cons (+ gpgx-min-size 38) #x24000))

;; From the marker: scd.regs (256 little-endian words, register $FF80xx at word xx/2), the timers,
;; then the gfx context: cycles, cyclesPerLine and dotMask (32-bit), stampShift and mapShift
;; (8-bit), bufferOffset (16-bit), bufferStart, and the trace and map pointers as offsets into
;; word RAM (32-bit), all little-endian.
(define scd-regs 4)
(define scd-gfx #x212)
(define scd-cdc #x22E)

;; The CD part is read only from "GENPLUS-GX 1.7.6" states: 1.7.5 ones predate e87891f (Sep
;; 2021), which grew the CDD context, and aren't supported.
(define gpgx-scd-version #"GENPLUS-GX 1.7.6")

;; What follows the gfx context changed twice without a new version string, as GPGX's CDC rework
;; (fcb6620, Nov 2023, to e8a6086, Feb 2024) changed how the CDC is saved, so word RAM sits at one
;; of three offsets. After the CDC comes its DMA target (1 byte), then the CDD context (33 bytes:
;; cycles, latency, index (32-bit) ...), PCM (65672 bytes) and PRG-RAM (0x80000), the same in all
;; three. A layout is told apart by facts that hold for its own states and rarely for the others
;; (check : data cdc-offset -> boolean); a state must match exactly one.
(define cdc-registers 24) ; ifstat, ifctrl, dbc, dac, pt, wa, ctrl[2], head[2][4], stat[4]
(define cdc-ram (+ #x4000 2352))
(define cdd-size 33)
(define cdd-index 8)
(define pcm-size 65672)
(define prg-ram-size #x80000)

;; cdc-size: the CDC's saved bytes up to the DMA target
(struct cd-layout (name cdc-size check))

(define (cd-layout-wordram l)
  (+ scd-cdc (cd-layout-cdc-size l) 1 cdd-size pcm-size prg-ram-size))

;; cdd.index, the current track, is at most 100
(define (track-index-ok? data l cdc)
  (<= (le-long data (+ cdc (cd-layout-cdc-size l) 1 cdd-index)) 100))

(define (dma-target data l cdc) (bytes-ref data (+ cdc (cd-layout-cdc-size l))))
(define (host-pointer data at) (integer-bytes->integer data #f #f at (+ at 8)))

(define gpgx-cd-layouts
  (letrec
      ([current
        ;; the registers, cycles[2] (8), the CDC RAM; DMA target 0 to 7
        (cd-layout "builds since Feb 2024 (e8a6086), such as a current RetroArch core"
                   (+ cdc-registers 8 cdc-ram)
                   (λ (data cdc)
                     (and (<= (dma-target data current cdc) 7)
                          (track-index-ok? data current cdc))))]
       [rework
        ;; the registers, cycles (4), the DMA callback pointer (8; non-null exactly when the
        ;; target is 1 to 5, while 6 and 7 are a halted DMA), the CDC RAM; DMA target 0 to 7
        (cd-layout "builds from Nov 2023 (fcb6620) to Feb 2024 (before e8a6086)"
                   (+ cdc-registers 4 8 cdc-ram)
                   (λ (data cdc)
                     (define pointer (host-pointer data (+ cdc cdc-registers 4)))
                     (define target (dma-target data rework cdc))
                     (and (< pointer (expt 2 48))
                          (<= target 7)
                          (eq? (zero? pointer) (not (<= 1 target 5)))
                          (track-index-ok? data rework cdc))))]
       [old
        ;; the whole cdc_t, 18776 bytes on 64-bit hosts: the registers, cycles (4), padding (4,
        ;; zero), the DMA callback pointer (8; null exactly when the target is 0), the CDC RAM;
        ;; DMA target 0 to 5
        (cd-layout "builds from Sep 2021 (e87891f) to Nov 2023 (before fcb6620), such as OpenEmu's (a2931d1)"
                   (+ cdc-registers 4 4 8 cdc-ram)
                   (λ (data cdc)
                     (define pointer (host-pointer data (+ cdc cdc-registers 8)))
                     (define target (dma-target data old cdc))
                     (and (zero? (le-long data (+ cdc cdc-registers 4)))
                          (< pointer (expt 2 48))
                          (<= target 5)
                          (eq? (zero? pointer) (zero? target))
                          (track-index-ok? data old cdc))))])
    (list current rework old)))
(define wordram-size #x40000)

(define (fail fmt . args) (raise-user-error 'genesis-savestate (apply format fmt args)))

(define (prefix? data prefix)
  (and (>= (bytes-length data) (bytes-length prefix))
       (equal? (subbytes data 0 (bytes-length prefix)) prefix)))

;; count 16-bit words at offset, through (convert word), as big-endian bytes
(define (words data offset count read-word [convert values])
  (define out (make-bytes (* 2 count)))
  (for ([i (in-range count)])
    (define w (convert (read-word data (+ offset (* 2 i)))))
    (bytes-set! out (* 2 i) (arithmetic-shift w -8))
    (bytes-set! out (add1 (* 2 i)) (bitwise-and w #xFF)))
  out)

(define (le-word data at) (bitwise-ior (bytes-ref data at) (arithmetic-shift (bytes-ref data (add1 at)) 8)))
(define (le-long data at) (integer-bytes->integer data #f #f at (+ at 4)))

(define (check-size data min-size name)
  (when (< (bytes-length data) min-size)
    (fail "~a savestate is ~a bytes, shorter than the ~a its layout needs (truncated?)"
          name (bytes-length data) min-size)))

(define (extract-gst data)
  (check-size data gst-min-size "the GST")
  (hasheq 'vram (subbytes data gst-vram (+ gst-vram #x10000))
          'cram (words data gst-cram 64 le-word)
          'vsram (words data gst-vsram 40 le-word)
          'registers (subbytes data gst-registers (+ gst-registers 24))))

;; BBBGGGRRR to the bus format the 68K writes, 0000BBB0GGG0RRR0
(define (unpack-gpgx-color c)
  (bitwise-ior (arithmetic-shift (bitwise-and c #x1C0) 3)
               (arithmetic-shift (bitwise-and c #x038) 2)
               (arithmetic-shift (bitwise-and c #x007) 1)))

(define (extract-gpgx data)
  (check-size data gpgx-min-size "the Genesis Plus GX")
  (define vdp
    (hasheq 'vram (words data gpgx-vram 32768 le-word)
            'cram (words data gpgx-cram 64 le-word unpack-gpgx-color)
            'vsram (words data gpgx-vsram 40 le-word)
            'registers (subbytes data gpgx-registers (+ gpgx-registers 24))))
  (define marker (find-scd-marker data))
  (if marker
      (for/fold ([memory vdp]) ([(k v) (in-hash (extract-megacd data marker))])
        (hash-set memory k v))
      vdp))

(define (marker-at? data at)
  (and (<= (+ at 4) (bytes-length data)) (equal? (subbytes data at (+ at 4)) gpgx-scd-marker)))

;; The marker's offset if the state is a Mega-CD one, #f if it's a Mega Drive one
(define (find-scd-marker data)
  (cond
    [(for/first ([m (in-list gpgx-scd-markers)] #:when (marker-at? data m)) m)]
    [(for/first ([at (in-range (car gpgx-scd-search) (cdr gpgx-scd-search))]
                 #:when (marker-at? data at))
       at)
     => (λ (at)
          (fail "the Mega-CD marker (SCD!) is at $~a, not where a 64-bit Genesis Plus GX puts it (~a): a 32-bit host or an unknown build, whose layout this tool doesn't know"
                (number->string at 16)
                (map (λ (m) (string-append "$" (number->string m 16))) gpgx-scd-markers)))]
    [else #f]))

;; wordram: 2M order, big-endian words. asic: see genesis.md.
(define (extract-megacd data marker)
  (unless (prefix? data gpgx-scd-version)
    (fail "this Mega-CD savestate is from Genesis Plus GX ~a; only ~a states are supported"
          (bytes->string/latin-1 (subbytes data 11 16)) gpgx-scd-version))
  ;; every layout's word RAM must fit, or a truncated state could match only a layout it isn't
  (when (< (bytes-length data) (+ marker (apply max (map cd-layout-wordram gpgx-cd-layouts)) wordram-size))
    (fail "the Mega-CD savestate is ~a bytes, shorter than its word RAM's end (truncated?)"
          (bytes-length data)))
  (define layouts
    (filter (λ (l) ((cd-layout-check l) data (+ marker scd-cdc))) gpgx-cd-layouts))
  (unless (= (length layouts) 1)
    (fail "can't tell which Genesis Plus GX Mega-CD layout this is (~a); the known ones are ~a"
          (if (null? layouts) "it matches none" (format "it matches ~a" (map cd-layout-name layouts)))
          (map cd-layout-name gpgx-cd-layouts)))
  (define layout (first layouts))
  (define regs (+ marker scd-regs))
  ;; $FF8003 (the low byte of word 1) bit 2, MODE: 1M mode
  (define one-m? (bitwise-bit-set? (bytes-ref data (+ regs 2)) 2))
  (define at (+ marker (cd-layout-wordram layout)))
  ;; 2M: one block of host-order words. 1M: two 128 KB banks, and 2M word 2i is bank 0 word i,
  ;; 2i+1 is bank 1 word i.
  (define (source-word i)
    (if one-m?
        (+ at (* 2 (+ (quotient i 2) (* #x10000 (remainder i 2)))))
        (+ at (* 2 i))))
  (define wordram (make-bytes wordram-size))
  (for ([i (in-range (quotient wordram-size 2))])
    (define from (source-word i))
    (bytes-set! wordram (* 2 i) (bytes-ref data (add1 from)))
    (bytes-set! wordram (add1 (* 2 i)) (bytes-ref data from)))
  (define gfx (+ marker scd-gfx))
  (define (gfx-field offset size) (integer-bytes->integer data #f #f (+ gfx offset) (+ gfx offset size)))
  (define (be32 n) (integer->integer-bytes n 4 #f #t))
  (define asic
    (bytes-append
     (words data (+ regs 2) 1 le-word)                    ; $FF8002
     (words data (+ regs #x58) 8 le-word)                 ; $FF8058 to $FF8066
     (make-bytes 2 0)
     (be32 (gfx-field 0 4))                               ; cycles
     (be32 (gfx-field 4 4))                               ; cyclesPerLine
     (be32 (gfx-field 8 4))                               ; dotMask
     (be32 (bytes-ref data (+ gfx 12)))                   ; stampShift
     (be32 (bytes-ref data (+ gfx 13)))                   ; mapShift
     (be32 (gfx-field 14 2))                              ; bufferOffset
     (be32 (gfx-field 16 4))                              ; bufferStart
     (be32 (gfx-field 20 4))                              ; trace pointer
     (be32 (gfx-field 24 4))))                            ; map pointer
  (hasheq 'wordram wordram 'asic asic
          'megacd (format "Mega-CD, word RAM in ~a mode (CD part laid out as GPGX ~a)"
                          (if one-m? "1M" "2M") (cd-layout-name layout))))

;; RetroArch's uncompressed container: "RASTATE" and a version byte, then blocks of a 4-byte id,
;; a little-endian 32-bit length and the content padded to 8 bytes; the core's state is "MEM ".
(define (rastate-core-state data)
  (let loop ([at 8])
    (when (> (+ at 8) (bytes-length data))
      (fail "the RetroArch savestate ends before its core state (MEM block)"))
    (define id (subbytes data at (+ at 4)))
    (define len (le-long data (+ at 4)))
    (define start (+ at 8))
    (when (> (+ start len) (bytes-length data))
      (fail "the RetroArch savestate's ~s block runs past its end" id))
    (cond [(equal? id #"MEM ") (subbytes data start (+ start len))]
          [(equal? id #"END ") (fail "the RetroArch savestate has no core state (MEM block)")]
          [else (loop (+ start (* 8 (quotient (+ len 7) 8))))])))

;; extract-savestate : bytes -> (values format-name (hash/c symbol? any/c))
;; The hash has one entry per output-files name, in the VDP's big-endian order; for a Mega-CD
;; state, one per megacd-output-files name too, and 'megacd, a one-line description.
(define (extract-savestate data)
  (define-values (name memory)
    (cond
      [(prefix? data #"GST") (values "GST (Gens, Kega Fusion, BlastEm)" (extract-gst data))]
      [(for/or ([v (in-list gpgx-versions)]) (and (prefix? data v) v))
       => (λ (v) (values (format "Genesis Plus GX (~a)" v) (extract-gpgx data)))]
      [(prefix? data #"GENPLUS-GX")
       (fail "~a savestates aren't supported, only ~a (another version's layout may differ)"
             (subbytes data 0 (min 16 (bytes-length data))) gpgx-versions)]
      [(prefix? data #"RASTATE")
       (define-values (inner-name inner) (extract-savestate (rastate-core-state data)))
       (values (string-append "RetroArch, " inner-name) inner)]
      [(prefix? data #"#RZIPv")
       (fail "the savestate is compressed: turn off RetroArch's savestate compression (Settings > Saving > Savestate Compression) and save again")]
      [(prefix? data #"BLSTSZ")
       (fail "this is BlastEm's native savestate: set `state_format gst` in the ui section of blastem.cfg and save again")]
      [else (fail "not a savestate this tool reads (GST, or Genesis Plus GX ~a)" gpgx-versions)]))
  (check-mode-5 (hash-ref memory 'registers))
  (values name memory))

;; Register 1 bit 2 is Mega Drive mode (mode 5); a Master System mode state, or a misread one,
;; doesn't have it
(define (check-mode-5 registers)
  (unless (bitwise-bit-set? (bytes-ref registers 1) 2)
    (fail "the VDP isn't in Mega Drive mode (register 1 is $~a): a Master System game, or not a Mega Drive savestate"
          (number->string (bytes-ref registers 1) 16))))

(define (hex n) (string-append "$" (number->string n 16)))

;; A one-line summary of the screen's setup, to sanity-check a dump
;; A cosmetic summary. The window and sprite table addresses aren't masked for H40, which ignores
;; reg 3 bit 1 and reg 5 bit 0; a consumer (GE1) must mask them itself.
(define (describe registers)
  (define (reg i) (bytes-ref registers i))
  (format "~a, display ~a, plane A ~a, plane B ~a, window ~a, sprites ~a, hscroll ~a, planes ~ax~a"
          (if (bitwise-bit-set? (reg 12) 0) "H40 (320 wide)" "H32 (256 wide)")
          (if (bitwise-bit-set? (reg 1) 6) "on" "off")
          (hex (* #x2000 (bitwise-and (arithmetic-shift (reg 2) -3) 7)))
          (hex (* #x2000 (bitwise-and (reg 4) 7)))
          (hex (* #x800 (bitwise-and (arithmetic-shift (reg 3) -1) #x1F)))
          (hex (* #x200 (bitwise-and (reg 5) #x7F)))
          (hex (* #x400 (bitwise-and (reg 13) #x3F)))
          (vector-ref #(32 64 #f 128) (bitwise-and (reg 16) 3))
          (vector-ref #(32 64 #f 128) (bitwise-and (arithmetic-shift (reg 16) -4) 3))))

(module+ main
  (require racket/cmdline racket/file)
  (define-values (state-path out-dir)
    (command-line #:args (savestate out-dir) (values savestate out-dir)))
  (with-handlers ([exn:fail? (λ (e) (eprintf "~a\n" (exn-message e)) (exit 1))])
    (define-values (name memory) (extract-savestate (file->bytes state-path)))
    (define files
      (if (hash-has-key? memory 'megacd) (append output-files megacd-output-files) output-files))
    (make-directory* out-dir)
    (for ([file (in-list files)])
      (define-values (key file-name size) (apply values file))
      (define content (hash-ref memory key))
      (unless (= (bytes-length content) size)
        (fail "internal error: ~a is ~a bytes, not ~a" file-name (bytes-length content) size))
      (call-with-output-file (build-path out-dir file-name) #:exists 'truncate
        (λ (port) (void (write-bytes content port)))))
    (printf "~a: ~a\n" name (describe (hash-ref memory 'registers)))
    (when (hash-has-key? memory 'megacd) (printf "~a\n" (hash-ref memory 'megacd)))
    (printf "Wrote ~a to ~a\n" (map second files) out-dir)))
