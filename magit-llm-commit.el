;;; magit-llm-commit.el --- Generate commit messages for magit using OpenAI-compatible APIs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Authors
;; SPDX-License-Identifier: Apache-2.0

;; Author: Ragnar Dahlén <r.dahlen@gmail.com>
;; Maintainer: Hirozy <git@hirozy.com>
;; Version: 2.0
;; Package-Requires: ((emacs "28.1") (magit "4.0"))
;; Keywords: vc, convenience
;; URL: https://github.com/Hirozy/magit-llm-commit

;;; Commentary:

;; This package adds LLM integration into magit for generating
;; commit messages and explaining diffs.  It uses Emacs' built-in
;; URL library to call OpenAI-compatible APIs directly, without
;; requiring any external LLM packages.

;;; Code:

(require 'json)
(require 'magit)
(require 'url)

(defconst magit-llm-commit-prompt-zed
  "You are an expert at writing Git commits. Your job is to write a short clear commit message that summarizes the changes.

If you can accurately express the change in just the subject line, don't include anything in the message body. Only use the body when it is providing *useful* information.

Don't repeat information from the subject line in the message body.

Only return the commit message in your response. Do not include any additional meta-commentary about the task. Do not include the raw diff output in the commit message.

Follow good Git style:

- Separate the subject from the body with a blank line
- Try to limit the subject line to 50 characters
- Capitalize the subject line
- Do not end the subject line with any punctuation
- Use the imperative mood in the subject line
- Wrap the body at 68 characters
- Keep the body short and concise (omit it entirely if not useful)"
  "A prompt adapted from Zed (https://github.com/zed-industries/zed/blob/main/crates/git_ui/src/commit_message_prompt.txt).")

(defconst magit-llm-commit-prompt-conventional-commits
  "You are an expert at writing Git commits. Your job is to write a short clear commit message that summarizes the changes.

The commit message should be structured as follows:

    <type>(<optional scope>): <description>

    [optional body]

- Commits MUST be prefixed with a type, which consists of one of the followings words: build, chore, ci, docs, feat, fix, perf, refactor, style, test
- The type feat MUST be used when a commit adds a new feature
- The type fix MUST be used when a commit represents a bug fix
- An optional scope MAY be provided after a type. A scope is a phrase describing a section of the codebase enclosed in parenthesis, e.g., fix(parser):
- A description MUST immediately follow the type/scope prefix. The description is a short description of the code changes, e.g., fix: array parsing issue when multiple spaces were contained in string.
- Try to limit the whole subject line to 60 characters
- Capitalize the subject line
- Do not end the subject line with any punctuation
- A longer commit body MAY be provided after the short description, providing additional contextual information about the code changes. The body MUST begin one blank line after the description.
- Use the imperative mood in the subject line
- Keep the body short and concise (omit it entirely if not useful)"
  "A prompt adapted from Conventional Commits (https://www.conventionalcommits.org/en/v1.0.0/).")

(defcustom magit-llm-commit-commit-prompt
  magit-llm-commit-prompt-conventional-commits
  "The prompt to use for generating a commit message.
The prompt should consider that the input will be a diff of all
staged changes."
  :type 'string
  :group 'magit-llm-commit)

(defcustom magit-llm-commit-diff-explain-prompt
  "You are an expert at understanding and explaining code changes by reading diff output. Your job is to write a short clear summary explanation of the changes. Answer in Markdown format."
  "The prompt to use for explaining diff changes.
The prompt should consider that the input will be a diff of some changes."
  :type 'string
  :group 'magit-llm-commit)

(defcustom magit-llm-commit-api-url
  "https://api.openai.com/v1/chat/completions"
  "OpenAI-compatible API endpoint URL.

This URL should point to a chat completions endpoint that accepts
the standard OpenAI request format with a `messages' array.

Common values:
  - OpenAI:     https://api.openai.com/v1/chat/completions
  - DeepSeek:   https://api.deepseek.com/v1/chat/completions
  - OpenRouter: https://openrouter.ai/api/v1/chat/completions
  - Ollama:     http://localhost:11434/v1/chat/completions"
  :type 'string
  :group 'magit-llm-commit)

(defcustom magit-llm-commit-api-key nil
  "API key for the LLM service.

Can be either a string containing the key directly, or a function
that returns the key string.  Using a function is recommended for
security -- you can retrieve the key from `auth-source' or an
environment variable instead of storing it in your config.

Example function using an environment variable:
  (lambda () (getenv \"OPENAI_API_KEY\"))

Example using auth-source:
  (lambda ()
    (auth-source-pick-first-password :host \"api.openai.com\"))"
  :type '(choice (const :tag "None" nil)
                 (string :tag "API Key")
                 (function :tag "Function returning API key"))
  :group 'magit-llm-commit)

(defcustom magit-llm-commit-model "gpt-4.1-mini"
  "Model name for generating commit messages."
  :type 'string
  :group 'magit-llm-commit)

(defcustom magit-llm-commit-temperature 0.7
  "Temperature parameter for API requests.
Lower values produce more deterministic outputs."
  :type 'number
  :group 'magit-llm-commit)

(defcustom magit-llm-commit-timeout 60
  "Timeout in seconds for API requests.
If the API does not respond within this time, the request is cancelled."
  :type 'integer
  :group 'magit-llm-commit)

(defvar magit-llm-commit--spinner-timer nil
  "Timer for the progress spinner.")

(defvar magit-llm-commit--spinner-frame 0
  "Current frame index for the spinner animation.")

(defvar magit-llm-commit--spinner-frames ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Spinner animation frames.")

(defun magit-llm-commit--start-spinner (message-text)
  "Start a progress spinner with MESSAGE-TEXT."
  (setq magit-llm-commit--spinner-frame 0)
  (setq magit-llm-commit--spinner-timer
        (run-with-timer 0 0.1
                        (lambda ()
                          (message "%s %s" message-text
                                   (aref magit-llm-commit--spinner-frames
                                         magit-llm-commit--spinner-frame))
                          (setq magit-llm-commit--spinner-frame
                                (% (1+ magit-llm-commit--spinner-frame)
                                   (length magit-llm-commit--spinner-frames)))))))

(defun magit-llm-commit--stop-spinner ()
  "Stop the progress spinner."
  (when magit-llm-commit--spinner-timer
    (cancel-timer magit-llm-commit--spinner-timer)
    (setq magit-llm-commit--spinner-timer nil)))

(defun magit-llm-commit--resolve-api-key ()
  "Resolve `magit-llm-commit-api-key' to a string value.
If it is a function, call it; if it is a string, return it directly.
Signals an error if no key is configured."
  (cond
   ((functionp magit-llm-commit-api-key)
    (funcall magit-llm-commit-api-key))
   ((stringp magit-llm-commit-api-key)
    magit-llm-commit-api-key)
   (t
    (user-error "magit-llm-commit: No API key configured.  Set `magit-llm-commit-api-key'"))))

(defun magit-llm-commit--format-commit-message (message)
  "Format commit message MESSAGE nicely."
  (with-temp-buffer
    (insert message)
    (text-mode)
    (setq fill-column git-commit-summary-max-length)
    (fill-region (point-min) (point-max))
    (buffer-string)))

(defun magit-llm-commit--clean-response (response)
  "Clean LLM response by stripping markdown code fences and whitespace."
  (let ((cleaned (replace-regexp-in-string
                  "^```\\(commit\\)?[[:space:]]*\n?" "" response)))
    (setq cleaned (replace-regexp-in-string "\n?```$" "" cleaned))
    (string-trim cleaned)))

(defun magit-llm-commit--json-escape-non-ascii (string)
  "Escape non-ASCII characters in STRING as JSON \\uXXXX sequences.
Uses surrogate pairs for code points above U+FFFF.
This ensures the result is pure ASCII, which is required by
`url-http-create-request' to avoid multibyte text errors."
  (replace-regexp-in-string
   "[^[:ascii:]]"
   (lambda (match)
     (let ((cp (aref match 0)))
       (if (< cp #x10000)
           (format "\\u%04X" cp)
         (format "\\u%04X\\u%04X"
                 (+ #xD800 (/ (- cp #x10000) #x400))
                 (+ #xDC00 (% (- cp #x10000) #x400))))))
   string t t))

(defun magit-llm-commit--request (messages callback)
  "Send MESSAGES to the LLM API and call CALLBACK with the response.

MESSAGES should be a list of alists with `role' and `content' keys:
  (((role . \"system\") (content . \"...\"))
   ((role . \"user\")   (content . \"...\")))

CALLBACK is called with the response string on success, or nil on
error with a message displayed in the echo area."
  (let* ((api-key (magit-llm-commit--resolve-api-key))
         (url-request-method "POST")
         (url-request-extra-headers
          `(("Content-Type" . "application/json")
            ("Authorization" . ,(concat "Bearer " api-key))))
         (url-request-data
          (magit-llm-commit--json-escape-non-ascii
           (json-serialize
            `((model . ,magit-llm-commit-model)
              (temperature . ,magit-llm-commit-temperature)
              (messages . ,(vconcat
                            (mapcar
                             (lambda (m)
                               `((role . ,(cdr (assoc 'role m)))
                                 (content . ,(cdr (assoc 'content m)))))
                             messages)))))))
         (url-mime-accept-string "application/json"))
    (magit-llm-commit--start-spinner "magit-llm-commit: Requesting...")
    (condition-case err
        (let ((response-buffer (url-retrieve-synchronously
                                magit-llm-commit-api-url
                                nil nil magit-llm-commit-timeout)))
          (magit-llm-commit--stop-spinner)
          (when response-buffer
            (unwind-protect
                (with-current-buffer response-buffer
                  (goto-char (point-min))
                  (if (not (re-search-forward "\r?\n\r?\n" nil t))
                      (message "magit-llm-commit: No response body found")
                    (condition-case err
                        (let* ((json-data (json-parse-buffer :object-type 'alist))
                               (error-obj (alist-get 'error json-data)))
                          (if error-obj
                              (message "magit-llm-commit: API error: %s"
                                       (alist-get 'message error-obj))
                            (let* ((choices (alist-get 'choices json-data))
                                   (first-choice (and choices (length> choices 0)
                                                      (aref choices 0)))
                                   (message-obj (and first-choice
                                                     (alist-get 'message first-choice)))
                                   (content (and message-obj
                                                 (alist-get 'content message-obj))))
                              (if content
                                  (funcall callback content)
                                (message "magit-llm-commit: Unexpected response format")))))
                      (json-parse-error
                       (message "magit-llm-commit: Invalid JSON response from server"))
                      (error
                       (message "magit-llm-commit: Error processing response: %s"
                                (error-message-string err))))))
              (kill-buffer response-buffer))))
      (error
       (magit-llm-commit--stop-spinner)
       (message "magit-llm-commit: Request failed: %s"
                (error-message-string err))))))

(defun magit-llm-commit--generate (callback)
  "Generate a commit message for current magit repo.
Invokes CALLBACK with the generated message when done."
  (let ((diff (magit-git-output "diff" "--cached")))
    (if (string-blank-p diff)
        (user-error "magit-llm-commit: No staged changes found")
      (magit-llm-commit--request
       `(((role . "system") (content . ,magit-llm-commit-commit-prompt))
         ((role . "user") (content . ,(format "Generate a commit message for the following diff:\n\n%s" diff))))
       (lambda (response)
         (when response
           (funcall callback (magit-llm-commit--format-commit-message
                              (magit-llm-commit--clean-response response)))))))))

(defun magit-llm-commit-generate-message ()
  "Generate a commit message when in the git commit buffer."
  (interactive)
  (unless (magit-commit-message-buffer)
    (user-error "No commit in progress"))
  (magit-llm-commit--generate (lambda (message)
                                (with-current-buffer (magit-commit-message-buffer)
                                  (save-excursion
                                    (goto-char (point-min))
                                    (insert message)))
                                (message "magit-llm-commit: Commit message generated"))))

(defun magit-llm-commit-commit-generate (&optional args)
  "Create a new commit with a generated commit message.
Uses ARGS from transient mode."
  (interactive (list (magit-commit-arguments)))
  (magit-llm-commit--generate
   (lambda (message)
     (magit-commit-create (append args `("--message" ,message "--edit")))
     (message "magit-llm-commit: Commit generated"))))

(defun magit-llm-commit--show-diff-explain (text)
  "Popup a buffer with diff explanation TEXT."
  (let ((buffer-name "*magit-llm-commit diff-explain*"))
    (when-let ((existing-buffer (get-buffer buffer-name)))
      (kill-buffer existing-buffer))
    (let ((buffer (get-buffer-create buffer-name)))
      (with-current-buffer buffer
        (insert text)
        (setq fill-column 72)
        (fill-region (point-min) (point-max))
        (if (fboundp 'markdown-view-mode)
            (markdown-view-mode)
          (text-mode)
          (message "magit-llm-commit: Install markdown-mode for better formatting"))
        (goto-char (point-min)))
      (pop-to-buffer buffer))))

(defun magit-llm-commit--do-diff-request (diff)
  "Send request for an explanation of DIFF."
  (magit-llm-commit--request
   `(((role . "system") (content . ,magit-llm-commit-diff-explain-prompt))
     ((role . "user") (content . ,(format "Explain the following diff:\n\n%s" diff))))
   (lambda (response)
     (when response
       (magit-llm-commit--show-diff-explain response)
       (message "magit-llm-commit: Diff explained")))))

(defun magit-llm-commit-diff-explain ()
  "Ask for an explanation of diff at current section."
  (interactive)
  (when-let* ((section (magit-current-section))
              (start (oref section content))
              (end (oref section end))
              (content (buffer-substring start end)))
    (magit-llm-commit--do-diff-request content)))

;;;###autoload
(defun magit-llm-commit-install ()
  "Install magit-llm-commit functionality."
  (define-key git-commit-mode-map (kbd "C-c g") 'magit-llm-commit-generate-message)
  (transient-append-suffix 'magit-commit #'magit-commit-create
    '("g" "Generate commit" magit-llm-commit-commit-generate))
  (transient-append-suffix 'magit-diff #'magit-stash-show
    '("x" "Explain" magit-llm-commit-diff-explain)))

(provide 'magit-llm-commit)
;;; magit-llm-commit.el ends here
