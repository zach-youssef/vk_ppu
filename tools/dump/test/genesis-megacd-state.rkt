#lang racket/base
;; Synthetic Genesis Plus GX Mega-CD (Sega CD) states, for genesis-savestate-test.rkt and
;; gpgx-frame's check. No real Mega-CD state can be committed (they embed BIOS-derived PRG-RAM),
;; so these are the Mega Drive fixture's prefix up to where the marker goes (so the VDP part is
;; real), then "SCD!" and a CD part with patterns at the offsets the extractor reads and zeros
;; elsewhere, laid out as each known build saves it (see genesis.md). From the command line, writes
;; a current-layout state in 2M mode (a libretro build's, marker at 0x234C6):
;;
;;   racket tools/dump/test/genesis-megacd-state.rkt <out.state>

(require racket/file racket/runtime-path)
(provide megacd-state wordram-word scd-reg-word gfx-values le put!)

(define-runtime-path gpgx-fixture "genesis-test.gpgx-state")
(define gpgx (file->bytes gpgx-fixture))

;; Word RAM in 2M order: word i, byte-asymmetric
(define (wordram-word i) (bitwise-and (+ (* i #x0107) (arithmetic-shift i -9) #x0A00) #xFFFF))
;; scd.regs word n ($FF8000 + 2n), with $FF8002's MODE bit (bit 2) set for 1M
(define (scd-reg-word n one-m?)
  (define w (bitwise-and (+ (* n #x0B13) #x4100) #xFFFF))
  (if (= n 1) (if one-m? (bitwise-ior w 4) (bitwise-and w (bitwise-not 4))) w))
;; gfx_context_save's fields: cycles, cyclesPerLine, dotMask, stampShift, mapShift, bufferOffset,
;; bufferStart, trace and map offsets
(define gfx-values '(#x12345678 #x0000A1B2 #x007FFFFF #x05 #x04 #x00F8 #x00012340 #x00031208 #x00020000))

(define (le n size) (integer->integer-bytes n size #f #f))
(define (put! state at bs) (bytes-copy! state at bs))

;; A Mega-CD state, built field by field from GPGX's saved sizes (not from the tool's offsets):
;; the Mega Drive fixture's prefix up to the marker, then scd_context_save. layout is 'current,
;; 'rework (Nov 2023 to Feb 2024) or 'old (OpenEmu's); dma-target is the CDC's saved DMA target
;; (2, PRG-RAM, by default; 6 is a halted DMA in a 'rework state). idle-timers? zeroes the CDC's
;; and CDD's cycle counts and the CDC RAM, which makes a state look like the other layouts too.
(define (megacd-state marker-at layout one-m? #:idle-timers? [idle? #f] #:dma-target [target 2]
                      #:version [version #"GENPLUS-GX 1.7.6"])
  (define cdd-cycles (if idle? 0 #x00012C40))
  (define dma-callback (if (<= 1 target 5) #x0000000104A3B2C0 0))
  ;; sector data, here bytes no DMA target or host pointer can be, as the other layouts read some
  ;; of it as those
  (define cdc-ram (make-bytes (+ #x4000 2352) 0))
  (unless idle?
    (for ([i (in-range (bytes-length cdc-ram))])
      (bytes-set! cdc-ram i (bitwise-ior #x80 (bitwise-and (* i 7) #x7F)))))
  (define cdc
    (bytes-append
     (make-bytes 24 0)                                    ; ifstat .. stat
     (case layout
       [(current) (bytes-append (le #x3F00 4) (le (if idle? 0 #x0004B1D0) 4))] ; cycles[2]
       [(rework) (bytes-append (le #x3F00 4) (le dma-callback 8))]             ; cycles, dma_w
       [(old) (bytes-append (le #x3F00 4) (make-bytes 4 0) (le dma-callback 8))]) ; and padding
     cdc-ram
     (bytes target)))
  (define cdd (bytes-append (le cdd-cycles 4) (le 3 4) (le 2 4) (make-bytes 21 0))) ; cycles, latency, index
  (define wordram
    (let ([w (make-bytes #x40000)])
      ;; host (little-endian) words; in 1M mode two banks of alternate 2M words
      (for ([i (in-range #x20000)])
        (define slot (if one-m? (+ (quotient i 2) (* #x10000 (remainder i 2))) i))
        (bytes-copy! w (* 2 slot) (le (wordram-word i) 2)))
      w))
  (define state
    (bytes-append
     (subbytes gpgx 0 marker-at)
     #"SCD!"
     (apply bytes-append (for/list ([n (in-range 256)]) (le (scd-reg-word n one-m?) 2)))
     (make-bytes 14 0)                                    ; the timers
     (apply bytes-append (for/list ([v (in-list gfx-values)] [size (in-list '(4 4 4 1 1 2 4 4 4))])
                           (le v size)))
     cdc
     cdd
     (make-bytes 65672 0)                                 ; PCM
     (make-bytes #x80000 0)                               ; PRG-RAM
     wordram
     (make-bytes 116 0)))                                 ; what follows (sub 68K ...)
  (put! state 0 version)
  state)

(module+ main
  (require racket/cmdline)
  (define out (command-line #:args (out.state) out.state))
  (call-with-output-file out #:exists 'truncate
    (λ (port) (void (write-bytes (megacd-state #x234C6 'current #f) port)))))
