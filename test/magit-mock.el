;;; magit-mock.el --- Minimal magit mock for testing -*- lexical-binding: t; -*-

;;; Commentary:

;; Provides stubs for magit symbols used by magit-llm-commit so that
;; tests can run without a full magit installation.

;;; Code:

(defvar git-commit-mode-map (make-sparse-keymap)
  "Mock keymap for git-commit-mode.")

(defvar git-commit-summary-max-length 50
  "Mock max length for commit summary line.")

(defun magit-commit-message-buffer ()
  "Mock: return nil (no commit buffer)."
  nil)

(defun magit-git-output (&rest _args)
  "Mock: return empty diff."
  "")

(defun magit-commit-create (&rest _args)
  "Mock: no-op.")

(defun magit-commit-arguments ()
  "Mock: return empty args."
  nil)

(defun magit-current-section ()
  "Mock: return nil."
  nil)

(defun magit-stash-show ()
  "Mock: no-op."
  nil)

;; Provide magit so (require 'magit) succeeds
(provide 'magit)

(provide 'magit-mock)
;;; magit-mock.el ends here