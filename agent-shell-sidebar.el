;;; agent-shell-sidebar.el --- Sidebar interface for agent-shell -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Calum MacRae

;; Author: Calum MacRae https://github.com/cmacrae
;; URL: https://github.com/cmacrae/agent-shell-sidebar
;; Package-Requires: ((emacs "29.1") (agent-shell "0.17.2"))
;; Version: 0.1.0

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This package is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Provides sidebar functionality for agent-shell, allowing the agent
;; interface to be displayed as a persistent side panel similar to treemacs.
;;
;; Each project gets its own independent sidebar that persists across
;; visibility toggles and maintains separate state for buffer, provider,
;; and last focused window.
;;
;; Usage:
;;   M-x agent-shell-sidebar-toggle          - Toggle sidebar visibility
;;   M-x agent-shell-sidebar-toggle-focus    - Toggle focus between sidebar and last buffer
;;   M-x agent-shell-sidebar-change-provider - Switch to a different agent provider
;;   M-x agent-shell-sidebar-reset           - Reset sidebar for current project
;;
;; Customization:
;;   `agent-shell-sidebar-width'             - Width of the sidebar (default: "25%")
;;   `agent-shell-sidebar-minimum-width'     - Minimum width (default: 80)
;;   `agent-shell-sidebar-maximum-width'     - Maximum width (default: "50%")
;;   `agent-shell-sidebar-position'          - Position: 'left or 'right (default: 'right)
;;   `agent-shell-sidebar-default-config'    - Default config to use
;;   `agent-shell-sidebar-locked'            - Lock sidebar position and size (default: t)
;;
;; Setting a default provider:
;;   To automatically use a specific provider without being prompted, set
;;   `agent-shell-sidebar-default-config' to the result of calling one of
;;   the agent-shell config functions:
;;
;;   ;; Anthropic's Claude Code
;;   (setq agent-shell-sidebar-default-config
;;         (agent-shell-anthropic-make-claude-code-config))
;;
;;   ;; Google's Gemini
;;   (setq agent-shell-sidebar-default-config
;;         (agent-shell-google-make-gemini-config))
;;
;;   ;; OpenAI Codex
;;   (setq agent-shell-sidebar-default-config
;;         (agent-shell-openai-make-codex-config))
;;
;;   ;; Goose Agent
;;   (setq agent-shell-sidebar-default-config
;;         (agent-shell-goose-make-agent-config))

;;; Code:

(eval-when-compile
  (require 'cl-lib))
(require 'agent-shell)
(require 'map)

(declare-function project-root "project")
(declare-function project-roots "project")
(declare-function project-current "project")
(declare-function projectile-project-root "projectile")
(declare-function agent-shell--start "agent-shell")

(defgroup agent-shell-sidebar nil
  "Sidebar interface for agent-shell."
  :group 'agent-shell
  :prefix "agent-shell-sidebar-")

(defcustom agent-shell-sidebar-width "25%"
  "Width of the agent-shell sidebar window.

Can be specified as:
 * An integer (e.g., 80) for absolute width in columns
 * A string with % suffix (e.g., \"25%\") for percentage of frame width

The final width will be constrained by `agent-shell-sidebar-minimum-width'
and `agent-shell-sidebar-maximum-width'."
  :type '(choice (integer :tag "Absolute width in columns")
                 (string :tag "Percentage of frame width (e.g., \"25%\")"))
  :group 'agent-shell-sidebar)

(defcustom agent-shell-sidebar-minimum-width 80
  "Minimum width of the agent-shell sidebar window.

Can be specified as:
 * An integer (e.g., 80) for absolute width in columns
 * A string with % suffix (e.g., \"10%\") for percentage of frame width

This constraint is applied after calculating the configured width."
  :type '(choice (integer :tag "Absolute width in columns")
                 (string :tag "Percentage of frame width (e.g., \"10%\")"))
  :group 'agent-shell-sidebar)

(defcustom agent-shell-sidebar-maximum-width "50%"
  "Maximum width of the agent-shell sidebar window.

Can be specified as:
 * An integer (e.g., 120) for absolute width in columns
 * A string with % suffix (e.g., \"50%\") for percentage of frame width

This constraint is applied after calculating the configured width.
When the minimum width is greater than the maximum width, the minimum
takes precedence."
  :type '(choice (integer :tag "Absolute width in columns")
                 (string :tag "Percentage of frame width (e.g., \"50%\")"))
  :group 'agent-shell-sidebar)

(defcustom agent-shell-sidebar-position 'right
  "Position of the agent-shell sidebar.

Valid values are:
 * `left' - Display sidebar on the left side
 * `right' - Display sidebar on the right side"
  :type '(choice (const :tag "Left" left)
                 (const :tag "Right" right))
  :group 'agent-shell-sidebar)

(defcustom agent-shell-sidebar-default-config nil
  "Default agent config to use for sidebar sessions.

When set, the sidebar will automatically use this config without prompting.
When nil, the user will be prompted to select from `agent-shell-agent-configs'.

The value should be an agent config alist as returned by
`agent-shell-make-agent-config' or provider-specific config functions like
`agent-shell-anthropic-make-claude-code-config'."
  :type '(choice (const :tag "Prompt for config" nil)
                 (alist :tag "Agent config alist"))
  :group 'agent-shell-sidebar)

(defcustom agent-shell-sidebar-locked t
  "When non-nil, lock the sidebar to its fixed position.

A locked sidebar:
 * Cannot be resized manually
 * Is invisible to `other-window' commands (C-x o)

When nil, the sidebar can be resized manually and will be visible to
`other-window' commands."
  :type 'boolean
  :group 'agent-shell-sidebar)

(defcustom agent-shell-sidebar-use-custom-font t
  "Show `agent-shell-sidebar' with custom font.

This face can be customized using `agent-shell-sidebar-face'."
  :type 'boolean
  :group 'agent-shell-sidebar)

(defface agent-shell-sidebar-face nil
  "Face used by `agent-shell-sidebar' for custom font.

This only takes effect if `agent-shell-sidebar-use-custom-font' is enabled."
  :group 'agent-shell-sidebar)

(defvar agent-shell-sidebar--project-state (make-hash-table :test 'equal)
  "Hash table storing sidebar state per project.
Keys are project root paths, values are alists with:
  (:buffer . BUFFER)       - sidebar buffer for this project
  (:config . ALIST)        - agent config used for this sidebar
  (:last-buffer . BUFFER)  - last non-sidebar buffer with focus
  (:width . INTEGER)       - current width of the sidebar window")

(defvar-local agent-shell-sidebar--is-sidebar nil
  "Non-nil if this buffer is an agent-shell sidebar buffer.")

(defvar agent-shell-sidebar--last-window nil
  "Last selected window before entering sidebar.
Used to restore focus when toggling sidebar off.")

(cl-defun agent-shell-sidebar--make-state (&key buffer config last-buffer width)
  "Construct sidebar state with BUFFER, CONFIG, LAST-BUFFER, and WIDTH."
  (list (cons :buffer buffer)
        (cons :config config)
        (cons :last-buffer last-buffer)
        (cons :width width)))

(defun agent-shell-sidebar--get-project-root ()
  "Get the current project root directory.
Returns nil if not in a project, otherwise returns the project root.
Checks projectile first, then project.el, then default-directory."
  (or (when (fboundp 'projectile-project-root)
        (ignore-errors (projectile-project-root)))
      (when (fboundp 'project-root)
        (when-let* ((proj (project-current)))
          (if (fboundp 'project-root)
              (project-root proj)
            (car (project-roots proj)))))
      default-directory))

(defun agent-shell-sidebar--project-state (project-root)
  "Get the sidebar state alist for PROJECT-ROOT.
Creates empty state if none exists."
  (or (gethash project-root agent-shell-sidebar--project-state)
      (let ((state (agent-shell-sidebar--make-state)))
        (puthash project-root state agent-shell-sidebar--project-state)
        state)))

(defun agent-shell-sidebar--parse-width-value (value frame-width)
  "Parse width VALUE into absolute columns.
VALUE can be an integer (absolute columns) or a string ending in '%'
(percentage of FRAME-WIDTH). Returns an integer representing columns."
  (cond
   ((integerp value)
    value)
   ((and (stringp value) (string-suffix-p "%" value))
    (let* ((percentage-str (substring value 0 -1))
           (percentage (string-to-number percentage-str)))
      (if (and (numberp percentage) (> percentage 0))
          (round (* frame-width (/ percentage 100.0)))
        (error "Invalid percentage value: %s" value))))
   (t
    (error "Width value must be an integer or percentage string: %s" value))))

(defun agent-shell-sidebar--calculate-width ()
  "Calculate the sidebar width in columns.
Parses `agent-shell-sidebar-width', `agent-shell-sidebar-minimum-width',
and `agent-shell-sidebar-maximum-width', applying constraints.
Returns an integer representing the final width in columns."
  (let* ((frame-width (frame-width))
         (configured-width (agent-shell-sidebar--parse-width-value
                           agent-shell-sidebar-width frame-width))
         (min-width (agent-shell-sidebar--parse-width-value
                    agent-shell-sidebar-minimum-width frame-width))
         (max-width (agent-shell-sidebar--parse-width-value
                    agent-shell-sidebar-maximum-width frame-width)))
    ;; If min > max, prefer min (user's responsibility to set sensible values)
    (cond
     ((> min-width max-width)
      min-width)
     (t
      (max min-width (min configured-width max-width))))))

(cl-defun agent-shell-sidebar--get-buffer (&key (project-root (agent-shell-sidebar--get-project-root)))
  "Get the agent-shell sidebar buffer for PROJECT-ROOT."
  (when-let* ((state (agent-shell-sidebar--project-state project-root))
              (buffer (map-elt state :buffer)))
    (when (buffer-live-p buffer)
      buffer)))

(cl-defun agent-shell-sidebar--get-window (&key (project-root (agent-shell-sidebar--get-project-root)))
  "Get the window displaying the sidebar for PROJECT-ROOT."
  (when-let* ((buffer (agent-shell-sidebar--get-buffer :project-root project-root)))
    (get-buffer-window buffer)))

(cl-defun agent-shell-sidebar--visible-p (&key (project-root (agent-shell-sidebar--get-project-root)))
  "Return t if sidebar for PROJECT-ROOT is currently visible."
  (not (null (agent-shell-sidebar--get-window :project-root project-root))))

(defun agent-shell-sidebar--buffer-p (buffer)
  "Return t if BUFFER is a sidebar buffer for any project."
  (when buffer
    (buffer-local-value 'agent-shell-sidebar--is-sidebar buffer)))

(cl-defun agent-shell-sidebar--setup-window (&key buffer project-root)
  "Setup window parameters for sidebar BUFFER in PROJECT-ROOT."
  (when-let* ((window (get-buffer-window buffer)))
    (with-selected-window window
      (set-window-parameter window 'no-delete-other-windows t)
      (set-window-parameter window 'window-side agent-shell-sidebar-position)
      (set-window-parameter window 'window-slot 0)
      (set-window-dedicated-p window t)

      (with-current-buffer buffer
        (setq-local window-size-fixed (when agent-shell-sidebar-locked 'width)))

      (unless (one-window-p)
        (let* ((state (agent-shell-sidebar--project-state project-root))
               (target-width (if agent-shell-sidebar-locked
                                 ;; When locked, always recalculate from config (responsive)
                                 (agent-shell-sidebar--calculate-width)
                               ;; When unlocked, use saved width or calculate from config
                               (or (map-elt state :width)
                                   (agent-shell-sidebar--calculate-width))))
               (window-size-fixed nil))
          (when (> (window-width) target-width)
            (shrink-window-horizontally (- (window-width) target-width)))
          (when (< (window-width) target-width)
            (enlarge-window-horizontally (- target-width (window-width)))))))))

(cl-defun agent-shell-sidebar--display-buffer (&key buffer project-root)
  "Display BUFFER as a sidebar for PROJECT-ROOT."
  (let ((window (display-buffer
                 buffer
                 `(display-buffer-in-side-window
                   . ((side . ,agent-shell-sidebar-position)
                      (slot . 0)
                      (window-width . ,(agent-shell-sidebar--calculate-width))
                      (dedicated . t)
                      (window-parameters . ((no-delete-other-windows . t))))))))
    (agent-shell-sidebar--setup-window :buffer buffer :project-root project-root)
    window))

(defun agent-shell-sidebar--clean-up ()
  "Clean up sidebar resources when buffer is killed."
  (when agent-shell-sidebar--is-sidebar
    (let ((project-root (agent-shell-sidebar--get-project-root)))
      (when-let* ((state (gethash project-root agent-shell-sidebar--project-state))
                  (buffer (map-elt state :buffer)))
        (when (eq buffer (current-buffer))
          (map-put! (agent-shell-sidebar--project-state project-root) :buffer nil))))))

(cl-defun agent-shell-sidebar--start-session (&key config project-root)
  "Start new agent-shell sidebar session using CONFIG in PROJECT-ROOT.
CONFIG should be an agent config alist."
  (let* ((state (agent-shell-sidebar--project-state project-root))
         (existing-buffer (map-elt state :buffer)))

    (when (and existing-buffer (buffer-live-p existing-buffer))
      (kill-buffer existing-buffer))

    ;; Call agent-shell--start directly with no-focus and new-session parameters
    (let ((shell-buffer (agent-shell--start :config config :no-focus t :new-session t)))
      (with-current-buffer shell-buffer
        (setq-local agent-shell-sidebar--is-sidebar t)
        (add-hook 'kill-buffer-hook #'agent-shell-sidebar--clean-up nil t)

        (when (and agent-shell-sidebar-use-custom-font
                   (bound-and-true-p agent-shell-sidebar-face))
          (setq-local buffer-face-mode-face agent-shell-sidebar-face)
          (buffer-face-mode)))

      (map-put! state :buffer shell-buffer)
      (map-put! state :config config)

      shell-buffer)))

(defun agent-shell-sidebar--select-config ()
  "Select an agent config for the sidebar.
If `agent-shell-sidebar-default-config' is set, use that without prompting.
Otherwise, interactively prompt the user to select from `agent-shell-agent-configs'."
  (or agent-shell-sidebar-default-config
      (let* ((configs agent-shell-agent-configs)
             (choices (mapcar (lambda (config)
                                (cons (or (map-elt config :mode-line-name)
                                          (map-elt config :buffer-name)
                                          "Unknown Agent")
                                      config))
                              configs))
             (selected-name (completing-read "Select agent: " choices nil t)))
        (map-elt choices selected-name))))

(cl-defun agent-shell-sidebar--save-last-window ()
  "Save the currently selected window before entering sidebar."
  (unless (agent-shell-sidebar--buffer-p (current-buffer))
    (setq agent-shell-sidebar--last-window (selected-window))))

(cl-defun agent-shell-sidebar--restore-last-window ()
  "Restore focus to the last window before sidebar was entered."
  (cond
   ;; First, try the explicitly saved window
   ((and agent-shell-sidebar--last-window
         (window-live-p agent-shell-sidebar--last-window)
         (not (agent-shell-sidebar--buffer-p
               (window-buffer agent-shell-sidebar--last-window))))
    (select-window agent-shell-sidebar--last-window))
   ;; Fall back to most recently used non-sidebar window
   (t
    (let ((mru-window (get-mru-window (selected-frame) nil :not-selected)))
      (if (and mru-window
               (not (agent-shell-sidebar--buffer-p (window-buffer mru-window))))
          (select-window mru-window)
        ;; Last resort: find any non-sidebar window
        (let ((other-window (get-window-with-predicate
                             (lambda (w)
                               (not (agent-shell-sidebar--buffer-p (window-buffer w))))
                             nil nil)))
          (when other-window
            (select-window other-window))))))))

(cl-defun agent-shell-sidebar--hide-sidebar (&key project-root window)
  "Hide sidebar WINDOW for PROJECT-ROOT and save width if unlocked."
  ;; Only save width when unlocked (user may have manually resized)
  (unless agent-shell-sidebar-locked
    (map-put! (agent-shell-sidebar--project-state project-root) :width (window-width window)))
  (delete-window window)
  (agent-shell-sidebar--restore-last-window))

(cl-defun agent-shell-sidebar--show-existing-sidebar (&key project-root buffer)
  "Show existing sidebar BUFFER for PROJECT-ROOT."
  (agent-shell-sidebar--save-last-window)
  (let ((window (agent-shell-sidebar--display-buffer :buffer buffer :project-root project-root)))
    (select-window window)))

(cl-defun agent-shell-sidebar--create-and-show-sidebar (&key project-root)
  "Create new sidebar for PROJECT-ROOT and show it."
  (agent-shell-sidebar--save-last-window)
  (let* ((state (agent-shell-sidebar--project-state project-root))
         (config (or (map-elt state :config)
                     (agent-shell-sidebar--select-config)))
         (shell-buffer (agent-shell-sidebar--start-session :config config :project-root project-root))
         (window (agent-shell-sidebar--display-buffer :buffer shell-buffer :project-root project-root)))
    (select-window window)))

;;;###autoload
(defun agent-shell-sidebar-toggle ()
  "Toggle sidebar visibility for the current project.
If sidebar doesn't exist, create new session and focus it.
If it exists but not visible, show it and focus it.
If visible, hide it and return focus to last focused buffer.

Each project gets its own independent sidebar."
  (interactive)
  (let ((project-root (agent-shell-sidebar--get-project-root)))
    (cond
     ((agent-shell-sidebar--get-window :project-root project-root)
      (agent-shell-sidebar--hide-sidebar
       :project-root project-root
       :window (agent-shell-sidebar--get-window :project-root project-root)))
     ((agent-shell-sidebar--get-buffer :project-root project-root)
      (agent-shell-sidebar--show-existing-sidebar
       :project-root project-root
       :buffer (agent-shell-sidebar--get-buffer :project-root project-root)))
     (t
      (agent-shell-sidebar--create-and-show-sidebar :project-root project-root)))))

;;;###autoload
(defun agent-shell-sidebar-toggle-focus ()
  "Toggle focus between sidebar and last buffer for current project.
If not in sidebar, switch to it (creating if necessary).
If in sidebar, switch back to the last non-sidebar buffer.
When repeatedly called, switches focus back and forth.

Each project maintains its own sidebar and last-buffer state."
  (interactive)
  (let* ((project-root (agent-shell-sidebar--get-project-root))
         (sidebar-buffer (agent-shell-sidebar--get-buffer :project-root project-root))
         (in-sidebar (and sidebar-buffer (eq (current-buffer) sidebar-buffer))))
    (if in-sidebar
        (agent-shell-sidebar--restore-last-window)
      (progn
        (agent-shell-sidebar--save-last-window)
        (cond
         ((agent-shell-sidebar--get-window :project-root project-root)
          (select-window (agent-shell-sidebar--get-window :project-root project-root)))
         (sidebar-buffer
          (agent-shell-sidebar--show-existing-sidebar
           :project-root project-root
           :buffer sidebar-buffer))
         (t
          (agent-shell-sidebar--create-and-show-sidebar :project-root project-root)))))))

;;;###autoload
(defun agent-shell-sidebar-change-provider ()
  "Change the agent provider for the current project's sidebar.
This will kill the current sidebar session and start a new one with
the selected provider."
  (interactive)
  (let ((project-root (agent-shell-sidebar--get-project-root))
        (config (agent-shell-sidebar--select-config)))
    (when-let* ((buffer (agent-shell-sidebar--get-buffer :project-root project-root)))
      (kill-buffer buffer))
    (agent-shell-sidebar--save-last-window)
    (let* ((shell-buffer (agent-shell-sidebar--start-session :config config :project-root project-root))
           (window (agent-shell-sidebar--display-buffer :buffer shell-buffer :project-root project-root)))
      (select-window window))))

;;;###autoload
(defun agent-shell-sidebar-reset ()
  "Reset the sidebar for the current project by killing the current session.
The next toggle will create a fresh session."
  (interactive)
  (let ((project-root (agent-shell-sidebar--get-project-root)))
    (when-let* ((buffer (agent-shell-sidebar--get-buffer :project-root project-root)))
      (when-let* ((window (get-buffer-window buffer)))
        (delete-window window))
      (kill-buffer buffer))
    (remhash project-root agent-shell-sidebar--project-state)
    (message "Sidebar reset for project: %s"
             (file-name-nondirectory (directory-file-name project-root)))))

(with-eval-after-load 'golden-ratio
  (when (boundp 'golden-ratio-exclude-modes)
    (add-to-list 'golden-ratio-exclude-modes 'agent-shell-mode)))

(provide 'agent-shell-sidebar)

;;; agent-shell-sidebar.el ends here
