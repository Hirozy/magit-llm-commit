;;; magit-llm-commit-test.el --- Tests for magit-llm-commit -*- lexical-binding: t; -*-

;;; Commentary:

;; Run tests with:
;;   emacs --batch -l ert -L test -L . -l magit-llm-commit-test -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
;; Load mock before magit-llm-commit so (require 'magit) succeeds
(require 'magit-mock)
(require 'magit-llm-commit)

;; ===========================================================================
;; magit-llm-commit--json-escape-non-ascii
;; ===========================================================================

(ert-deftest magit-llm-commit-test/escape-empty-string ()
  "Empty string should pass through unchanged."
  (should (equal (magit-llm-commit--json-escape-non-ascii "") "")))

(ert-deftest magit-llm-commit-test/escape-ascii-unchanged ()
  "Pure ASCII strings should pass through unchanged."
  (should (equal (magit-llm-commit--json-escape-non-ascii "hello world")
                 "hello world"))
  (should (equal (magit-llm-commit--json-escape-non-ascii "abc 123 !@#")
                 "abc 123 !@#"))
  (should (equal (magit-llm-commit--json-escape-non-ascii "fix: update parser")
                 "fix: update parser")))

(ert-deftest magit-llm-commit-test/escape-ascii-control-chars ()
  "ASCII control characters (newline, tab) should pass through."
  (should (equal (magit-llm-commit--json-escape-non-ascii "line1\nline2")
                 "line1\nline2"))
  (should (equal (magit-llm-commit--json-escape-non-ascii "col1\tcol2")
                 "col1\tcol2"))
  (should (equal (magit-llm-commit--json-escape-non-ascii "a\rb")
                 "a\rb")))

(ert-deftest magit-llm-commit-test/escape-chinese ()
  "Chinese characters should be escaped as \\uXXXX."
  (should (equal (magit-llm-commit--json-escape-non-ascii "你好")
                 "\\u4F60\\u597D"))
  (should (equal (magit-llm-commit--json-escape-non-ascii "hello你好world")
                 "hello\\u4F60\\u597Dworld")))

(ert-deftest magit-llm-commit-test/escape-japanese ()
  "Japanese characters should be escaped correctly."
  (should (equal (magit-llm-commit--json-escape-non-ascii "こんにちは")
                 "\\u3053\\u3093\\u306B\\u3061\\u306F")))

(ert-deftest magit-llm-commit-test/escape-korean ()
  "Korean characters should be escaped correctly."
  ;; 안녕하세요
  (should (equal (magit-llm-commit--json-escape-non-ascii "안녕하세요")
                 "\\uC548\\uB155\\uD558\\uC138\\uC694")))

(ert-deftest magit-llm-commit-test/escape-cyrillic ()
  "Cyrillic characters should be escaped correctly."
  ;; Привет - format uses %04X (uppercase hex)
  (should (equal (magit-llm-commit--json-escape-non-ascii "Привет")
                 "\\u041F\\u0440\\u0438\\u0432\\u0435\\u0442")))

(ert-deftest magit-llm-commit-test/escape-accented-latin ()
  "Accented Latin characters should be escaped."
  (should (equal (magit-llm-commit--json-escape-non-ascii "café")
                 "caf\\u00E9"))
  (should (equal (magit-llm-commit--json-escape-non-ascii "naïve")
                 "na\\u00EFve"))
  (should (equal (magit-llm-commit--json-escape-non-ascii "über")
                 "\\u00FCber")))

(ert-deftest magit-llm-commit-test/escape-mixed-content ()
  "Mixed ASCII and non-ASCII should escape only non-ASCII parts."
  (should (equal (magit-llm-commit--json-escape-non-ascii "fix: 修复 bug")
                 "fix: \\u4FEE\\u590D bug"))
  (should (equal (magit-llm-commit--json-escape-non-ascii "feat(模块): add feature")
                 "feat(\\u6A21\\u5757): add feature")))

(ert-deftest magit-llm-commit-test/escape-supplementary-planes ()
  "Characters above U+FFFF should use surrogate pairs."
  ;; U+1F600 (grinning face)
  (should (equal (magit-llm-commit--json-escape-non-ascii "\U0001F600")
                 "\\uD83D\\uDE00"))
  ;; U+1F4A9 (pile of poo)
  (should (equal (magit-llm-commit--json-escape-non-ascii "\U0001F4A9")
                 "\\uD83D\\uDCA9"))
  ;; Multiple emoji mixed with ASCII
  (should (equal (magit-llm-commit--json-escape-non-ascii "hi \U0001F600 bye")
                 "hi \\uD83D\\uDE00 bye")))

(ert-deftest magit-llm-commit-test/escape-single-non-ascii ()
  "A single non-ASCII character should be escaped."
  (should (equal (magit-llm-commit--json-escape-non-ascii "中")
                 "\\u4E2D")))

(ert-deftest magit-llm-commit-test/escape-all-non-ascii ()
  "A string of only non-ASCII characters."
  (should (equal (magit-llm-commit--json-escape-non-ascii "中文测试")
                 "\\u4E2D\\u6587\\u6D4B\\u8BD5")))

(ert-deftest magit-llm-commit-test/escape-result-is-ascii ()
  "Result should always be pure ASCII (string-bytes == length)."
  (let* ((input "Hello 世界! café résumé naïve \U0001F600")
         (result (magit-llm-commit--json-escape-non-ascii input)))
    (should (= (string-bytes result) (length result)))))

;; ===========================================================================
;; magit-llm-commit--clean-response
;; ===========================================================================

(ert-deftest magit-llm-commit-test/clean-empty-string ()
  "Empty string should return empty."
  (should (equal (magit-llm-commit--clean-response "") "")))

(ert-deftest magit-llm-commit-test/clean-only-whitespace ()
  "Whitespace-only string should return empty."
  (should (equal (magit-llm-commit--clean-response "   ") ""))
  (should (equal (magit-llm-commit--clean-response "\n\n") ""))
  (should (equal (magit-llm-commit--clean-response "  \n  \n  ") "")))

(ert-deftest magit-llm-commit-test/clean-plain-text ()
  "Plain text without fences should be trimmed only."
  (should (equal (magit-llm-commit--clean-response "  fix: update parser  ")
                 "fix: update parser"))
  (should (equal (magit-llm-commit--clean-response "fix: update parser")
                 "fix: update parser")))

(ert-deftest magit-llm-commit-test/clean-code-fence ()
  "Markdown code fences should be stripped."
  (should (equal (magit-llm-commit--clean-response "```\nfix: update parser\n```")
                 "fix: update parser")))

(ert-deftest magit-llm-commit-test/clean-commit-fence ()
  "Code fences with 'commit' language tag should be stripped."
  (should (equal (magit-llm-commit--clean-response "```commit\nfix: update parser\n```")
                 "fix: update parser")))

(ert-deftest magit-llm-commit-test/clean-other-language-fence ()
  "Code fences with non-commit language tags should keep the tag as content."
  ;; ```json should NOT be stripped — only bare ``` and ```commit are handled
  (let ((result (magit-llm-commit--clean-response "```json\n{\"key\": \"val\"}\n```")))
    (should (string-match-p "json" result))))

(ert-deftest magit-llm-commit-test/clean-fence-with-extra-spaces ()
  "Code fences with trailing spaces after backticks should be handled."
  (should (equal (magit-llm-commit--clean-response "```  \nfix: bug\n```")
                 "fix: bug")))

(ert-deftest magit-llm-commit-test/clean-only-opening-fence ()
  "Only an opening fence should be stripped, leaving the rest."
  (should (equal (magit-llm-commit--clean-response "```\nfix: update parser")
                 "fix: update parser")))

(ert-deftest magit-llm-commit-test/clean-only-closing-fence ()
  "Only a closing fence should be stripped."
  (should (equal (magit-llm-commit--clean-response "fix: update parser\n```")
                 "fix: update parser")))

(ert-deftest magit-llm-commit-test/clean-multiline-body ()
  "Multi-line commit messages should preserve body content."
  (let ((input "```\nfeat: add login\n\nAdd OAuth2 login flow.\n```"))
    (should (equal (magit-llm-commit--clean-response input)
                   "feat: add login\n\nAdd OAuth2 login flow."))))

(ert-deftest magit-llm-commit-test/clean-trailing-whitespace ()
  "Trailing whitespace should be trimmed."
  (should (equal (magit-llm-commit--clean-response "fix: bug\n\n  ")
                 "fix: bug")))

(ert-deftest magit-llm-commit-test/clean-leading-whitespace ()
  "Leading whitespace should be trimmed."
  (should (equal (magit-llm-commit--clean-response "   \nfix: bug")
                 "fix: bug")))

(ert-deftest magit-llm-commit-test/clean-crlf-line-endings ()
  "CRLF line endings should be handled."
  (should (equal (magit-llm-commit--clean-response "fix: bug\r\n\r\nDetails")
                 "fix: bug\r\n\r\nDetails")))

(ert-deftest magit-llm-commit-test/clean-fence-with-crlf ()
  "Fences with CRLF line endings should be stripped."
  (should (equal (magit-llm-commit--clean-response "```\r\nfix: bug\r\n```")
                 "fix: bug")))

(ert-deftest magit-llm-commit-test/clean-conventional-commit-format ()
  "Typical conventional commit output should be cleaned properly."
  (let ((input "```commit\nfeat(auth): add OAuth2 support\n\nImplement Google and GitHub OAuth2 providers.\n```"))
    (should (equal (magit-llm-commit--clean-response input)
                   "feat(auth): add OAuth2 support\n\nImplement Google and GitHub OAuth2 providers."))))

(ert-deftest magit-llm-commit-test/clean-no-fence-no-trim-needed ()
  "Already clean text should pass through unchanged."
  (should (equal (magit-llm-commit--clean-response "fix: update parser")
                 "fix: update parser")))

;; ===========================================================================
;; magit-llm-commit--resolve-api-key
;; ===========================================================================

(ert-deftest magit-llm-commit-test/resolve-key-string ()
  "A string api-key should be returned as-is."
  (let ((magit-llm-commit-api-key "sk-test-123"))
    (should (equal (magit-llm-commit--resolve-api-key) "sk-test-123"))))

(ert-deftest magit-llm-commit-test/resolve-key-empty-string ()
  "An empty string api-key is a valid string and should be returned."
  (let ((magit-llm-commit-api-key ""))
    (should (equal (magit-llm-commit--resolve-api-key) ""))))

(ert-deftest magit-llm-commit-test/resolve-key-function ()
  "A function api-key should be called and its result returned."
  (let ((magit-llm-commit-api-key (lambda () "sk-from-func")))
    (should (equal (magit-llm-commit--resolve-api-key) "sk-from-func"))))

(ert-deftest magit-llm-commit-test/resolve-key-function-empty ()
  "A function returning empty string should work."
  (let ((magit-llm-commit-api-key (lambda () "")))
    (should (equal (magit-llm-commit--resolve-api-key) ""))))

(ert-deftest magit-llm-commit-test/resolve-key-function-env ()
  "A function reading from environment should work."
  (let ((process-environment (cons "TEST_API_KEY=sk-env-123" process-environment))
        (magit-llm-commit-api-key (lambda () (getenv "TEST_API_KEY"))))
    (should (equal (magit-llm-commit--resolve-api-key) "sk-env-123"))))

(ert-deftest magit-llm-commit-test/resolve-key-nil ()
  "A nil api-key should signal a user-error."
  (let ((magit-llm-commit-api-key nil))
    (should-error (magit-llm-commit--resolve-api-key) :type 'user-error)))

(ert-deftest magit-llm-commit-test/resolve-key-function-error-propagates ()
  "If the key function signals an error, it should propagate."
  (let ((magit-llm-commit-api-key (lambda () (error "auth failed"))))
    (should-error (magit-llm-commit--resolve-api-key) :type 'error)))

(ert-deftest magit-llm-commit-test/resolve-key-symbol-not-function ()
  "A non-nil, non-string, non-function value should signal a user-error."
  (let ((magit-llm-commit-api-key 'some-symbol))
    (should-error (magit-llm-commit--resolve-api-key) :type 'user-error)))

(ert-deftest magit-llm-commit-test/resolve-key-integer ()
  "An integer api-key value should signal a user-error."
  (let ((magit-llm-commit-api-key 42))
    (should-error (magit-llm-commit--resolve-api-key) :type 'user-error)))

;; ===========================================================================
;; magit-llm-commit--format-commit-message
;; ===========================================================================

(ert-deftest magit-llm-commit-test/format-message-short ()
  "A short message should be returned unchanged."
  (let ((git-commit-summary-max-length 50))
    (should (equal (magit-llm-commit--format-commit-message "fix: update parser")
                   "fix: update parser"))))

(ert-deftest magit-llm-commit-test/format-message-with-body ()
  "A message with body should preserve the blank line separator."
  (let ((git-commit-summary-max-length 50))
    (let ((result (magit-llm-commit--format-commit-message
                   "feat: add login\n\nAdd OAuth2 login flow.")))
      (should (string-match-p "^feat: add login" result))
      (should (string-match-p "Add OAuth2" result)))))

(ert-deftest magit-llm-commit-test/format-message-single-word ()
  "A single word should pass through."
  (let ((git-commit-summary-max-length 50))
    (should (equal (magit-llm-commit--format-commit-message "update")
                   "update"))))

(ert-deftest magit-llm-commit-test/format-message-long-line-wraps ()
  "A line exceeding fill-column should be wrapped."
  (let ((git-commit-summary-max-length 20))
    (let ((result (magit-llm-commit--format-commit-message
                   "fix: this is a very long commit message that exceeds the limit")))
      (should (string-match-p "\n" result)))))

(ert-deftest magit-llm-commit-test/format-message-exact-limit ()
  "A message exactly at the limit should not wrap."
  (let ((git-commit-summary-max-length 18))
    (should (equal (magit-llm-commit--format-commit-message "fix: update parser")
                   "fix: update parser"))))

(ert-deftest magit-llm-commit-test/format-message-conventional-commit ()
  "Conventional commit format should be handled correctly."
  (let ((git-commit-summary-max-length 50))
    (let ((result (magit-llm-commit--format-commit-message
                   "feat(api): add new endpoint\n\nThis adds a REST endpoint for user management.")))
      (should (string-match-p "^feat(api): add new endpoint" result))
      (should (string-match-p "REST endpoint" result)))))

;; ===========================================================================
;; Custom variables (defcustom)
;; ===========================================================================

(ert-deftest magit-llm-commit-test/custom-vars-exist ()
  "All custom variables should be defined."
  (should (boundp 'magit-llm-commit-api-url))
  (should (boundp 'magit-llm-commit-api-key))
  (should (boundp 'magit-llm-commit-model))
  (should (boundp 'magit-llm-commit-temperature))
  (should (boundp 'magit-llm-commit-commit-prompt))
  (should (boundp 'magit-llm-commit-diff-explain-prompt)))

(ert-deftest magit-llm-commit-test/custom-var-defaults ()
  "Custom variables should have sensible defaults."
  (should (stringp magit-llm-commit-api-url))
  (should (string-match-p "http" magit-llm-commit-api-url))
  (should (stringp magit-llm-commit-model))
  (should (> (length magit-llm-commit-model) 0))
  (should (numberp magit-llm-commit-temperature))
  (should (>= magit-llm-commit-temperature 0))
  (should (<= magit-llm-commit-temperature 2)))

(ert-deftest magit-llm-commit-test/custom-var-api-key-default-nil ()
  "API key should default to nil."
  ;; We need to check the standard value, not the current one
  ;; which might have been modified by other tests
  (should (null (default-value 'magit-llm-commit-api-key))))

;; ===========================================================================
;; Prompt constants
;; ===========================================================================

(ert-deftest magit-llm-commit-test/prompts-are-strings ()
  "Prompt constants should be non-empty strings."
  (should (stringp magit-llm-commit-prompt-zed))
  (should (> (length magit-llm-commit-prompt-zed) 0))
  (should (stringp magit-llm-commit-prompt-conventional-commits))
  (should (> (length magit-llm-commit-prompt-conventional-commits) 0)))

(ert-deftest magit-llm-commit-test/prompts-mention-git ()
  "Prompts should mention Git or commit to provide context."
  (should (string-match-p "[Gg]it\\|[Cc]ommit" magit-llm-commit-prompt-zed))
  (should (string-match-p "[Gg]it\\|[Cc]ommit"
                          magit-llm-commit-prompt-conventional-commits)))

(ert-deftest magit-llm-commit-test/prompt-conventional-has-types ()
  "Conventional commits prompt should list commit types."
  (should (string-match-p "feat" magit-llm-commit-prompt-conventional-commits))
  (should (string-match-p "fix" magit-llm-commit-prompt-conventional-commits))
  (should (string-match-p "refactor" magit-llm-commit-prompt-conventional-commits)))

(ert-deftest magit-llm-commit-test/default-commit-prompt-is-conventional ()
  "Default commit prompt should be the conventional commits prompt."
  (should (equal (default-value 'magit-llm-commit-commit-prompt)
                 magit-llm-commit-prompt-conventional-commits)))

(ert-deftest magit-llm-commit-test/diff-explain-prompt-mentions-markdown ()
  "Diff explain prompt should request Markdown output."
  (should (string-match-p "[Mm]arkdown" magit-llm-commit-diff-explain-prompt)))

;; ===========================================================================
;; Functions are defined
;; ===========================================================================

(ert-deftest magit-llm-commit-test/functions-are-defined ()
  "All expected functions should be defined."
  (should (fboundp 'magit-llm-commit--resolve-api-key))
  (should (fboundp 'magit-llm-commit--format-commit-message))
  (should (fboundp 'magit-llm-commit--clean-response))
  (should (fboundp 'magit-llm-commit--json-escape-non-ascii))
  (should (fboundp 'magit-llm-commit--request))
  (should (fboundp 'magit-llm-commit--generate))
  (should (fboundp 'magit-llm-commit-generate-message))
  (should (fboundp 'magit-llm-commit-commit-generate))
  (should (fboundp 'magit-llm-commit--show-diff-explain))
  (should (fboundp 'magit-llm-commit--do-diff-request))
  (should (fboundp 'magit-llm-commit-diff-explain))
  (should (fboundp 'magit-llm-commit-install)))

(ert-deftest magit-llm-commit-test/interactive-functions ()
  "User-facing commands should be interactive."
  (should (commandp 'magit-llm-commit-generate-message))
  (should (commandp 'magit-llm-commit-commit-generate))
  (should (commandp 'magit-llm-commit-diff-explain)))

;; ===========================================================================
;; Diff explain with markdown-mode fallback
;; ===========================================================================

(ert-deftest magit-llm-commit-test/show-diff-explain-without-markdown ()
  "Should fall back to text-mode when markdown-view-mode is not available."
  (let ((test-text "# Test\n\nThis is a test.")
        (markdown-available (fboundp 'markdown-view-mode)))
    ;; Temporarily remove markdown-view-mode if it exists
    (when markdown-available
      (fmakunbound 'markdown-view-mode))
    (unwind-protect
        (progn
          (magit-llm-commit--show-diff-explain test-text)
          (let ((buf (get-buffer "*magit-llm-commit diff-explain*")))
            (should buf)
            (with-current-buffer buf
              ;; Should be in text-mode
              (should (eq major-mode 'text-mode))
              ;; Content should be present
              (should (string-match-p "Test" (buffer-string))))))
      ;; Restore markdown-view-mode if it was available
      (when markdown-available
        (require 'markdown-mode nil t)))))

(ert-deftest magit-llm-commit-test/show-diff-explain-with-markdown ()
  "Should use markdown-view-mode when available."
  (let ((test-text "# Test\n\nThis is a test."))
    (magit-llm-commit--show-diff-explain test-text)
    (let ((buf (get-buffer "*magit-llm-commit diff-explain*")))
      (should buf)
      (with-current-buffer buf
        ;; Should be in markdown-view-mode
        (should (eq major-mode 'markdown-view-mode))
        ;; Content should be present
        (should (string-match-p "Test" (buffer-string)))))))

;; ===========================================================================
;; Timeout and spinner
;; ===========================================================================

(ert-deftest magit-llm-commit-test/timeout-custom-exists ()
  "Timeout custom variable should be defined."
  (should (boundp 'magit-llm-commit-timeout))
  (should (integerp magit-llm-commit-timeout))
  (should (> magit-llm-commit-timeout 0)))

(ert-deftest magit-llm-commit-test/timeout-default-value ()
  "Timeout should have a reasonable default value."
  (should (eq (default-value 'magit-llm-commit-timeout) 60)))

(ert-deftest magit-llm-commit-test/spinner-frames-exist ()
  "Spinner frames should be defined and non-empty."
  (should (boundp 'magit-llm-commit--spinner-frames))
  (should (vectorp magit-llm-commit--spinner-frames))
  (should (> (length magit-llm-commit--spinner-frames) 0)))

(ert-deftest magit-llm-commit-test/start-spinner ()
  "Starting spinner should create a timer."
  (magit-llm-commit--start-spinner "Testing")
  (should (timerp magit-llm-commit--spinner-timer))
  (magit-llm-commit--stop-spinner))

(ert-deftest magit-llm-commit-test/stop-spinner ()
  "Stopping spinner should cancel the timer."
  (magit-llm-commit--start-spinner "Testing")
  (magit-llm-commit--stop-spinner)
  (should (null magit-llm-commit--spinner-timer)))

(ert-deftest magit-llm-commit-test/spinner-advances ()
  "Spinner frame should advance when timer fires."
  (let ((initial-frame magit-llm-commit--spinner-frame))
    (magit-llm-commit--start-spinner "Testing")
    (sleep-for 0.2)  ; Wait for timer to fire
    (should (not (eq magit-llm-commit--spinner-frame initial-frame)))
    (magit-llm-commit--stop-spinner)))

;; ===========================================================================
;; Feature provide
;; ===========================================================================

(ert-deftest magit-llm-commit-test/feature-provided ()
  "The feature should be provided."
  (should (featurep 'magit-llm-commit)))

;; ===========================================================================
;; Integration: escape then JSON round-trip
;; ===========================================================================

(ert-deftest magit-llm-commit-test/escape-produces-valid-json-string ()
  "Escaped string should produce valid JSON when serialized."
  (let* ((original "Hello 世界! café")
         (escaped (magit-llm-commit--json-escape-non-ascii original))
         (json-str (json-serialize `((content . ,escaped)))))
    ;; Should be valid JSON
    (should (stringp json-str))
    ;; Should be pure ASCII
    (should (= (string-bytes json-str) (length json-str)))
    ;; Should parse without error
    (should (json-parse-string json-str :object-type 'alist))))

(ert-deftest magit-llm-commit-test/escape-preserves-ascii-in-json ()
  "ASCII parts should survive JSON serialization unchanged."
  (let* ((original "fix: update parser")
         (escaped (magit-llm-commit--json-escape-non-ascii original))
         (json-str (json-serialize `((content . ,escaped))))
         (parsed (json-parse-string json-str :object-type 'alist))
         (content (alist-get 'content parsed)))
    (should (equal content original))))

(ert-deftest magit-llm-commit-test/escape-json-structure ()
  "Escaped content should produce correct JSON structure for API."
  (let* ((original "测试")
         (escaped (magit-llm-commit--json-escape-non-ascii original))
         (json-str (json-serialize `((messages . [((role . "user") (content . ,escaped))])))))
    ;; Should contain the escaped sequences
    (should (string-match-p "\\\\u[0-9A-F]\\{4\\}" json-str))
    ;; Should be valid JSON
    (should (json-parse-string json-str :object-type 'alist))))

(provide 'magit-llm-commit-test)
;;; magit-llm-commit-test.el ends here