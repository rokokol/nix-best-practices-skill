# Comments in Nix

What a comment says is not this file's subject. What is here is the part that is particular to Nix: where a comment sits in a module, which of the two forms survives the formatter, and the one case where a comment changes the code's layout rather than only its reading

## Where a module's file comment goes

After the argument header, against the body, with no blank line between:

```nix
{
  config,
  rokokolName,
  ...
}:

# The keys this service reads come from sops as an env file rather than from the store, so
# the value never lands in a world-readable path
{
  sops.secrets."some-api-key" = { };
}
```

The reader meets the explanation and the code it explains together. A blank line between them turns the comment into a header for the file, which is a different claim: a header describes the file, this describes what follows it

Attribution for vendored third-party work goes above the header instead, where a licence header goes:

```nix
# Sayori Cursor V2 — an animated DDLC-style cursor theme
# Author: sev (https://ko-fi.com/sevverae)
{ pkgs, inputs, ... }:
```

The distinction is what the text is about. A credit is about the file's provenance and belongs before anything else; an explanation is about the code and belongs beside it

A file that is not a module — a package, a function, a string of configuration for something else — keeps its comment on line 1. There is no argument header there for the comment to be after, and the reader of such a file looks at the top

## `#` and `/* … */`

The formatter settles this, so the rule is what it does rather than what to prefer:

- a single-line `/* … */` becomes `#`
- a multiline one keeps its delimiters, each on a line of its own
- `/* bash */` immediately before a string is preserved

The last is a language annotation: an editor reads it to highlight the embedded code, so it is part of the string's meaning rather than a comment about it. The same works for other languages an editor knows

## Documentation comments

`/** … */` before a binding is the documentation format `nixdoc` reads, and it is for a library function that someone will call from elsewhere:

```nix
/**
  Turn a hex colour into the `rgba(rrggbbaa)` form Hyprland wants.

  # Example

  ```nix
  rgba "1d1f21" "ee"
  => "rgba(1d1f21ee)"
  ```
*/
rgba = hex: alpha: "rgba(${hex}${alpha})";
```

It earns its cost where a function is an interface — a `lib` a flake exports, a helper several modules call. Over a module it does not: a module is not called, it is merged, and what a reader needs there is why rather than how to invoke it

## The comment that explains a deviation

A list kept in some order will sometimes have an entry that breaks it, and the comment beside that entry is what stops the next person restoring the order and the bug with it:

```nix
home.packages = with pkgs; [
  evince
  # IfcOpenShell fails against the current Boost; stable has the version it was built for
  stable.freecad
  geary
];
```

The comment is beside the line rather than at the top of the list, because the list is not what it is about

## A comment changes the layout

This one is particular to Nix and easy to meet by accident. A comment inside a list or an attribute set stops the formatter collapsing it:

```nix
p = with pkgs; [ jq ];        # stays on one line

p = with pkgs; [              # with a comment inside, it cannot
  # the one thing this needs
  jq
];
```

So adding an explanation to a short construct rewrites its layout permanently, and the diff that carries the comment also carries the reflow. Where the note is about the whole binding rather than about an element of it, putting it above the binding keeps both
