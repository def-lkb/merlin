;;; merlin-imenu.el --- Merlin and imenu integration.   -*- coding: utf-8 -*-
;; Licensed under the MIT license.

;; Author: Ta Quang Trung
;; Version: 0.3
;; Release log:
;;   - v0.1: July 2016
;;   - v0.2: 27 April 2017
;;   - v0.3: 21 August 2019
;; Keywords: ocaml, imenu, merlin
;; URL:

(require 'imenu)
(require 'tuareg)
(require 'subr-x)
(require 'merlin)

;;; enable depth and size threshold for OCaml modules with big size
(setq max-lisp-eval-depth 10000)
(setq max-specpdl-size 10000)

;; lists of different outline items
(defvar-local value-list nil)
(defvar-local type-list nil)
(defvar-local class-list nil)
(defvar-local exception-list nil)
(defvar-local label-list nil)

(defun compute-pos (line col)
  "Get location of the item."
  (save-excursion
    (condition-case nil
        (progn
          (goto-char (point-min))
          (forward-line (- line 1))
          (move-to-column col)
          (point))
      (error -1))))

(defun update-item-type (name type kind line col)
  (defun query-type-from-code ()
    ;; NOTE: this query can be slow
    (let* ((types (merlin/call "type-enclosing"
                               "-position" (format "%d:%d" line col)
                               "-expression" name)))
      (cdr (nth 3 (car types)))))
  (let* ((new-type (cond ((not (string= kind "Value")) "null")
                         ((not (string= type "null")) type)
                         (t (query-type-from-code))))
         (new-type (replace-regexp-in-string "\n" " " new-type))
         (new-type (propertize new-type 'face 'font-lock-doc-face)))
    (if (string= new-type "null") name (concat name " : " new-type))))

(defun parse-outline-item (prefix item)
  "Parse one item of the outline tree."
  (let* ((line (cdr (nth 2 (nth 1 item))))
         (col (cdr (nth 3 (nth 1 item))))
         (item-name (cdr (nth 3 item)))
         (item-kind (cdr (nth 4 item)))
         (item-type (cdr (nth 5 item)))
         (sub-trees (cdr (nth 6 item)))
         (item-name (update-item-type item-name item-type item-kind line col))
         (item-name (concat prefix item-name))
         (item-pos (compute-pos line col))
         (marker (set-marker (make-marker) item-pos))
         (item-marker (cons item-name marker)))
    (cond ((string= item-kind "Value")
           (setq value-list (cons item-marker value-list)))
          ((string= item-kind "Type")
           (setq type-list (cons item-marker type-list)))
          ((string= item-kind "Class")
           (setq class-list (cons item-marker class-list)))
          ((string= item-kind "Exn")
           (setq exception-list (cons item-marker exception-list)))
          ((string= item-kind "Label")
           (setq label-list (cons item-marker label-list))))
    (if (and (listp sub-trees) (not (null sub-trees)))
        (parse-outline-tree (concat prefix item-name " / ") sub-trees))))

(defun parse-outline-tree (prefix outline)
  "Parse outline tree."
  (when (not (null outline))
    (parse-outline-item prefix (car outline))
    (parse-outline-tree prefix (cdr outline))))

(defun merlin-imenu-create-index ()
  "Create data for imenu using the merlin outline feature."
  (interactive)
  ;; Reset local vars
  (setq value-list nil
        type-list nil
        class-list nil
        exception-list nil
        label-list nil)
  ;; Read outline tree
  (parse-outline-tree "" (merlin/call "outline"))
  (let ((index ()))
    (when exception-list (push (cons "Exception" exception-list) index))
    (when label-list (push (cons "Label" label-list) index))
    (when type-list (push (cons "Type" type-list) index))
    (when class-list (push (cons "Class" class-list) index))
    (when value-list (push (cons "Value" value-list) index))
    index))

;; enable Merlin to use the merlin-imenu module
(defun merlin-use-merlin-imenu ()
  "Merlin: use the custom imenu feature from Merlin"
  (interactive)
  ;; change the index function and force a rescan of imenu-index
  (setq imenu-create-index-function 'merlin-imenu-create-index)
  (imenu--cleanup)
  (setq imenu--index-alist nil)
  (message "Merlin: merlin-imenu is selected, rescanning buffer..."))

;; enable Merlin to use the default tuareg-imenu module
(defun merlin-use-tuareg-imenu ()
  "Merlin: use the default imenu feature from Tuareg"
  (interactive)
  ;; change the index function and force a rescan of imenu-index
  (setq imenu-create-index-function 'tuareg-imenu-create-index)
  (imenu--cleanup)
  (setq imenu--index-alist nil)
  (message "Merlin: tuareg-imenu is selected, rescanning buffer..."))

(provide 'merlin-imenu)
;;; merlin-imenu.el ends here
