;;; owl.el --- Major mode for the Owl programming language -*- lexical-binding: t; -*-

;; Copyright (C) 2026 D. Neumann
;; Author: D. Neumann
;; URL: https://github.com/dneumann/ellipse
;; Version: 0.1
;; Package-Requires: ((emacs "26.1"))
;; Keywords: languages, owl

;;; Commentary:

;; A major mode for Owl source files (``*.owl''), the language of the
;; Ellipse system (https://github.com/dneumann/ellipse).  It provides
;;
;;  - syntax highlighting of forms, operators, definitions, fields,
;;    strings and numbers,
;;  - `;' comments,
;;  - indentation driven by the blocks opened with a trailing `:'
;;    (see below),
;;  - Imenu support for `fun', `command' and `dynamic-command'
;;    definitions,
;;  - navigation between definitions with `M-a' and `M-e'.
;;
;; Indentation: Owl delimits blocks by indentation alone, so a line
;; that follows a deeper block can either continue it or close it.
;; `owl-indent-line' replays the blocks of the enclosing item: it
;; indents past a line that opens a block (one ending in `:') and
;; otherwise leaves a column alone when it already sits at a level of
;; an open block (a deliberate dedent stays).  C-u TAB re-derives the
;; column from the block structure.
;;
;; Install: put this file on your `load-path' and add
;;
;;     (require 'owl)
;;
;; to your init file.  Files ending in `.owl' then open in `owl-mode'
;; automatically.

;;; Code:

(defgroup owl nil
  "Major mode for editing Owl programs."
  :group 'languages
  :prefix "owl-")

(defcustom owl-indent-width 4
  "Indentation width of a block line after a line ending in `:'."
  :type 'integer
  :group 'owl)

(defvar owl-mode-syntax-table
  (let ((table (make-syntax-table)))
    ;; `;' starts a comment that runs to end of line.
    (modify-syntax-entry ?\; "< b" table)
    (modify-syntax-entry ?\n "> b" table)
    ;; Strings have no escape characters in Owl.
    (modify-syntax-entry ?\" "\"\"" table)
    (modify-syntax-entry ?\\ "." table)
    ;; Parentheses delimit calls.
    (modify-syntax-entry ?\( "()" table)
    (modify-syntax-entry ?\) ")(" table)
    ;; `-' is part of identifiers (`pop-front'), the lexer's delimiters
    ;; are only whitespace, parens, colon, equals, quote, semicolon and
    ;; the dot inside numbers.
    (modify-syntax-entry ?- "w" table)
    (modify-syntax-entry ?. "." table)
    (modify-syntax-entry ?: "." table)
    (modify-syntax-entry ?= "." table)
    (modify-syntax-entry ?< "." table)
    (modify-syntax-entry ?> "." table)
    (modify-syntax-entry ?* "." table)
    (modify-syntax-entry ?/ "." table)
    (modify-syntax-entry ?+ "." table)
    table)
  "Syntax table for `owl-mode'.")

(defconst owl-mode--keywords
  '("fun" "command" "dynamic-command" "lambda" "λ" "use"
    "if" "when" "unless" "while" "cond" "do"
    "set" "try" "bind" "with" "quote" "eval")
  "Syntactic forms of Owl.")

(defconst owl-mode--constants
  '("true" "false" "nothing")
  "Constant words of Owl.")

(defconst owl-mode--operators
  '("=" "<>" "<" ">" "+" "-" "*" "/")
  "Operator words of Owl.")

(defconst owl-mode--builtins
  '("echo" "print" "error" "readline" "read-file" "write-file"
    "file-exists" "current-dir" "is-terminal" "newline"
    "concat" "length" "to-string" "char" "code" "type-of"
    "and" "or" "not" "min" "max" "first" "find" "index" "slice"
    "pair" "field" "append" "prepend" "insert" "pop" "pop-front"
    "is-any" "is-empty" "is-nothing"
    "starts-with" "ends-with" "drop" "take"
    "floor" "new-scope" "syntax-form" "syntax-scope"
    "open-project" "project-modules" "module-file" "load-module"
    "source-items" "select-item" "add-item" "update-item" "put-item"
    "remove-item" "new-project" "run-file")
  "Builtin commands and functions of the standard libraries.")

(defun owl-mode--word-regexp (words)
  "Build a regexp matching one whole word out of WORDS."
  (concat "\\b\\("
          (mapconcat #'regexp-quote words "\\|")
          "\\)\\b"))

(defconst owl-font-lock-keywords
  (list
   ;; Definitions: the name after fun / command / dynamic-command.
   (list "\\<\\(fun\\|command\\|dynamic-command\\|lambda\\)\\s-+\\([a-zA-Z0-9_-]+\\)"
         '(1 'font-lock-keyword-face)
         '(2 'font-lock-function-name-face))
   ;; The colon that opens a block, at end of line.
   (list "^.*\\(:\\)\\s-*\\(?:;.*\\)?$" '(1 'font-lock-keyword-face))
   ;; Syntactic forms.
   (list (owl-mode--word-regexp owl-mode--keywords)
          '(1 'font-lock-keyword-face))
   ;; Constants.
   (list (owl-mode--word-regexp owl-mode--constants)
          '(1 'font-lock-constant-face))
   ;; Operators, as standalone words.
   (list (concat "\\(?:^\\|\\s-\\|\\s(\\)\\("
                 (mapconcat #'regexp-quote owl-mode--operators "\\|")
                 "\\)\\(?:\\s-\\|$\\|\\s)\\)")
          '(1 'owl-operator-face))
   ;; Builtins.
   (list (owl-mode--word-regexp owl-mode--builtins)
          '(1 'font-lock-builtin-face))
   ;; Numbers, including decimals and signed literals.
   (list "\\b\\([-+]?[0-9]+\\(?:\\.[0-9]+\\)?\\)\\b" '(1 'font-lock-constant-face))
   ;; Field access: the word after a dot.
   (list "\\w\\.\\([a-zA-Z][a-zA-Z0-9_-]*\\)" '(1 'font-lock-variable-name-face)))
  "Default highlighting for `owl-mode'.")

(defvar owl-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map prog-mode-map)
    map)
  "Keymap for `owl-mode'.")

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.owl\\'" . owl-mode))

(defface owl-operator-face
  '((t :inherit font-lock-type-face))
  "Face for Owl operator words (`=', `<>', `<', `>', `+', `-', ...)."
  :group 'owl)

(defun owl--propertize-line ()
  "Give explicit syntax properties to the quotes of the line at point.
Owl strings never span lines and have no escapes, and a `;' outside a
string starts a comment to the end of the line, exactly like the lexer.
Quotes in the code part of the line alternate as string delimiters;
quotes inside the comment part are plain punctuation."
  (save-excursion
    (let ((line-end (line-end-position))
          (in-string nil))
      (while (and (< (point) line-end)
                  (not (and (not in-string) (= ?\; (char-after)))))
        (when (= ?\" (char-after))
          (put-text-property (point) (1+ (point)) 'syntax-table
                             (string-to-syntax "\""))
          (setq in-string (not in-string)))
        (forward-char 1))
      ;; Quotes in the comment part are plain punctuation.
      (skip-chars-forward "^\"" line-end)
      (while (re-search-forward "\"" line-end t)
        (put-text-property (match-beginning 0) (match-end 0)
                           'syntax-table (string-to-syntax "."))))))

(defun owl--syntax-propertize (begin end)
  "Propertize all lines overlapping the region from BEGIN to END."
  (save-excursion
    (goto-char begin)
    (beginning-of-line)
    (while (< (point) end)
      (owl--propertize-line)
      (forward-line 1))))

(defconst owl-defun-regexp
  "^[ \t]*\\(fun\\|command\\|dynamic-command\\)\\s-+\\([a-zA-Z0-9_-]+\\)"
  "Regexp matching the first line of an Owl definition.")

(defconst owl--definition-regexp
  "\\(fun\\|command\\|dynamic-command\\)\\s-"
  "Regexp matching the start of a definition line (after its indent).")

(defun owl--matching-open-column ()
  "Column of the open parenthesis enclosing the current line, if any."
  (save-excursion
    (condition-case nil
        (progn (backward-up-list) (current-column))
      (scan-error nil))))

(defun owl--definition-start-indent ()
  "Return the column a fresh definition line should start at, or nil.
Owl files put top-level definitions in the first column, and a nested
definition either sits directly after code or under its own comment.
So after a blank line the column is 0; after comment lines the column
is theirs; directly after a code line the definition continues the
current level, which this returns nil for."
  (save-excursion
    (beginning-of-line)
    (let ((blank nil)
          (comment-at nil)
          (code nil))
      (while (and (not blank)
                  (not code)
                  (zerop (forward-line -1)))
        (skip-chars-forward " \t")
        (cond
         ((eolp) (setq blank t))
         ((eq ?\; (char-after))
          (unless comment-at (setq comment-at (current-column))))
         (t (setq code t))))
      (cond
       (blank 0)
       (code comment-at)
       (comment-at comment-at)
       (t 0)))))

(defun owl--item-start ()
  "Start of the enclosing top-level item: the closest code line before
point indented at column 0, else the beginning of the buffer."
  (save-excursion
    (let (found)
      (while (and (not found) (zerop (forward-line -1)))
        (skip-chars-forward " \t")
        (when (and (not (eolp))
                   (not (eq ?\; (char-after)))
                   (= (current-column) 0))
          (setq found (point))))
      (or found (point-min)))))

(defun owl--block-info ()
  "Replay the enclosing item and return (TARGET . VALID).
TARGET is the indent implied by the blocks still open before this line;
VALID lists the columns this line may legally keep: the body and header
indent of every open block plus column 0.  Owl blocks are delimited by
indentation alone, so a line that follows a deeper block can either
continue it or close it; only the author knows which, and a legal
column is left as typed."
  (save-excursion
    (beginning-of-line)
    (let ((cur (line-beginning-position))
          (stack)            ; ((HEADER . BODY) ...), innermost first
          (last-colon nil)
          (last-indent nil))
      (goto-char (owl--item-start))
      (while (< (line-beginning-position) cur)
        (skip-chars-forward " \t")
        (unless (or (eolp) (eq ?\; (char-after)))
          (let ((indent (current-column))
                (colon (save-excursion
                         (end-of-line)
                         (skip-chars-backward " \t")
                         (eq ?: (char-before)))))
            (setq last-colon colon last-indent indent)
            ;; Close the blocks this line dedents out of.
            (while (and stack (< indent (cdar stack)))
              (setq stack (cdr stack)))
            (cond
             ((null stack)
              (when colon
                (push (cons indent (+ indent owl-indent-width)) stack)))
             ((= indent (cdar stack))
              (when colon
                (push (cons indent (+ indent owl-indent-width)) stack)))
             ((> indent (cdar stack))
              ;; A deeper line: its own block, or body of a fresh one.
              (when colon
                (push (cons indent (+ indent owl-indent-width)) stack)))
             (t nil))))
        (forward-line 1))
      (cons
       (if last-colon
           (+ last-indent owl-indent-width)
         (if stack (cdar stack) 0))
       (append '(0)
               (mapcar (lambda (e) (car e)) stack)
               (mapcar (lambda (e) (cdr e)) stack))))))

(defun owl-indent-line ()
  "Indent the current line of an Owl buffer."
  (interactive)
  (let ((target
         (save-excursion
           (beginning-of-line)
           (skip-chars-forward " \t")
           (let ((ppss (syntax-ppss)))
             (cond
              ;; Inside a string or comment: leave the column as it is.
              ((nth 8 ppss) (current-indentation))
              ;; A fresh top-level definition: column 0, or its comment.
              ((and (looking-at owl--definition-regexp)
                    (owl--definition-start-indent)))
              ((and (looking-at "use\\s-")
                    (owl--definition-start-indent)))
              ;; The line closes an open call: align with its paren.
              ((looking-at ")")
               (or (owl--matching-open-column) 0))
              ;; Inside an unclosed call: one past the opening paren.
              ((> (nth 0 ppss) 0)
               (if-let* ((col (save-excursion
                                (goto-char (nth 1 ppss))
                                (current-column))))
                   (1+ col)
                 0))
              ;; An empty line: leave the column alone.
              ((and (eolp) (not current-prefix-arg)) (current-indentation))
              ;; Otherwise the block structure decides; a column that is
              ;; legal for an open block stays as typed.  With a prefix
              ;; argument, always re-derive it from the block structure.
              (t
               (let ((info (owl--block-info))
                     (cur (current-indentation)))
                 (if (and (not current-prefix-arg)
                          (member cur (cdr info)))
                     cur
                   (car info)))))))))
    (unless (= (current-indentation) target)
      (indent-line-to target))))

(defun owl-beginning-of-defun (&optional arg)
  "Move to the beginning of the ARGth Owl definition.
Meets the `beginning-of-defun-function' contract."
  (let ((arg (or arg 1))
        (found t))
    (while (and (/= arg 0) found)
      (if (> arg 0)
          (progn
            ;; from a header line, go to the previous definition
            (when (save-excursion (beginning-of-line)
                                  (looking-at owl-defun-regexp))
              (forward-line -1))
            (setq found (re-search-backward owl-defun-regexp nil t))
            (when found (goto-char (match-beginning 0))))
        (forward-line 1)
        (setq found (re-search-forward owl-defun-regexp nil t))
        (when found (goto-char (match-beginning 0))))
      (setq arg (if (> arg 0) (1- arg) (1+ arg))))
    (unless found (goto-char (point-max)))
    (= arg 0)))

(defun owl-end-of-defun ()
  "Move to the end of the current Owl definition.
Meets the `end-of-defun-function' contract."
  (let ((start
         (save-excursion
           (beginning-of-line)
           (or (and (looking-at owl-defun-regexp) (point))
               (and (re-search-backward owl-defun-regexp nil t)
                    (match-beginning 0))))))
    (when start
      (let ((base-indent (save-excursion
                           (goto-char start)
                           (current-indentation))))
        (goto-char start)
        (forward-line 1)
        (while (not (or (eobp)
                        (save-excursion
                          (skip-chars-forward " \t")
                          (and (not (eolp))          ; blank lines stay in
                               (not (looking-at ";")) ; and comment lines
                               (<= (current-column) base-indent)))))
          (forward-line 1))))))

(defun owl-imenu-create-index ()
  "Build an Imenu index of the definitions in the current buffer."
  (let ((index))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward owl-defun-regexp nil t)
        (push (cons (match-string 2) (match-beginning 1)) index)))
    (nreverse index)))

;;;###autoload
(define-derived-mode owl-mode prog-mode "Owl"
  "Major mode for the Owl programming language.
\\{owl-mode-map}"
  :syntax-table owl-mode-syntax-table
  :group 'owl
  (setq-local comment-start "; ")
  (setq-local comment-end "")
  (setq-local comment-use-syntax t)
  (setq-local indent-line-function #'owl-indent-line)
  (setq-local indent-tabs-mode nil)
  (setq-local standard-indent owl-indent-width)
  (setq-local parse-sexp-ignore-errors t)
  (setq-local parse-sexp-lookup-properties t)
  (setq-local syntax-propertize-function #'owl--syntax-propertize)
  (setq-local imenu-create-index-function #'owl-imenu-create-index)
  (setq-local beginning-of-defun-function #'owl-beginning-of-defun)
  (setq-local end-of-defun-function #'owl-end-of-defun)
  (setq-local electric-indent-chars (append '(?\n) electric-indent-chars))
  (setq font-lock-defaults '(owl-font-lock-keywords)))

(provide 'owl)
;;; owl.el ends here
