;;; org-roam-stats.el --- Personal Knowledge Management Dashboard -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Copyright (C) 2025 Gerardo Cendejas Mendoza

;; Author: Gerardo Cendejas Mendoza <gc597@cornell.edu>
;; Assisted-by: Claude:claude-sonnet-4-6
;; Maintainer: Gerardo Cendejas Mendoza <gc597@cornell.edu>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (org-roam "2.0") (simple-httpd "1.6"))
;; Keywords: org-roam, notes, statistics, dashboard
;; URL: https://github.com/GerardoCendejas/org-roam-stats

;; License: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;  Org-roam-stats provides a browser-based dashboard for your org-roam notes.
;;  It tracks note creation over time, identifies orphaned nodes, and supports
;;  filtering by file tags.  Enable `org-roam-stats-mode' to log creation
;;  timestamps, then call `org-roam-stats-start' to open the dashboard.

;;; Code:

;; Required packages

(require 'simple-httpd)
(require 'json)
(require 'org-roam)

;; Custom group and variables

(defgroup org-roam-stats nil
  "Customizations for org-roam-stats dashboard."
  :group 'org-roam)

(defcustom org-roam-stats-log-file (locate-user-emacs-file "org-roam-stats-log.org")
  "Path to the file where exact creation timestamps of org-roam nodes are recorded."
  :type 'file
  :group 'org-roam-stats)

(defcustom org-roam-stats-port 8089
  "Unique local port dedicated for the org-roam-stats web server."
  :type 'integer
  :group 'org-roam-stats)

(defvar org-roam-stats--cache (make-hash-table :test 'equal)
  "Memory cache store for org-roam-stats nodes data to prevent re-parsing unmodified files.")

(defconst org-roam-stats--package-root
  (eval-and-compile
    (file-name-directory (or (bound-and-true-p byte-compile-current-file)
                             load-file-name
                             (buffer-file-name)
                             default-directory)))
  "Absolute path of the package installation.")

;;;###autoload
(define-minor-mode org-roam-stats-mode
  "Toggle exact creation time logging for org-roam nodes."
  :global t
  :group 'org-roam-stats
  (if org-roam-stats-mode
      (add-hook 'org-roam-capture-new-node-hook #'org-roam-stats--log-node-creation)
    (remove-hook 'org-roam-capture-new-node-hook #'org-roam-stats--log-node-creation)))

(defun org-roam-stats--log-node-creation ()
  "Hook function to log the exact creation timestamp and ID of a newly created org-roam node."
  (let* ((node-id (org-id-get))
         (timestamp (format-time-string "[%Y-%m-%d %a %H:%M]"))
         (log-dir (file-name-directory (expand-file-name org-roam-stats-log-file))))
    (when node-id
      (unless (file-directory-p log-dir)
        (make-directory log-dir t))
      (with-current-buffer (find-file-noselect org-roam-stats-log-file)
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert (format "* %s\n  :PROPERTIES:\n  :ID:       %s\n  :END:\n" timestamp node-id))
        (save-buffer)))))

;;; ================= METADATA EXTRACTION PARSER =================

(defun org-roam-stats--get-node-creation-time (node-id file-path file-mod-time)
  "Extract creation time for node.
Argument NODE-ID Node ID.
Argument FILE-PATH path for node file.
Argument FILE-MOD-TIME Timestamp of the file (for when the log has no info)."
  (let ((precise-time nil))
    (when (file-exists-p org-roam-stats-log-file)
      (with-temp-buffer
        (insert-file-contents org-roam-stats-log-file)
        (goto-char (point-min))
        (when (re-search-forward (concat ":ID:[ \t]+" (regexp-quote node-id)) nil t)
          (when (search-backward "* [" nil t)
            (when (looking-at "^\\*+[ \t]+\\[\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}[^]]*\\)\\]")
              (let ((raw-time (match-string 1)))
                (setq precise-time
                      (string-trim
                       (replace-regexp-in-string
                        "\\b\\(Sun\\|Mon\\|Tue\\|Wed\\|Thu\\|Fri\\|Sat\\|dom\\|lun\\|mar\\|mie\\|jue\\|vie\\|sab\\)\\b"
                        ""
                        raw-time)))))))))
    
    ;; If no precise time found, fallback to filename parsing or file modification time (For org-roam nodes created before the logging with org-roam-stats-mode)
    (if precise-time
        precise-time
      (let ((base-name (file-name-base file-path)))
        (if (string-match "^\\([0-9]\\{4\\}\\)\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)-" base-name)
            (format "%s-%s-%s %s:%s"
                    (match-string 1 base-name)
                    (match-string 2 base-name)
                    (match-string 3 base-name)
                    (match-string 4 base-name)
                    (match-string 5 base-name))
          (concat (format-time-string "%Y-%m-%d" file-mod-time) " NO_TIME"))))))

(defun org-roam-stats--extract-node-data (node backlinks-map links-map)
  "Extract properties for a node.
Argument NODE org-roam node.
Argument BACKLINKS-MAP info about backlinks of nodes.
Argument LINKS-MAP links between nodes."
  (let* ((id (org-roam-node-id node))
         (title (org-roam-node-title node))
         (file (org-roam-node-file node))
         (tags (org-roam-node-tags node))
         (attrs (when (and file (file-exists-p file)) (file-attributes file)))
         (mod-time (when attrs (file-attribute-modification-time attrs)))
         (cache-val (gethash id org-roam-stats--cache))
         (backlinks-count (or (gethash id backlinks-map) 0))
         (links-count (or (gethash id links-map) 0))
         (word-count 0)
         (timestamp "")
         (content "")) ; Will show the content of orphaned nodes in the dashboard if they have no links or backlinks))
    
    (if (and cache-val (equal (cdr (assoc 'mod-time cache-val)) mod-time))
        (setq timestamp (cdr (assoc 'timestamp cache-val))
              word-count (cdr (assoc 'words cache-val)))
      
      (setq timestamp (org-roam-stats--get-node-creation-time id file mod-time))
      (when (and file attrs (= (org-roam-node-level node) 0))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (let ((body-start (point-min)))
            (while (re-search-forward "^#\\+.*$" nil t)
              (setq body-start (match-end 0)))
            (setq word-count (count-words body-start (point-max))))))
      
      (let ((new-cache-entry (list (cons 'mod-time mod-time)
                                   (cons 'timestamp timestamp)
                                   (cons 'words word-count))))
        (puthash id new-cache-entry org-roam-stats--cache)))
    
    ;; If the node has no links or backlinks, and it is a top-level node, we will include its content in the dashboard for context.
    (when (and (= backlinks-count 0) (= links-count 0) file (file-exists-p file))
      (with-temp-buffer
        (insert-file-contents-literally file)
        (setq content (buffer-substring-no-properties (point-min) (point-max)))))
    
    (list (cons 'id id)
          (cons 'title title)
          (cons 'timestamp timestamp)
          (cons 'words word-count)
          (cons 'links links-count)
          (cons 'backlinks backlinks-count)
          (cons 'tags (or tags []))
          (cons 'content content))))

;;; ================= JSON GENERATION ENGINE =================

(defun org-roam-stats-generate-json ()
  "Compile full database metrics into a single unified data.json package."
  ;; First time generation will be slower, but subsequent runs will be faster due to caching.
  (interactive)
  (let* ((web-dir (expand-file-name "web/" org-roam-stats--package-root))
         (all-nodes (org-roam-node-list))
         (nodes-json '())
         (backlinks-query (org-roam-db-query "SELECT dest, COUNT(source) FROM links GROUP BY dest"))
         (backlinks-map (make-hash-table :test 'equal))
         (links-query (org-roam-db-query "SELECT source, COUNT(dest) FROM links GROUP BY source"))
         (links-map (make-hash-table :test 'equal)))
    
    (dolist (row backlinks-query)
      (let ((dest-id (nth 0 row))
            (count (nth 1 row)))
        (when (stringp dest-id) (puthash dest-id count backlinks-map))))

    (dolist (row links-query)
      (let ((source-id (nth 0 row))
            (count (nth 1 row)))
        (when (stringp source-id) (puthash source-id count links-map))))
    
    (unless (file-directory-p web-dir) (make-directory web-dir t))
    
    (dolist (node all-nodes)
      (when (= (org-roam-node-level node) 0)
        (push (org-roam-stats--extract-node-data node backlinks-map links-map) nodes-json)))
    
    (let ((final-payload (list (cons 'nodes nodes-json)
                               (cons 'links '())))
          (json-encoding-pretty-print t))
      (with-temp-file (expand-file-name "data.json" web-dir)
        (insert (json-encode final-payload))))
    (message "Org-roam Dashboard updated successfully in: %s" web-dir)))

;;; ================= SERVER ENGINE CONTROL =================

;;;###autoload
(defun org-roam-stats-start ()
  "Start the local server and open the org-roam-stats dashboard in a browser."
  (interactive)
  (clrhash org-roam-stats--cache)
  (org-roam-stats-generate-json)
  (httpd-stop)
  (let ((web-path (expand-file-name "web/" org-roam-stats--package-root)))
    (setq httpd-port org-roam-stats-port
          httpd-root web-path)
    (httpd-start)
    (browse-url (format "http://localhost:%d/index.html" org-roam-stats-port))))

(provide 'org-roam-stats)
;;; org-roam-stats.el ends here
