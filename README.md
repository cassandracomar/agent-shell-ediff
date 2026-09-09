# agent-shell-ediff

Replace `agent-shell-diff` with a grouped Ediff interface. All files in
one Agent Shell edit share a persistent sidebar, one review lifecycle,
and one permission decision. Select a file in the sidebar to change the
side-by-side comparison. On quit you are prompted to accept or reject
the entire edit.

## Requirements

- Emacs 29.1+
- [agent-shell](https://github.com/xenodium/agent-shell)

## Installation

### use-package + straight.el

```elisp
(use-package agent-shell-ediff
  :straight (:host github :repo "cassandracomar/agent-shell-ediff")
  :after agent-shell
  :custom
  (agent-shell-ediff-quick-quit t)
  :config
  (agent-shell-ediff-mode 1))
```

### use-package (manual load path)

```elisp
(use-package agent-shell-ediff
  :load-path "~/.emacs.d/site-lisp/agent-shell-ediff"
  :after agent-shell
  :custom
  (agent-shell-ediff-quick-quit t)
  :config
  (agent-shell-ediff-mode 1))
```

### Manual

Clone the repository and add it to your load path:

```sh
git clone https://github.com/cassandracomar/agent-shell-ediff ~/.emacs.d/site-lisp/agent-shell-ediff
```

```elisp
(add-to-list 'load-path "~/.emacs.d/site-lisp/agent-shell-ediff")
(require 'agent-shell-ediff)
(setq agent-shell-ediff-quick-quit t)
(agent-shell-ediff-mode 1)
```

## Usage

Enable the mode globally:

```elisp
(agent-shell-ediff-mode 1)
```

Disable it to restore the default `agent-shell-diff` behavior:

```elisp
(agent-shell-ediff-mode -1)
```

Or toggle interactively with `M-x agent-shell-ediff-mode`.

You may want to set the ediff highlighting faces to only change the face backgrounds, and blend them to different
opacities to ensure good visibility:

```elisp
(let ((bg (face-background 'default))
      (red (face-foreground 'error nil t))
      (green (face-foreground 'success nil t)))
  (custom-set-faces!
    `(ediff-odd-diff-A :foreground unspecified :inherit nil
      :background ,(doom-blend red bg 0.05) :extend t)
    `(ediff-odd-diff-B :foreground unspecified :inherit nil
      :background ,(doom-blend green bg 0.05) :extend t)
    `(ediff-even-diff-A :foreground unspecified :inherit nil
      :background ,(doom-blend red bg 0.05) :extend t)
    `(ediff-even-diff-B :foreground unspecified :inherit nil
      :background ,(doom-blend green bg 0.05) :extend t)
    `(ediff-current-diff-A :foreground unspecified :inherit nil
      :background ,(doom-blend red bg 0.2) :extend t)
    `(ediff-current-diff-B :foreground unspecified :inherit nil
      :background ,(doom-blend green bg 0.2) :extend t)
    `(ediff-fine-diff-A    :foreground unspecified :inherit nil
      :background ,(doom-blend red bg 0.35) :extend t)
    `(ediff-fine-diff-B    :foreground unspecified :inherit nil
      :background ,(doom-blend green bg 0.35) :extend t)))
```

## Configuration

- `agent-shell-ediff-quick-quit` -- when non-nil, `q` in the ediff
  control buffer calls `agent-shell-ediff-quit` (skips the extra ediff
  quit confirmation). Works with evil-mode. Default: `nil`.
- `agent-shell-ediff-sidebar-width` -- width of the persistent file
  sidebar. Default: `32`.

## Key bindings

In the file sidebar:

- `j` / `k` or arrow keys move between files.
- `RET` or `SPC` displays the selected file.
- `a` accepts the entire edit.
- `r` rejects the entire edit.
- `q` closes the grouped review and asks whether to accept or reject it.

Inside an ediff session the standard ediff bindings apply. With
`agent-shell-ediff-quick-quit` enabled, `q` skips the ediff quit
confirmation and ends the grouped review, then Agent Shell asks whether
to accept or reject the entire edit.
