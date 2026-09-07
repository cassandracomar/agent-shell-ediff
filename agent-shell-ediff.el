;;; agent-shell-ediff.el --- Replace agent-shell-diff with ediff  -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Cassandra Comar
;;
;; Author: Cassandra Comar <cass@mountclare.net>
;; Maintainer: Cassandra Comar <cass@mountclare.net>
;; Created: April 08, 2026
;; Modified: April 08, 2026
;; Version: 0.0.1
;; Homepage: https://github.com/cassandracomar/agent-shell-ediff
;; Package-Requires: ((emacs "24.3") (agent-shell "0.58.1"))
;;
;; This file is not part of GNU Emacs.
;;
;;; Commentary:
;;
;;  Description
;;
;;; Code:

(require 'ediff)
(require 'cl-lib)
(require 'agent-shell)

(defcustom agent-shell-ediff-quick-quit nil
  "When non-nil, bind \\`q' in ediff to skip the extra quit confirmation.
Uses `agent-shell-ediff-quit' instead of the default `ediff-quit'."
  :type 'boolean
  :group 'agent-shell)

(defcustom agent-shell-ediff-overlay-priority '(nil . 101)
  "Priority for ediff current-diff and fine-diff overlays.
Must be higher than `hl-line-overlay-priority' (typically (nil . 100))
so that ediff highlighting is visible in non-selected windows."
  :type 'sexp
  :group 'agent-shell)

(defun agent-shell-ediff--setup-quick-quit ()
  "Bind \\`q' to `agent-shell-ediff-quit' in the ediff control buffer.
When `evil-mode' is active, normalize keymaps so the binding takes effect."
  (when agent-shell-ediff-quick-quit
    (define-key ediff-mode-map "q" #'agent-shell-ediff-quit)
    (when (bound-and-true-p evil-mode)
      (evil-normalize-keymaps))))

(defun agent-shell-ediff--boost-overlay-priority ()
  "Set priority on ediff current-diff and fine-diff overlays.
This ensures ediff highlighting is visible over `hl-line-mode'
overlays in non-selected windows."
  (let ((pri agent-shell-ediff-overlay-priority))
    ;; Current-diff overlays
    (dolist (ov-var '(ediff-current-diff-overlay-A
                      ediff-current-diff-overlay-B
                      ediff-current-diff-overlay-C
                      ediff-current-diff-overlay-Ancestor))
      (when (and (boundp ov-var) (overlayp (symbol-value ov-var)))
        (overlay-put (symbol-value ov-var) 'priority pri)))
    ;; Fine-diff overlays for the current difference
    (when (ediff-valid-difference-p ediff-current-difference)
      (dolist (buf-type '(A B C))
        (condition-case nil
            (let ((vec (ediff-get-fine-diff-vector
                        ediff-current-difference buf-type)))
              (when (vectorp vec)
                (mapc (lambda (ov)
                        (when (overlayp ov)
                          (overlay-put ov 'priority pri)))
                      vec)))
          (error nil))))))

(cl-defun agent-shell-ediff (&key diffs on-exit on-accept on-reject title)
  "Ediff-based replacement for `agent-shell-diff'.
Creates one or more side-by-side ediff sessions, one per entry in
DIFFS.  When DIFFS holds more than one diff, sessions are shown one
after another; only once the last one is quit is the user prompted to
accept or reject, and the appropriate callback fires for the batch as
a whole.

Arguments match `agent-shell-diff':
  :DIFFS     - List of ((:old . _) (:new . _) (:file . _)) alists, as
               returned by `agent-shell--make-diff-infos'.  A single
               diff is passed as a one-element list.
  :ON-EXIT   - Function called with no arguments if a session is
               killed unexpectedly
  :ON-ACCEPT - Command to accept all changes
  :ON-REJECT - Command to reject all changes
  :TITLE     - Optional title to fall back on for buffer names when a
               diff has no :file"
  (agent-shell-ediff--review
   :diffs diffs
   :index 1
   :total (length diffs)
   :title title
   :on-exit on-exit
   :on-accept on-accept
   :on-reject on-reject
   :saved-winconf (current-window-configuration)
   :calling-buffer (current-buffer)))

(cl-defun agent-shell-ediff--review (&key diffs index total title on-exit on-accept on-reject saved-winconf calling-buffer)
  "Review the first diff in DIFFS, then continue with the rest.
INDEX and TOTAL number the diff currently under review among all the
diffs being reviewed together; used to label buffers when DIFFS holds
more than one entry.  The remaining arguments are as in
`agent-shell-ediff' and are threaded through unchanged as review
proceeds from one diff to the next."
  (when diffs
    (let* ((diff (car diffs))
           (rest (cdr diffs))
           (file (map-elt diff :file))
           (old (or (map-elt diff :old) ""))
           (new (or (map-elt diff :new) ""))
           (name (or (and file (file-name-nondirectory file)) title "unknown"))
           (label (if (> total 1) (format "%s (%d/%d)" name index total) name)))
      (agent-shell-ediff--session
       :old old :new new :file file :label label :final (null rest)
       :on-exit on-exit :on-accept on-accept :on-reject on-reject
       :saved-winconf saved-winconf :calling-buffer calling-buffer
       :on-continue (lambda ()
                      (agent-shell-ediff--review
                       :diffs rest :index (1+ index) :total total
                       :title title :on-exit on-exit :on-accept on-accept
                       :on-reject on-reject :saved-winconf saved-winconf
                       :calling-buffer calling-buffer))))))

(cl-defun agent-shell-ediff--session (&key old new file label final on-exit on-accept on-reject saved-winconf calling-buffer on-continue)
  "Run a single ediff session comparing OLD and NEW content for FILE.
LABEL names the session's buffers.  When FINAL is non-nil, quitting
prompts to accept or reject and fires ON-ACCEPT/ON-REJECT; otherwise
quitting simply calls ON-CONTINUE to advance to the next diff in a
multi-file batch.  SAVED-WINCONF is restored once the session ends.
ON-EXIT and CALLING-BUFFER are as in `agent-shell-ediff'."
  (let* (;; Try to build full-file buffers: read file from disk for
         ;; the old content, replace the old hunk with the new hunk
         ;; to produce the new content.  Fall back to the raw
         ;; old/new hunks if the file can't be read or the hunk
         ;; can't be located.
         (full-old (when (and file (file-readable-p file))
                     (with-temp-buffer
                       (insert-file-contents file)
                       (buffer-string))))
         (full-new (when full-old
                     (with-temp-buffer
                       (insert full-old)
                       (goto-char (point-min))
                       (when (search-forward old nil t)
                         (replace-match new t t)
                         (buffer-string)))))
         (old-content (or full-old old))
         (new-content (or full-new new))
         (buf-a (generate-new-buffer (format "*old: %s*" label)))
         (buf-b (generate-new-buffer (format "*new: %s*" label)))
         (mode (and file (assoc-default file auto-mode-alist #'string-match)))
         ctl-buf startup-hook-fn before-setup-hook-fn)

    ;; Fill buffers with content and set mode for syntax highlighting
    (cl-loop for (buf . content) in (list (cons buf-a old-content)
                                          (cons buf-b new-content))
             do (with-current-buffer buf
                  (insert content)
                  ;; Temporarily set buffer-file-name for mode hooks,
                  ;; then clear it so Emacs doesn't treat this as a file buffer
                  (when file (setq-local buffer-file-name file))
                  (when mode (ignore-errors (funcall mode)))
                  (setq-local buffer-file-name nil)
                  (font-lock-ensure)
                  (set-buffer-modified-p nil)
                  (setq buffer-read-only t)))

    ;; Self-removing hooks (following claude-code-ide pattern)
    (setq before-setup-hook-fn
          (lambda ()
            ;; Delete side windows to prevent "Cannot split side window" errors
            (cl-loop for window in (window-list)
                     when (window-parameter window 'window-side)
                     do (delete-window window))
            (remove-hook 'ediff-before-setup-hook before-setup-hook-fn)))

    (setq startup-hook-fn
          (lambda ()
            (setq ctl-buf ediff-control-buffer)
            (with-current-buffer ediff-control-buffer
              ;; For agent-shell-diff-kill-buffer compatibility
              (setq-local agent-shell-diff--on-exit on-exit)

              ;; Suppress janitor asking about our temp buffers
              (setq-local ediff-keep-variants t)

              ;; Quit hook chain: prompt/continue → kill temps → ediff cleanup → restore winconf
              (setq-local ediff-quit-hook
                          (list
                           ;; 1. On the last diff, prompt accept/reject and schedule
                           ;;    the callback; otherwise clear on-exit and move on to
                           ;;    the next diff in the batch.
                           (if final
                               (lambda ()
                                 (let ((choice (condition-case nil
                                                   (if (y-or-n-p "Accept changes?")
                                                       'accept 'reject)
                                                 (quit 'ignore))))
                                   ;; Clear on-exit so kill-buffer-hook doesn't double-fire
                                   (setq agent-shell-diff--on-exit nil)
                                   (run-with-idle-timer
                                    0.1 nil
                                    (lambda ()
                                      (pcase choice
                                        ('accept (when on-accept (funcall on-accept)))
                                        ('reject
                                         ;; Route through on-exit which sends a proper
                                         ;; reject_once permission response (not just
                                         ;; :cancelled).  Suppress its y-or-n-p since
                                         ;; we already have the user's answer.
                                         (if on-exit
                                             (cl-letf (((symbol-function 'y-or-n-p)
                                                        (lambda (&rest _) nil)))
                                               (funcall on-exit))
                                           (when on-reject (funcall on-reject))))
                                        (_ (message "Ignored")))))))
                             (lambda ()
                               ;; Clear on-exit so kill-buffer-hook doesn't double-fire
                               (setq agent-shell-diff--on-exit nil)
                               (run-with-idle-timer 0.1 nil on-continue)))
                           ;; 2. Kill temp buffers
                           (lambda ()
                             (when (buffer-live-p buf-a) (kill-buffer buf-a))
                             (when (buffer-live-p buf-b) (kill-buffer buf-b)))
                           ;; 3. Standard ediff cleanup (kills aux buffers + control buffer)
                           #'ediff-cleanup-mess
                           ;; 4. Restore window configuration
                           (lambda ()
                             (when saved-winconf
                               (ignore-errors
                                 (set-window-configuration saved-winconf))))))

              ;; External/unexpected kill: fire on-exit and clean up ediff artifacts
              (add-hook 'kill-buffer-hook
                        (lambda ()
                          (when (and agent-shell-diff--on-exit
                                     (buffer-live-p calling-buffer))
                            (with-current-buffer calling-buffer
                              (funcall agent-shell-diff--on-exit)))
                          (cl-loop for buf in (list buf-a buf-b)
                                   when (buffer-live-p buf) do (kill-buffer buf))
                          (cl-loop for var in '(ediff-diff-buffer ediff-fine-diff-buffer
                                                ediff-custom-diff-buffer ediff-error-buffer)
                                   for buf = (and (boundp var) (symbol-value var))
                                   when (and buf (buffer-live-p buf)) do (kill-buffer buf)))
                        nil t))

            (ignore-errors (ediff-next-difference))
            ;; Boost overlay priority so ediff faces win over hl-line
            (agent-shell-ediff--boost-overlay-priority)
            (add-hook 'ediff-select-hook
                      #'agent-shell-ediff--boost-overlay-priority nil t)
            (remove-hook 'ediff-startup-hook startup-hook-fn)))

    ;; Register hooks
    (add-hook 'ediff-before-setup-hook before-setup-hook-fn)
    (add-hook 'ediff-startup-hook startup-hook-fn)

    ;; Start ediff
    (condition-case err
        (let ((old-setup-fn ediff-window-setup-function)
              (old-split-fn ediff-split-window-function)
              (ediff-control-buffer-suffix (format "<%s>" label)))
          (unwind-protect
              (progn
                (setq ediff-window-setup-function #'ediff-setup-windows-plain
                      ediff-split-window-function #'split-window-horizontally)
                (ediff-buffers buf-a buf-b))
            (setq ediff-window-setup-function old-setup-fn
                  ediff-split-window-function old-split-fn)))
      (error
       (when (buffer-live-p buf-a) (kill-buffer buf-a))
       (when (buffer-live-p buf-b) (kill-buffer buf-b))
       (remove-hook 'ediff-before-setup-hook before-setup-hook-fn)
       (remove-hook 'ediff-startup-hook startup-hook-fn)
       (signal (car err) (cdr err))))

    ctl-buf))

(defun agent-shell-ediff-quit ()
  "Quit ediff without the extra confirmation prompt."
  (interactive)
  (ediff-barf-if-not-control-buffer)
  (setq this-command 'ediff-quit)
  (ediff-really-quit nil))

;;;###autoload
(define-minor-mode agent-shell-ediff-mode
  "Toggle ediff-based diffs for `agent-shell'.
When enabled, `agent-shell-diff' is overridden with `agent-shell-ediff'
so that file-change reviews use an ediff session instead of the
default diff display."
  :global t
  :group 'agent-shell
  (if agent-shell-ediff-mode
      (progn
        (advice-add 'agent-shell-diff :override #'agent-shell-ediff)
        (add-hook 'ediff-startup-hook #'agent-shell-ediff--setup-quick-quit))
    (advice-remove 'agent-shell-diff #'agent-shell-ediff)
    (remove-hook 'ediff-startup-hook #'agent-shell-ediff--setup-quick-quit)
    (when (eq (lookup-key ediff-mode-map "q") #'agent-shell-ediff-quit)
      (define-key ediff-mode-map "q" #'ediff-quit))))

(provide 'agent-shell-ediff)
;;; agent-shell-ediff.el ends here
