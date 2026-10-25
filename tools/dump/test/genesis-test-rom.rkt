#lang racket/base
;; A tiny Mega Drive ROM, hand-assembled, that writes known patterns into every part of the VDP
;; that genesis-savestate.rkt extracts, then loops forever. A savestate taken while it loops is the
;; extractor's test fixture (test/genesis-test.gs0, and
;; test/genesis-test.gpgx-state from Genesis Plus GX); the expected-* functions give what each
;; extracted byte must be. It's our own code, so the ROM and the savestate are freely
;; redistributable, but the ROM itself isn't committed: it's regenerated when needed.
;;
;;   racket tools/dump/test/genesis-test-rom.rkt <out.md>
;;
;; What the ROM does, from 0x200 (the reset vector):
;;   - TMSS: writes "SEGA" to 0xA14000 when the version register says the console has TMSS
;;   - writes the 24 VDP registers from test-registers (reg 1 first enables mode 5, so the
;;     registers above 10 are accepted; auto-increment, reg 15, is 2)
;;   - VRAM: 32768 words from address 0, word i = i * 0x0103 (mod 2^16)
;;   - CRAM: 64 words from address 0, word i = (i * 0x0246) & 0x0EEE
;;   - VSRAM: 40 words from address 0, word i = (i * 0x0135) & 0x07FF
;;   - then `bra.s *`
;; The patterns aren't byte-symmetric, so a swapped byte order fails the test.

(provide test-registers
         expected-vram expected-cram expected-vsram expected-registers
         build-test-rom)

;; Register values (index 0-23): a plausible H40 setup with distinct values throughout. Display
;; on, no interrupts, no DMA (reg 1 bit 4 clear, so the DMA registers are only stored).
(define test-registers
  (list #x04 #x44 #x30 #x3C #x07 #x6C #x00 #x21 #x00 #x00 #xDF #x03
        #x81 #x34 #x00 #x02 #x11 #x8A #x9C #x12 #x34 #x56 #x78 #x1A))

(define (vram-word i) (bitwise-and (* i #x0103) #xFFFF))
(define (cram-word i) (bitwise-and (* i #x0246) #x0EEE))
(define (vsram-word i) (bitwise-and (* i #x0135) #x07FF))

;; Big-endian words to bytes: the extractor's output order (the VDP's own)
(define (words->bytes count word)
  (define out (make-bytes (* 2 count)))
  (for ([i (in-range count)])
    (define w (word i))
    (bytes-set! out (* 2 i) (arithmetic-shift w -8))
    (bytes-set! out (add1 (* 2 i)) (bitwise-and w #xFF)))
  out)

(define (expected-vram) (words->bytes 32768 vram-word))
(define (expected-cram) (words->bytes 64 cram-word))
(define (expected-vsram) (words->bytes 40 vsram-word))
(define (expected-registers) (list->bytes test-registers))

(define code-start #x200)
(define idle-loop #x27A)        ; the `bra.s *`
(define register-table #x27C)   ; 24 words, 0x8000 | reg << 8 | value
(define rom-size #x2000)

(define (long n) (list (arithmetic-shift n -16) (bitwise-and n #xFFFF)))

;; The program as 16-bit words; the comments give each instruction's address
(define code
  (append
   (list #x43F9) (long #xC00004)         ; 200 lea     $C00004,a1     (VDP control)
   (list #x41F9) (long #xC00000)         ; 206 lea     $C00000,a0     (VDP data)
   (list #x1039) (long #xA10001)         ; 20C move.b  $A10001,d0     (version register)
   (list #x0200 #x000F)                  ; 212 andi.b  #$0F,d0
   (list #x670A)                         ; 216 beq.s   $222           (no TMSS)
   (list #x23FC) (long #x53454741) (long #xA14000) ; 218 move.l #'SEGA',$A14000
   (list #x45F9) (long register-table)   ; 222 lea     register-table,a2
   (list #x7217)                         ; 228 moveq   #23,d1
   (list #x329A)                         ; 22A move.w  (a2)+,(a1)
   (list #x51C9 #xFFFC)                  ; 22C dbra    d1,$22A
   (list #x22BC) (long #x40000000)       ; 230 move.l  #$40000000,(a1)  VRAM write, address 0
   (list #x7000)                         ; 236 moveq   #0,d0
   (list #x323C #x7FFF)                  ; 238 move.w  #$7FFF,d1
   (list #x3080)                         ; 23C move.w  d0,(a0)
   (list #x0640 #x0103)                  ; 23E addi.w  #$0103,d0
   (list #x51C9 #xFFF8)                  ; 242 dbra    d1,$23C
   (list #x22BC) (long #xC0000000)       ; 246 move.l  #$C0000000,(a1)  CRAM write, address 0
   (list #x7000)                         ; 24C moveq   #0,d0
   (list #x723F)                         ; 24E moveq   #63,d1
   (list #x3600)                         ; 250 move.w  d0,d3
   (list #x0243 #x0EEE)                  ; 252 andi.w  #$0EEE,d3
   (list #x3083)                         ; 256 move.w  d3,(a0)
   (list #x0640 #x0246)                  ; 258 addi.w  #$0246,d0
   (list #x51C9 #xFFF2)                  ; 25C dbra    d1,$250
   (list #x22BC) (long #x40000010)       ; 260 move.l  #$40000010,(a1)  VSRAM write, address 0
   (list #x7000)                         ; 266 moveq   #0,d0
   (list #x7227)                         ; 268 moveq   #39,d1
   (list #x3600)                         ; 26A move.w  d0,d3
   (list #x0243 #x07FF)                  ; 26C andi.w  #$07FF,d3
   (list #x3083)                         ; 270 move.w  d3,(a0)
   (list #x0640 #x0135)                  ; 272 addi.w  #$0135,d0
   (list #x51C9 #xFFF2)                  ; 276 dbra    d1,$26A
   (list #x60FE)                         ; 27A bra.s   *
   (for/list ([value (in-list test-registers)] [reg (in-naturals)])
     (bitwise-ior #x8000 (arithmetic-shift reg 8) value)))) ; 27C register-table

(define (build-test-rom)
  (define rom (make-bytes rom-size 0))
  (define (put-word! address w)
    (bytes-set! rom address (arithmetic-shift w -8))
    (bytes-set! rom (add1 address) (bitwise-and w #xFF)))
  (define (put-long! address n)
    (put-word! address (arithmetic-shift n -16))
    (put-word! (+ address 2) (bitwise-and n #xFFFF)))
  (define (put-string! address s)
    (bytes-copy! rom address (string->bytes/latin-1 s)))
  ;; Vectors: the stack, the reset PC, and every exception or interrupt to the idle loop
  (put-long! 0 #x00FFFE00)
  (put-long! 4 code-start)
  (for ([v (in-range 8 #x100 4)]) (put-long! v idle-loop))
  ;; The header
  (put-string! #x100 "SEGA MEGA DRIVE ")
  (put-string! #x110 "(C)PPU  2026.OCT")
  (put-string! #x120 (pad "PPU DUMP TEST" 48))
  (put-string! #x150 (pad "PPU DUMP TEST" 48))
  (put-string! #x180 "GM 00000000-00")
  (put-string! #x190 (pad "J" 16))
  (put-long! #x1A0 0)
  (put-long! #x1A4 (sub1 rom-size))
  (put-long! #x1A8 #xFF0000)
  (put-long! #x1AC #xFFFFFF)
  (put-string! #x1F0 (pad "JUE" 16))
  ;; The program
  (for ([w (in-list code)] [i (in-naturals)])
    (put-word! (+ code-start (* 2 i)) w))
  (unless (= (+ code-start (* 2 (length code))) (+ register-table (* 2 (length test-registers))))
    (error 'build-test-rom "the code doesn't end where the register table does"))
  ;; The checksum (words from 0x200 to the end), which emulators don't check, for completeness
  (put-word! #x18E (for/fold ([sum 0]) ([a (in-range #x200 rom-size 2)])
                     (bitwise-and (+ sum (* 256 (bytes-ref rom a)) (bytes-ref rom (add1 a)))
                                  #xFFFF)))
  rom)

(define (pad s n) (string-append s (make-string (- n (string-length s)) #\space)))

(module+ main
  (require racket/cmdline racket/file)
  (define out (command-line #:args (out.md) out.md))
  (call-with-output-file out #:exists 'truncate (λ (port) (void (write-bytes (build-test-rom) port)))))
