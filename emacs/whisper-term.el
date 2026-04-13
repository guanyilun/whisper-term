;;; whisper-term.el --- Stream live transcription into an Emacs buffer -*- lexical-binding: t; -*-

;;; Commentary:
;; Runs whisper-term in the background, writing transcripts to a file.
;; Emacs tails the file in real-time via auto-revert-tail-mode.
;;
;; Commands:
;;   `whisper-term-start'       — start mic transcription
;;   `whisper-term-stop'        — stop transcription
;;   `whisper-term-toggle'      — toggle on/off
;;   `whisper-term-capture-app' — transcribe a running app's audio

;;; Code:

(defgroup whisper-term nil
  "Live transcription with whisper-term."
  :group 'tools
  :prefix "whisper-term-")

(defcustom whisper-term-engine "parakeet"
  "Transcription engine."
  :type 'string
  :group 'whisper-term)

(defcustom whisper-term-working-dir "~/Workspace/scratch/whisper_test"
  "Working directory (where models are)."
  :type 'directory
  :group 'whisper-term)

(defcustom whisper-term-audiocapture-path
  "~/Workspace/scratch/whisper_test/audiocapture/.build/release/audiocapture"
  "Path to audiocapture binary."
  :type 'file
  :group 'whisper-term)

(defcustom whisper-term-transcript-file
  "~/Workspace/scratch/whisper_test/transcript.txt"
  "File where whisper-term writes transcription output."
  :type 'file
  :group 'whisper-term)

(defvar whisper-term--process nil)

(defun whisper-term--list-apps ()
  "Get list of running apps via audiocapture --list."
  (let* ((default-directory (expand-file-name whisper-term-working-dir))
         (output (shell-command-to-string
                  (format "%s --list 2>/dev/null"
                          (expand-file-name whisper-term-audiocapture-path)))))
    (when (and output (not (string-empty-p output)))
      (let (apps)
        (dolist (line (split-string output "\n" t))
          (let ((parts (split-string line "\t")))
            (when (>= (length parts) 3)
              (let ((bid (nth 1 parts))
                    (name (nth 2 parts)))
                (push (cons (format "%s (%s)" name bid) bid) apps)))))
        (nreverse apps)))))

(defun whisper-term--start-process (app-id)
  "Start whisper-term process. APP-ID nil means mic mode."
  (when (and whisper-term--process (process-live-p whisper-term--process))
    (user-error "whisper-term already running. Stop first"))
  (let* ((transcript (expand-file-name whisper-term-transcript-file))
         (default-directory (expand-file-name whisper-term-working-dir))
         (wt "/Users/yilun/miniforge3/bin/whisper-term")
         (cmd (if app-id
                  (format "%s --app %s 2>/dev/null | %s --engine %s -q -o %s"
                          (expand-file-name whisper-term-audiocapture-path)
                          (shell-quote-argument app-id)
                          wt
                          whisper-term-engine
                          (shell-quote-argument transcript))
                (format "%s --engine %s -o %s --mic 2>/tmp/whisper-term-emacs.log"
                        wt
                        whisper-term-engine
                        (shell-quote-argument transcript)))))
    ;; Touch the file so we can open it
    (unless (file-exists-p transcript)
      (write-region "" nil transcript))
    ;; Start background process
    (setq whisper-term--process
          (start-process-shell-command "whisper-term" nil cmd))
    (set-process-sentinel whisper-term--process
                          (lambda (_proc _event)
                            (setq whisper-term--process nil)))
    (set-process-query-on-exit-flag whisper-term--process nil)
    ;; Open the transcript file with auto-revert-tail-mode
    (find-file-other-window transcript)
    (setq-local auto-revert-interval 1)
    (auto-revert-tail-mode 1)
    (goto-char (point-max))
    (message "whisper-term started — transcript streaming to %s" transcript)))

;;;###autoload
(defun whisper-term-start ()
  "Start mic transcription, tailing output in a buffer."
  (interactive)
  (whisper-term--start-process nil))

;;;###autoload
(defun whisper-term-stop ()
  "Stop whisper-term."
  (interactive)
  (if (and whisper-term--process (process-live-p whisper-term--process))
      (progn
        (let ((pid (process-id whisper-term--process)))
          (when pid (signal-process (- pid) 'SIGTERM)))
        (delete-process whisper-term--process)
        (setq whisper-term--process nil)
        (message "whisper-term stopped"))
    (message "whisper-term not running")))

;;;###autoload
(defun whisper-term-toggle ()
  "Toggle whisper-term."
  (interactive)
  (if (and whisper-term--process (process-live-p whisper-term--process))
      (whisper-term-stop)
    (whisper-term-start)))

;;;###autoload
(defun whisper-term-capture-app ()
  "Transcribe a running app's audio."
  (interactive)
  (let* ((apps (whisper-term--list-apps))
         (choice (if apps
                     (completing-read "Capture app: " apps nil t)
                   (read-string "App bundle ID: ")))
         (app-id (or (cdr (assoc choice apps)) choice)))
    (whisper-term--start-process app-id)))

(provide 'whisper-term)
;;; whisper-term.el ends here
