#lang racket/base
;; Tests for genesis-savestate.rkt, on real savestates of genesis-test-rom.rkt's ROM (whose
;; patterns give every byte the extractor must produce), taken by two emulators:
;;   genesis-test.gs0         - BlastEm (GST format), after 30 frames
;;   genesis-test.gpgx-state  - Genesis Plus GX 1.7.6 (libretro core's retro_serialize), after 30
;;                              frames
;; See genesis.md for how they were made. Run with `raco test tools/dump`.

(require rackunit racket/file racket/port racket/runtime-path racket/system compiler/find-exe
         "genesis-test-rom.rkt" "../genesis-savestate.rkt")

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
