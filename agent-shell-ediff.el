;;; agent-shell-ediff.el --- Review Agent Shell edits with Ediff -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Cassandra Comar
;;
;; Author: Cassandra Comar <cass@mountclare.net>
;; Maintainer: Cassandra Comar <cass@mountclare.net>
;; Created: April 08, 2026
;; Modified: September 09, 2026
;; Version: 0.1.0
;; Homepage: https://github.com/cassandracomar/agent-shell-ediff
;; Package-Requires: ((emacs "29.1") (agent-shell "0"))
;;
;; This file is not part of GNU Emacs.
;;
;;; Commentary:
;;
;; Replace `agent-shell-diff' with an Ediff-based review.  A tool call
;; touching multiple files is represented by one persistent review group:
;; a sidebar lists every file and selecting one changes the comparison
;; displayed by Ediff.  The group owns one Agent Shell permission decision.
;;
;;; Code:

(require 'cl-lib)
(require 'ediff)
(require 'ediff-init)
(require 'map)
(require 'subr-x)
(require 'agent-shell-diff)

(defgroup agent-shell-ediff nil
  "Review Agent Shell edits with Ediff."
  :group 'agent-shell)

(defcustom agent-shell-ediff-quick-quit nil
  "When non-nil, bind `q' to end the grouped review immediately.
This skips Ediff's own extra quit confirmation.  Agent Shell still asks
whether to accept or reject the edit."
  :type 'boolean
  :group 'agent-shell-ediff)

(defcustom agent-shell-ediff-overlay-priority '(nil . 101)
  "Priority for Ediff current-diff and fine-diff overlays.
This should be higher than `hl-line-overlay-priority' so Ediff
highlighting remains visible in non-selected windows."
  :type 'sexp
  :group 'agent-shell-ediff)

(defcustom agent-shell-ediff-sidebar-width 32
  "Width of the file-list sidebar."
  :type 'integer
  :group 'agent-shell-ediff)

(defface agent-shell-ediff-current-file
  '((t :inherit highlight :weight bold))
  "Face used for the file currently displayed by Ediff."
  :group 'agent-shell-ediff)

(defface agent-shell-ediff-visited-file
  '((t :inherit shadow))
  "Face used for files already visited in the grouped review."
  :group 'agent-shell-ediff)

(cl-defstruct (agent-shell-ediff-group
               (:constructor agent-shell-ediff-group-create))
  diffs
  title
  current-index
  visited
  sidebar-buffer
  ctl-buffer
  saved-winconf
  switching-files-p
  tracked-buffers
  calling-buffer
  default-directory
  closing-p)

(defvar agent-shell-ediff--current-group nil
  "The active grouped Agent Shell review, or nil.")

(defvar-local agent-shell-ediff--buffer-group nil
  "The grouped review associated with the current buffer.")

(declare-function evil-define-key* "evil-core")
(declare-function evil-local-set-key "evil-core")
(declare-function evil-set-initial-state "evil-core")
(defvar winum-assign-functions)

;;;; Sidebar

(defvar agent-shell-ediff-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'agent-shell-ediff-select-file)
    (define-key map (kbd "SPC") #'agent-shell-ediff-select-file)
    (define-key map (kbd "j") #'agent-shell-ediff-next-file)
    (define-key map (kbd "k") #'agent-shell-ediff-previous-file)
    (define-key map (kbd "<down>") #'agent-shell-ediff-next-file)
    (define-key map (kbd "<up>") #'agent-shell-ediff-previous-file)
    (define-key map (kbd "a") #'agent-shell-ediff-accept-all)
    (define-key map (kbd "r") #'agent-shell-ediff-reject-all)
    (define-key map (kbd "q") #'agent-shell-ediff-end-session)
    map)
  "Keymap for `agent-shell-ediff-list-mode'.")

(define-derived-mode agent-shell-ediff-list-mode special-mode
  "Agent-Shell-Ediff"
  "Major mode for the file list of a grouped Agent Shell review."
  (setq-local truncate-lines t)
  (setq-local cursor-type nil)
  (hl-line-mode 1)
  (add-hook 'kill-buffer-hook
            #'agent-shell-ediff--sidebar-killed-hook nil t))

(with-eval-after-load 'evil
  (evil-set-initial-state 'agent-shell-ediff-list-mode 'normal)
  (evil-define-key* 'normal agent-shell-ediff-list-mode-map
    (kbd "RET") #'agent-shell-ediff-select-file
    (kbd "SPC") #'agent-shell-ediff-select-file
    (kbd "j") #'agent-shell-ediff-next-file
    (kbd "k") #'agent-shell-ediff-previous-file
    (kbd "<down>") #'agent-shell-ediff-next-file
    (kbd "<up>") #'agent-shell-ediff-previous-file
    (kbd "a") #'agent-shell-ediff-accept-all
    (kbd "r") #'agent-shell-ediff-reject-all
    (kbd "q") #'agent-shell-ediff-end-session))

(defun agent-shell-ediff--diff-file (diff)
  "Return DIFF's file name."
  (or (map-elt diff :file) "(unknown file)"))

(defun agent-shell-ediff--render-sidebar (group)
  "Render the file list for GROUP."
  (let ((buffer (agent-shell-ediff-group-sidebar-buffer group)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (current (agent-shell-ediff-group-current-index group))
              (visited (agent-shell-ediff-group-visited group))
              (saved-line (line-number-at-pos)))
          (erase-buffer)
          (setq header-line-format
                (format " %s  RET view · a allow · r reject · q close"
                        (agent-shell-ediff-group-title group)))
          (cl-loop for diff in (agent-shell-ediff-group-diffs group)
                   for index from 0
                   for face = (cond ((= index current)
                                     'agent-shell-ediff-current-file)
                                    ((gethash index visited)
                                     'agent-shell-ediff-visited-file)
                                    (t 'default))
                   do (insert
                       (propertize
                        (agent-shell-ediff--diff-file diff)
                        'face face
                        'agent-shell-ediff-index index)
                       "\n"))
          (goto-char (point-min))
          (forward-line (max 0 (1- saved-line))))))))

(defun agent-shell-ediff--show-sidebar (group)
  "Display GROUP's file list in a persistent left side window."
  (let ((window
         (display-buffer-in-side-window
          (agent-shell-ediff-group-sidebar-buffer group)
          `((side . left)
            (slot . 0)
            (window-width . ,agent-shell-ediff-sidebar-width)
            (preserve-size . (t . nil))))))
    (when window
      (set-window-parameter window 'agent-shell-ediff-sidebar t)
      (set-window-parameter window 'no-delete-other-windows t)
      (set-window-dedicated-p window t))
    window))

(defun agent-shell-ediff--sidebar-window-p (window)
  "Return non-nil when WINDOW is this package's file-list window."
  (window-parameter window 'agent-shell-ediff-sidebar))

(defun agent-shell-ediff--winum-assign ()
  "Assign window number 0 to the Agent Shell Ediff sidebar."
  (when (eq major-mode 'agent-shell-ediff-list-mode) 0))

(with-eval-after-load 'winum
  (add-to-list 'winum-assign-functions
               #'agent-shell-ediff--winum-assign))

;;;; Diff contents and buffers

(defun agent-shell-ediff--replace-hunk (contents old new line)
  "Replace OLD with NEW in CONTENTS, using LINE as a location hint.
Return nil when OLD cannot be found."
  (unless (string-empty-p old)
    (with-temp-buffer
      (insert contents)
      (goto-char (point-min))
      (let ((start (point-min))
            found)
        (when (and (integerp line) (> line 0))
          (goto-char (point-min))
          (forward-line (1- line))
          (setq start (point)))
        (setq found (search-forward old nil t))
        (unless found
          (goto-char (point-min))
          (when (> start (point-min))
            (setq found (search-forward old start t))))
        (when found
          (delete-region (- found (length old)) found)
          (insert new)
          (buffer-string))))))

(defun agent-shell-ediff--build-contents (diff directory)
  "Return (OLD . NEW) full-file strings for DIFF in DIRECTORY.
Agent Shell diff entries can contain only the changed hunk.  When the
file still exists on disk, expand that hunk into the full file."
  (let* ((old (or (map-elt diff :old) ""))
         (new (or (map-elt diff :new) ""))
         (file (map-elt diff :file))
         (full-path (and file (expand-file-name file directory)))
         (full-old
          (when (and full-path (file-readable-p full-path))
            (with-temp-buffer
              (insert-file-contents full-path)
              (buffer-string))))
         (full-new
          (and full-old
               (agent-shell-ediff--replace-hunk
                full-old old new (map-elt diff :line)))))
    (cons (or full-old old)
          (or full-new new))))

(defun agent-shell-ediff--make-buffer (group diff side contents)
  "Create a temporary Ediff buffer for GROUP, DIFF, SIDE, and CONTENTS."
  (let* ((file (agent-shell-ediff--diff-file diff))
         (full-path (expand-file-name
                     file (agent-shell-ediff-group-default-directory group)))
         (buffer (generate-new-buffer
                  (format "*agent-shell-ediff %s: %s*" side file)))
         (mode (assoc-default file auto-mode-alist #'string-match)))
    (with-current-buffer buffer
      (setq default-directory
            (agent-shell-ediff-group-default-directory group))
      (insert contents)
      (setq-local buffer-file-name full-path)
      (when mode
        (ignore-errors (funcall mode)))
      (setq-local buffer-file-name nil)
      (font-lock-ensure)
      (set-buffer-modified-p nil)
      (setq buffer-read-only t))
    buffer))

(defun agent-shell-ediff--track-buffer (group buffer)
  "Track BUFFER for cleanup with GROUP."
  (when (and (buffer-live-p buffer)
             (not (memq buffer
                        (agent-shell-ediff-group-tracked-buffers group))))
    (push buffer (agent-shell-ediff-group-tracked-buffers group))))

(defun agent-shell-ediff--kill-tracked-buffers (group)
  "Kill all temporary comparison buffers belonging to GROUP."
  (dolist (buffer (agent-shell-ediff-group-tracked-buffers group))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (set-buffer-modified-p nil))
      (let ((kill-buffer-query-functions nil))
        (ignore-errors (kill-buffer buffer)))))
  (setf (agent-shell-ediff-group-tracked-buffers group) nil))

(defun agent-shell-ediff--kill-ediff-aux-buffers (control)
  "Kill Ediff auxiliary buffers associated with CONTROL."
  (when (buffer-live-p control)
    (with-current-buffer control
      (dolist (variable '(ediff-diff-buffer
                          ediff-custom-diff-buffer
                          ediff-fine-diff-buffer
                          ediff-tmp-buffer
                          ediff-error-buffer
                          ediff-msg-buffer
                          ediff-debug-buffer))
        (when-let* ((buffer (and (boundp variable)
                                 (symbol-value variable))))
          (when (buffer-live-p buffer)
            (let ((kill-buffer-query-functions nil))
              (ignore-errors (kill-buffer buffer)))))))))

;;;; Per-file view inside one grouped review

(defun agent-shell-ediff--setup-quick-quit ()
  "Install the quick-quit binding in the current Ediff control buffer."
  (when agent-shell-ediff-quick-quit
    (local-set-key (kbd "q") #'agent-shell-ediff-quit)
    (when (fboundp 'evil-local-set-key)
      (evil-local-set-key 'normal (kbd "q")
                          #'agent-shell-ediff-quit))))

(defun agent-shell-ediff--boost-overlay-priority ()
  "Raise Ediff overlays above common line-highlighting overlays."
  (let ((priority agent-shell-ediff-overlay-priority))
    (dolist (variable '(ediff-current-diff-overlay-A
                        ediff-current-diff-overlay-B
                        ediff-current-diff-overlay-C
                        ediff-current-diff-overlay-Ancestor))
      (when (and (boundp variable)
                 (overlayp (symbol-value variable)))
        (overlay-put (symbol-value variable) 'priority priority)))
    (when (ediff-valid-difference-p ediff-current-difference)
      (dolist (buffer-type '(A B C))
        (condition-case nil
            (let ((overlays
                   (ediff-get-fine-diff-vector
                    ediff-current-difference buffer-type)))
              (when (vectorp overlays)
                (mapc (lambda (overlay)
                        (when (overlayp overlay)
                          (overlay-put overlay 'priority priority)))
                      overlays)))
          (error nil))))))

(defun agent-shell-ediff--start-file (group index)
  "Display entry INDEX from GROUP in Ediff."
  (agent-shell-ediff--kill-tracked-buffers group)
  (let* ((diff (nth index (agent-shell-ediff-group-diffs group)))
         (contents
          (agent-shell-ediff--build-contents
           diff (agent-shell-ediff-group-default-directory group)))
         (buffer-a
          (agent-shell-ediff--make-buffer group diff "old" (car contents)))
         (buffer-b
          (agent-shell-ediff--make-buffer group diff "proposed" (cdr contents)))
         startup-hook before-setup-hook)
    (agent-shell-ediff--track-buffer group buffer-a)
    (agent-shell-ediff--track-buffer group buffer-b)
    (setf (agent-shell-ediff-group-current-index group) index)
    (puthash index t (agent-shell-ediff-group-visited group))
    (agent-shell-ediff--render-sidebar group)
    (setq before-setup-hook
          (lambda ()
            (cl-loop for window in (window-list)
                     when (and (window-parameter window 'window-side)
                               (not (agent-shell-ediff--sidebar-window-p window)))
                     do (delete-window window))
            (remove-hook 'ediff-before-setup-hook before-setup-hook)))
    (setq startup-hook
          (lambda ()
            (setf (agent-shell-ediff-group-ctl-buffer group)
                  ediff-control-buffer)
            (with-current-buffer ediff-control-buffer
              (setq-local agent-shell-ediff--buffer-group group)
              (setq-local ediff-keep-variants t)
              (agent-shell-ediff--setup-quick-quit)
              (setq-local
               ediff-quit-hook
               (list
                (lambda ()
                  (agent-shell-ediff--kill-tracked-buffers group))
                #'ediff-cleanup-mess
                (lambda ()
                  (setf (agent-shell-ediff-group-ctl-buffer group) nil)
                  (if (agent-shell-ediff-group-switching-files-p group)
                      (agent-shell-ediff--show-sidebar group)
                    (unless (agent-shell-ediff-group-closing-p group)
                      (agent-shell-ediff--end-session group)))))))
            (agent-shell-ediff--show-sidebar group)
            (ignore-errors (ediff-next-difference))
            (agent-shell-ediff--boost-overlay-priority)
            (add-hook 'ediff-select-hook
                      #'agent-shell-ediff--boost-overlay-priority nil t)
            (remove-hook 'ediff-startup-hook startup-hook)))
    (add-hook 'ediff-before-setup-hook before-setup-hook)
    (add-hook 'ediff-startup-hook startup-hook)
    (condition-case error-data
        (let ((ediff-window-setup-function #'ediff-setup-windows-plain)
              (ediff-split-window-function #'split-window-horizontally)
              (ediff-control-buffer-suffix
               (format "<%s>" (agent-shell-ediff--diff-file diff))))
          (ediff-buffers buffer-a buffer-b))
      (error
       (remove-hook 'ediff-before-setup-hook before-setup-hook)
       (remove-hook 'ediff-startup-hook startup-hook)
       (agent-shell-ediff--kill-tracked-buffers group)
       (signal (car error-data) (cdr error-data))))))

(defun agent-shell-ediff--quit-current-file (group)
  "Close GROUP's current Ediff comparison without ending the group."
  (let ((control (agent-shell-ediff-group-ctl-buffer group)))
    (when (buffer-live-p control)
      (setf (agent-shell-ediff-group-switching-files-p group) t)
      (unwind-protect
          (with-current-buffer control
            (ignore-errors (ediff-really-quit nil)))
        (setf (agent-shell-ediff-group-switching-files-p group) nil))))
  (setf (agent-shell-ediff-group-ctl-buffer group) nil)
  (agent-shell-ediff--kill-tracked-buffers group))

;;;; Group lifecycle and permission actions

(defun agent-shell-ediff--callback (group variable)
  "Return GROUP's sidebar-local callback VARIABLE."
  (let ((buffer (agent-shell-ediff-group-sidebar-buffer group)))
    (when (buffer-live-p buffer)
      (buffer-local-value variable buffer))))

(defun agent-shell-ediff--call-in-origin (group callback)
  "Call CALLBACK in GROUP's originating buffer when possible."
  (let ((origin (agent-shell-ediff-group-calling-buffer group)))
    (if (buffer-live-p origin)
        (with-current-buffer origin
          (funcall callback))
      (funcall callback))))

(defun agent-shell-ediff--end-session
    (&optional group suppress-on-exit sidebar-being-killed)
  "Tear down GROUP.
When SUPPRESS-ON-EXIT is non-nil, do not invoke Agent Shell's exit
callback.  This is used after the permission was resolved elsewhere.
SIDEBAR-BEING-KILLED is non-nil only when called from its kill hook."
  (let ((group (or group agent-shell-ediff--current-group)))
    (when (and group
               (not (agent-shell-ediff-group-closing-p group)))
      (setf (agent-shell-ediff-group-closing-p group) t)
      (let* ((sidebar (agent-shell-ediff-group-sidebar-buffer group))
             (callback
              (unless suppress-on-exit
                (agent-shell-ediff--callback
                 group 'agent-shell-diff--on-exit))))
        ;; Clear this before cleanup.  The callback may resolve the permission,
        ;; causing Agent Shell to try to kill the tracked sidebar again.
        (when (buffer-live-p sidebar)
          (with-current-buffer sidebar
            (setq agent-shell-diff--on-exit nil)
            (remove-hook 'kill-buffer-hook
                         #'agent-shell-ediff--sidebar-killed-hook t)))
        (setf (agent-shell-ediff-group-switching-files-p group) t)
        (let ((control (agent-shell-ediff-group-ctl-buffer group)))
          (when (buffer-live-p control)
            (with-current-buffer control
              (ignore-errors (ediff-really-quit nil)))
            (agent-shell-ediff--kill-ediff-aux-buffers control)
            (when (buffer-live-p control)
              (let ((kill-buffer-query-functions nil))
                (ignore-errors (kill-buffer control))))))
        (agent-shell-ediff--kill-tracked-buffers group)
        (unless sidebar-being-killed
          (when (buffer-live-p sidebar)
            (let ((kill-buffer-query-functions nil))
              (kill-buffer sidebar))))
        (when (eq group agent-shell-ediff--current-group)
          (setq agent-shell-ediff--current-group nil))
        (when-let* ((configuration
                     (agent-shell-ediff-group-saved-winconf group)))
          (ignore-errors (set-window-configuration configuration)))
        (when (functionp callback)
          (agent-shell-ediff--call-in-origin group callback))))))

(defun agent-shell-ediff--sidebar-killed-hook ()
  "End the grouped review when its persistent sidebar is killed."
  (when agent-shell-ediff--buffer-group
    (agent-shell-ediff--end-session
     agent-shell-ediff--buffer-group nil t)))

(defun agent-shell-ediff-end-session ()
  "End the entire grouped review.
Agent Shell's exit callback asks whether to accept or reject the edit."
  (interactive)
  (agent-shell-ediff--end-session
   (or agent-shell-ediff--buffer-group
       agent-shell-ediff--current-group)))

(defun agent-shell-ediff-accept-all ()
  "Accept the entire grouped edit."
  (interactive)
  (let* ((group (or agent-shell-ediff--buffer-group
                    agent-shell-ediff--current-group))
         (callback
          (and group
               (agent-shell-ediff--callback
                group 'agent-shell-diff--accept-all-command))))
    (unless (functionp callback)
      (user-error "No accept command available"))
    (agent-shell-ediff--call-in-origin group callback)
    (unless (agent-shell-ediff-group-closing-p group)
      (agent-shell-ediff--end-session group t))))

(defun agent-shell-ediff-reject-all ()
  "Reject the entire grouped edit."
  (interactive)
  (let* ((group (or agent-shell-ediff--buffer-group
                    agent-shell-ediff--current-group))
         (callback
          (and group
               (agent-shell-ediff--callback
                group 'agent-shell-diff--reject-all-command))))
    (unless (functionp callback)
      (user-error "No reject command available"))
    (when (agent-shell-ediff--call-in-origin group callback)
      (unless (agent-shell-ediff-group-closing-p group)
        (agent-shell-ediff--end-session group t)))))

;;;; Sidebar commands

(defun agent-shell-ediff-select-file ()
  "Display the file on the current sidebar line."
  (interactive)
  (let ((index (get-text-property
                (line-beginning-position) 'agent-shell-ediff-index))
        (group agent-shell-ediff--buffer-group))
    (cond
     ((null index) (user-error "No file at point"))
     ((null group) (user-error "No active grouped review"))
     ((= index (agent-shell-ediff-group-current-index group))
      (message "Already showing %s"
               (agent-shell-ediff--diff-file
                (nth index (agent-shell-ediff-group-diffs group)))))
     (t
      (agent-shell-ediff--quit-current-file group)
      (setf (agent-shell-ediff-group-current-index group) index)
      (agent-shell-ediff--start-file group index)))))

(defun agent-shell-ediff-next-file ()
  "Move to the next file in the sidebar."
  (interactive)
  (forward-line 1))

(defun agent-shell-ediff-previous-file ()
  "Move to the previous file in the sidebar."
  (interactive)
  (forward-line -1))

;;;; Agent Shell integration

(cl-defun agent-shell-ediff
    (&key diffs old new file on-exit on-accept on-reject title)
  "Review one Agent Shell edit as a grouped Ediff session.

DIFFS is the modern Agent Shell list of alists with :old, :new, :file,
and optional :line keys.  All entries share one persistent sidebar and
one permission decision.  OLD, NEW, and FILE remain accepted for
compatibility with older Agent Shell versions.

ON-EXIT, ON-ACCEPT, ON-REJECT, and TITLE follow `agent-shell-diff'."
  (let* ((diffs
          (or diffs
              (when (or old new file)
                (list `((:old . ,(or old ""))
                        (:new . ,(or new ""))
                        (:file . ,file))))))
         (diffs (if (vectorp diffs) (append diffs nil) diffs)))
    (unless diffs
      (user-error "No diffs to review"))
    (when agent-shell-ediff--current-group
      (if (buffer-live-p
           (agent-shell-ediff-group-sidebar-buffer
            agent-shell-ediff--current-group))
          (progn
            (unless (y-or-n-p "End the existing Agent Shell edit review? ")
              (user-error "Existing grouped review is still active"))
            (agent-shell-ediff--end-session
             agent-shell-ediff--current-group))
        (setq agent-shell-ediff--current-group nil)))
    (let* ((title
            (or title
                (if (= (length diffs) 1)
                    (file-name-nondirectory
                     (agent-shell-ediff--diff-file (car diffs)))
                  (format "%d files" (length diffs)))))
           (sidebar
            (generate-new-buffer
             (format "*agent-shell-ediff: %s*" title)))
           (group
            (agent-shell-ediff-group-create
             :diffs diffs
             :title title
             :current-index 0
             :visited (make-hash-table :test #'eql)
             :sidebar-buffer sidebar
             :saved-winconf (current-window-configuration)
             :calling-buffer (current-buffer)
             :default-directory default-directory)))
      (with-current-buffer sidebar
        (setq default-directory
              (agent-shell-ediff-group-default-directory group))
        (agent-shell-ediff-list-mode)
        (setq-local agent-shell-ediff--buffer-group group)
        ;; These names are part of modern Agent Shell's tracked diff-buffer
        ;; protocol.  `agent-shell-diff-kill-buffer' clears --on-exit before
        ;; killing this persistent owner buffer.
        (setq-local agent-shell-diff--on-exit on-exit)
        (setq-local agent-shell-diff--accept-all-command on-accept)
        (setq-local agent-shell-diff--reject-all-command on-reject))
      (setq agent-shell-ediff--current-group group)
      (condition-case error-data
          (progn
            (agent-shell-ediff--render-sidebar group)
            (agent-shell-ediff--show-sidebar group)
            (agent-shell-ediff--start-file group 0))
        (error
         (agent-shell-ediff--end-session group t)
         (signal (car error-data) (cdr error-data))))
      ;; Modern Agent Shell tracks and later kills this persistent buffer.
      sidebar)))

(defun agent-shell-ediff-quit ()
  "End the grouped review from an Ediff control buffer."
  (interactive)
  (ediff-barf-if-not-control-buffer)
  (agent-shell-ediff-end-session))

;;;###autoload
(define-minor-mode agent-shell-ediff-mode
  "Use grouped Ediff reviews for Agent Shell file edits."
  :global t
  :group 'agent-shell-ediff
  (if agent-shell-ediff-mode
      (advice-add 'agent-shell-diff :override #'agent-shell-ediff)
    (advice-remove 'agent-shell-diff #'agent-shell-ediff)))

(provide 'agent-shell-ediff)
;;; agent-shell-ediff.el ends here
