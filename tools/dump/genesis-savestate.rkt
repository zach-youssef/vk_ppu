#lang racket/base
;; Extracts the Mega Drive (Genesis) VDP's memory and registers from an emulator savestate, in the
;; VDP's own big-endian order, for a Genesis game program to load. See genesis.md beside this file
;; for the formats, the output files' layout and how to take a savestate.
;;
;;   racket tools/dump/genesis-savestate.rkt <savestate> <out-dir>
;;
;; writes <out-dir>/vram.bin (65536 bytes), cram.bin (128), vsram.bin (80) and registers.bin (24),
;; and exits non-zero, writing nothing, when the savestate isn't one it can read.

(require racket/list)

(provide extract-savestate output-files)

;; The output files, in the order they're written, with their sizes
(define output-files
  '((vram "vram.bin" 65536)
    (cram "cram.bin" 128)
    (vsram "vsram.bin" 80)
    (registers "registers.bin" 24)))

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
  (hasheq 'vram (words data gpgx-vram 32768 le-word)
          'cram (words data gpgx-cram 64 le-word unpack-gpgx-color)
          'vsram (words data gpgx-vsram 40 le-word)
          'registers (subbytes data gpgx-registers (+ gpgx-registers 24))))

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

;; extract-savestate : bytes -> (values format-name (hash/c symbol? bytes?))
;; The hash has one entry per output-files name, in the VDP's big-endian order.
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
    (make-directory* out-dir)
    (for ([file (in-list output-files)])
      (define-values (key file-name size) (apply values file))
      (define content (hash-ref memory key))
      (unless (= (bytes-length content) size)
        (fail "internal error: ~a is ~a bytes, not ~a" file-name (bytes-length content) size))
      (call-with-output-file (build-path out-dir file-name) #:exists 'truncate
        (λ (port) (void (write-bytes content port)))))
    (printf "~a: ~a\n" name (describe (hash-ref memory 'registers)))
    (printf "Wrote ~a to ~a\n" (map second output-files) out-dir)))
