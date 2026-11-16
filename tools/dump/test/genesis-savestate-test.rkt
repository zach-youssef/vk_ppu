#lang racket/base
;; Tests for genesis-savestate.rkt, on real savestates of genesis-test-rom.rkt's ROM (whose
;; patterns give every byte the extractor must produce), taken by two emulators:
;;   genesis-test.gs0         - BlastEm (GST format), after 30 frames
;;   genesis-test.gpgx-state  - Genesis Plus GX 1.7.6 (libretro core's retro_serialize), after 30
;;                              frames
;; See genesis.md for how they were made. Run with `raco test tools/dump`.

(require rackunit racket/file racket/port racket/runtime-path racket/system compiler/find-exe
         "genesis-test-rom.rkt" "genesis-megacd-state.rkt" "../genesis-savestate.rkt")

(define-runtime-path gst-fixture "genesis-test.gs0")
(define-runtime-path gpgx-fixture "genesis-test.gpgx-state")
(define-runtime-path extractor "../genesis-savestate.rkt")

(define expected
  (hasheq 'vram (expected-vram) 'cram (expected-cram) 'vsram (expected-vsram)
          'registers (expected-registers)))

(define (check-extracts data format-name)
  (define-values (name memory) (extract-savestate data))
  (check-equal? name format-name)
  (for ([file (in-list output-files)])
    (define-values (key file-name size) (apply values file))
    (check-equal? (bytes-length (hash-ref memory key)) size file-name)
    (check-equal? (hash-ref memory key) (hash-ref expected key) file-name)))

(define (check-fails data message-part)
  (check-exn (λ (e) (and (exn:fail:user? e) (regexp-match? (regexp-quote message-part) (exn-message e))))
             (λ () (extract-savestate data))))

(define gst (file->bytes gst-fixture))
(define gpgx (file->bytes gpgx-fixture))

(test-case "the fixtures have their formats' sizes"
  (check-equal? (bytes-length gst) #x22478)
  (check-equal? (bytes-length gpgx) #xFD000))

(test-case "a GST savestate extracts to what the ROM wrote"
  (check-extracts gst "GST (Gens, Kega Fusion, BlastEm)"))

(test-case "a Genesis Plus GX savestate extracts to what the ROM wrote"
  (check-extracts gpgx "Genesis Plus GX (GENPLUS-GX 1.7.6)"))

(test-case "a GST with Gens' extra data after it still extracts"
  (check-extracts (bytes-append gst (make-bytes #x11F08 7)) "GST (Gens, Kega Fusion, BlastEm)"))

;; RetroArch's container, with a block before the core's state whose length isn't a multiple of 8
(define (rastate core-state)
  (define (block id content)
    (bytes-append id (integer->integer-bytes (bytes-length content) 4 #f #f) content
                  (make-bytes (modulo (- (bytes-length content)) 8) 0)))
  (bytes-append #"RASTATE\1" (block #"RPLY" #"12345") (block #"MEM " core-state) (block #"END " #"")))

(test-case "a RetroArch savestate extracts its core's state"
  (check-extracts (rastate gpgx) "RetroArch, Genesis Plus GX (GENPLUS-GX 1.7.6)"))

(test-case "a RetroArch savestate without a core state fails"
  (check-fails (bytes-append #"RASTATE\1" #"END " (make-bytes 4 0)) "no core state")
  (check-fails (subbytes (rastate gpgx) 0 1000) "runs past its end"))

(test-case "truncated savestates fail"
  (check-fails (subbytes gst 0 (- #x22478 1)) "shorter than")
  (check-fails (subbytes gpgx 0 #x22000) "shorter than"))

(test-case "other formats fail with what to do"
  (check-fails #"#RZIPv1#rest" "compressed")
  (check-fails #"BLSTSZ\1\7rest" "state_format gst")
  (check-fails (bytes-append #"GENPLUS-GX 1.7.1" (subbytes gpgx 16)) "aren't supported")
  (check-fails (make-bytes #x30000 0) "not a savestate"))

(test-case "a VDP outside Mega Drive mode (mode 5) fails"
  (define mode-4 (bytes-copy gst))
  (bytes-set! mode-4 (+ #xFA 1) #x40)
  (check-fails mode-4 "isn't in Mega Drive mode"))

;; The command line: files written on success, a non-zero exit on failure
(define (run-extractor . args)
  (define err (open-output-string))
  (define ok?
    (parameterize ([current-output-port (open-output-nowhere)] [current-error-port err])
      (apply system* (find-exe) extractor args)))
  (values ok? (get-output-string err)))

(test-case "the command line writes the files, and fails non-zero on a bad savestate"
  (define out (make-temporary-directory))
  (dynamic-wind
   void
   (λ ()
     (define-values (ok? err) (run-extractor (path->string gst-fixture) (path->string out)))
     (check-true ok? err)
     (for ([file (in-list output-files)])
       (define-values (key file-name size) (apply values file))
       (check-equal? (file->bytes (build-path out file-name)) (hash-ref expected key) file-name))
     (define bad (build-path out "bad.gs0"))
     (call-with-output-file bad (λ (port) (void (write-bytes #"GST" port))))
     (define-values (bad-ok? bad-err) (run-extractor (path->string bad) (path->string (build-path out "bad"))))
     (check-false bad-ok?)
     (check-regexp-match #rx"shorter than" bad-err)
     (check-false (directory-exists? (build-path out "bad"))))
   (λ () (delete-directory/files out))))

;; ---------------------------------------------------------------------------------------------
;; Mega-CD (Genesis Plus GX), on synthetic states from genesis-megacd-state.rkt

(define (be n size) (integer->integer-bytes n size #f #t))
(define expected-wordram
  (apply bytes-append (for/list ([i (in-range #x20000)]) (be (wordram-word i) 2))))
(define (expected-asic one-m?)
  (bytes-append (be (scd-reg-word 1 one-m?) 2)
                (apply bytes-append (for/list ([n (in-range #x2C #x34)]) (be (scd-reg-word n one-m?) 2)))
                (bytes 0 0)
                (apply bytes-append (for/list ([v (in-list gfx-values)]) (be v 4)))))

(define (check-megacd state layout-part mode #:format [format-name "Genesis Plus GX (GENPLUS-GX 1.7.6)"])
  (define-values (name memory) (extract-savestate state))
  (check-equal? name format-name)
  (for ([file (in-list output-files)])
    (define-values (key file-name size) (apply values file))
    (check-equal? (hash-ref memory key) (hash-ref expected key) file-name))
  (for ([file (in-list megacd-output-files)])
    (define-values (key file-name size) (apply values file))
    (check-equal? (bytes-length (hash-ref memory key)) size file-name))
  (check-equal? (hash-ref memory 'wordram) expected-wordram "wordram.bin")
  (check-equal? (hash-ref memory 'asic) (expected-asic (equal? mode "1M")) "asic.bin")
  (check-regexp-match (regexp-quote layout-part) (hash-ref memory 'megacd))
  (check-regexp-match (regexp-quote (format "word RAM in ~a mode" mode)) (hash-ref memory 'megacd)))

(test-case "the Mega Drive fixture isn't taken for a Mega-CD state"
  (define-values (name memory) (extract-savestate gpgx))
  (check-false (hash-has-key? memory 'megacd)))

(test-case "a Mega-CD state extracts word RAM and the ASIC's state, in both word RAM modes"
  (for* ([build (in-list '((#x234C6 current "since Feb 2024")
                           (#x234C5 old "Sep 2021 (e87891f) to Nov 2023")
                           (#x22BEE current "since Feb 2024")
                           (#x234C6 rework "Nov 2023 (fcb6620) to Feb 2024")))]
         [mode (in-list '("2M" "1M"))])
    (define-values (marker layout layout-part) (apply values build))
    (check-megacd (megacd-state marker layout (equal? mode "1M")) layout-part mode)))

(test-case "a Nov 2023 to Feb 2024 Mega-CD state is read with or without a DMA"
  (for ([target (in-list '(0 2 6))])
    (check-megacd (megacd-state #x234C6 'rework #f #:dma-target target) "Nov 2023 (fcb6620)" "2M")))

(test-case "a Genesis Plus GX 1.7.5 Mega-CD state fails"
  (check-fails (megacd-state #x234C6 'old #f #:version #"GENPLUS-GX 1.7.5") "only GENPLUS-GX 1.7.6"))

(test-case "a RetroArch Mega-CD state extracts the same"
  (check-megacd (rastate (megacd-state #x234C6 'current #f)) "since Feb 2024" "2M"
                #:format "RetroArch, Genesis Plus GX (GENPLUS-GX 1.7.6)"))

(test-case "a Mega-CD marker where no known build puts it fails"
  (define state (megacd-state #x234C6 'current #f))
  (put! state #x234C6 #"\0\0\0\0")
  (put! state #x23400 #"SCD!")
  (check-fails state "not where a 64-bit Genesis Plus GX puts it"))

(test-case "a Mega-CD state whose layout can't be told fails"
  (check-fails (megacd-state #x234C6 'current #f #:idle-timers? #t) "it matches (")
  (check-fails (megacd-state #x234C6 'rework #f #:idle-timers? #t #:dma-target 0) "it matches (")
  (check-fails (megacd-state #x234C5 'old #f #:dma-target 9) "it matches none"))

(test-case "a truncated Mega-CD state fails"
  (define state (megacd-state #x234C6 'current #f))
  (check-fails (subbytes state 0 (- (bytes-length state) 200)) "shorter than its word RAM")
  ;; cut in the last 8 bytes of an old-layout state's word RAM, where the other layouts' word RAM
  ;; would still fit
  (define old (megacd-state #x234C5 'old #f))
  (check-fails (subbytes old 0 (- (bytes-length old) 116 4)) "shorter than its word RAM"))

(test-case "the command line writes word RAM and the ASIC's state for a Mega-CD state"
  (define out (make-temporary-directory))
  (dynamic-wind
   void
   (λ ()
     (define state-file (build-path out "cd.state"))
     (call-with-output-file state-file (λ (port) (void (write-bytes (megacd-state #x234C5 'old #t) port))))
     (define-values (ok? err) (run-extractor (path->string state-file) (path->string (build-path out "dump"))))
     (check-true ok? err)
     (check-equal? (file->bytes (build-path out "dump" "vram.bin")) (hash-ref expected 'vram))
     (check-equal? (file->bytes (build-path out "dump" "wordram.bin")) expected-wordram)
     (check-equal? (file->bytes (build-path out "dump" "asic.bin")) (expected-asic #t)))
   (λ () (delete-directory/files out))))
