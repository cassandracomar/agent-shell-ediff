;;; agent-shell-ediff-test.el --- Tests for agent-shell-ediff -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'agent-shell-ediff)

(defconst agent-shell-ediff-test--diffs
  '(((:old . "old one")
     (:new . "new one")
     (:file . "one.el"))
    ((:old . "old two")
     (:new . "new two")
     (:file . "two.el"))))

(defmacro agent-shell-ediff-test--without-live-group (&rest body)
  "Run BODY without retaining a grouped review."
  (declare (indent 0) (debug t))
  `(let ((agent-shell-ediff--current-group nil))
     (unwind-protect
         (progn ,@body)
       (when agent-shell-ediff--current-group
         (agent-shell-ediff--end-session
          agent-shell-ediff--current-group t)))))

(ert-deftest agent-shell-ediff-test-modern-diffs-form-one-group ()
  (agent-shell-ediff-test--without-live-group
    (let ((exit-count 0)
          started
          owner)
      (cl-letf (((symbol-function 'agent-shell-ediff--show-sidebar) #'ignore)
                ((symbol-function 'agent-shell-ediff--start-file)
                 (lambda (_session index) (push index started))))
        (setq owner
              (agent-shell-ediff
               :diffs agent-shell-ediff-test--diffs
               :title "2 files"
               :on-exit (lambda () (cl-incf exit-count))))
        (should (buffer-live-p owner))
        (should (equal started '(0)))
        (with-current-buffer owner
          (should (= (length (agent-shell-ediff-group-diffs
                              agent-shell-ediff--buffer-group))
                     2))
          (should (functionp agent-shell-diff--on-exit)))
        ;; This is how modern Agent Shell closes a tracked diff after the
        ;; permission has already been answered.  It must not prompt again.
        (agent-shell-diff-kill-buffer owner)
        (should (= exit-count 0))
        (should-not agent-shell-ediff--current-group)))))

(ert-deftest agent-shell-ediff-test-unexpected-owner-kill-runs-on-exit-once ()
  (agent-shell-ediff-test--without-live-group
    (let ((exit-count 0)
          owner)
      (cl-letf (((symbol-function 'agent-shell-ediff--show-sidebar) #'ignore)
                ((symbol-function 'agent-shell-ediff--start-file) #'ignore))
        (setq owner
              (agent-shell-ediff
               :diffs (list (car agent-shell-ediff-test--diffs))
               :on-exit (lambda ()
                          (cl-incf exit-count)
                          ;; Resolving the permission makes modern Agent Shell
                          ;; try to kill the tracked owner buffer again.
                          (agent-shell-diff-kill-buffer owner))))
        (kill-buffer owner)
        (should (= exit-count 1))
        (should-not agent-shell-ediff--current-group)))))

(ert-deftest agent-shell-ediff-test-ending-from-sidebar-kills-owner ()
  (agent-shell-ediff-test--without-live-group
    (let ((exit-count 0)
          owner)
      (cl-letf (((symbol-function 'agent-shell-ediff--show-sidebar) #'ignore)
                ((symbol-function 'agent-shell-ediff--start-file) #'ignore))
        (setq owner
              (agent-shell-ediff
               :diffs (list (car agent-shell-ediff-test--diffs))
               :on-exit (lambda () (cl-incf exit-count))))
        (with-current-buffer owner
          (agent-shell-ediff-end-session))
        (should-not (buffer-live-p owner))
        (should (= exit-count 1))
        (should-not agent-shell-ediff--current-group)))))

(ert-deftest agent-shell-ediff-test-sidebar-switches-files ()
  (agent-shell-ediff-test--without-live-group
    (let (started owner)
      (cl-letf (((symbol-function 'agent-shell-ediff--show-sidebar) #'ignore)
                ((symbol-function 'agent-shell-ediff--start-file)
                 (lambda (_session index) (push index started))))
        (setq owner (agent-shell-ediff :diffs agent-shell-ediff-test--diffs))
        (with-current-buffer owner
          (goto-char (point-min))
          (forward-line 1)
          (agent-shell-ediff-select-file)
          (should (= (agent-shell-ediff-group-current-index
                      agent-shell-ediff--buffer-group)
                     1)))
        (should (equal started '(1 0)))
        (agent-shell-diff-kill-buffer owner)))))

(ert-deftest agent-shell-ediff-test-accept-applies-to-whole-group ()
  (agent-shell-ediff-test--without-live-group
    (let ((accept-count 0)
          (exit-count 0)
          owner)
      (cl-letf (((symbol-function 'agent-shell-ediff--show-sidebar) #'ignore)
                ((symbol-function 'agent-shell-ediff--start-file) #'ignore))
        (setq owner
              (agent-shell-ediff
               :diffs agent-shell-ediff-test--diffs
               :on-accept (lambda () (cl-incf accept-count))
               :on-exit (lambda () (cl-incf exit-count))))
        (with-current-buffer owner
          (agent-shell-ediff-accept-all))
        (should (= accept-count 1))
        (should (= exit-count 0))
        (should-not (buffer-live-p owner))
        (should-not agent-shell-ediff--current-group)))))

(ert-deftest agent-shell-ediff-test-expands-a-hunk-to-full-file ()
  (let* ((dir (make-temp-file "agent-shell-ediff-test-" t))
         (file (expand-file-name "example.txt" dir)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "alpha\nbeta\ngamma\n"))
          (let ((contents
                 (agent-shell-ediff--build-contents
                  '((:old . "beta")
                    (:new . "BETA")
                    (:file . "example.txt"))
                  dir)))
            (should (equal (car contents) "alpha\nbeta\ngamma\n"))
            (should (equal (cdr contents) "alpha\nBETA\ngamma\n"))))
      (delete-directory dir t))))

(provide 'agent-shell-ediff-test)
;;; agent-shell-ediff-test.el ends here
