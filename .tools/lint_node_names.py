#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Линтер имён программно создаваемых нод (Dark Omens).

Конвенция: после каждого `Type.new()`, если нода добавляется в дерево или
возвращается из функции-ноды, ей надо задать `node.name = "..."` (семантическая
роль), иначе в дереве сцены копятся `@Type@N`.

Ловит:
  1. var X := Type.new(); ...; add_child(X)        без X.name = ...
  2. var X := Type.new(); ...; return X            (функция -> НодаТип) без X.name
  3. add_child(Type.new())                         (инлайн — всегда анонимная)

Использование:
  python .tools/lint_node_names.py [scripts ...]      # по умолчанию: scripts
  exit code 1, если есть нарушения (удобно для pre-commit).
"""
import re
import sys
import os

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

# Типы-ноды (для случая «return X» — чтобы не путать с StyleBoxFlat/Gradient/…).
NODE_TYPES = {
    "Node", "Node2D", "Node3D", "Control", "CanvasItem", "CanvasLayer",
    "Label", "RichTextLabel", "Button", "TextureButton", "OptionButton",
    "CheckBox", "CheckButton", "LineEdit", "TextEdit", "HSlider", "VSlider",
    "Slider", "ProgressBar", "SpinBox", "Panel", "PanelContainer",
    "VBoxContainer", "HBoxContainer", "BoxContainer", "CenterContainer",
    "MarginContainer", "GridContainer", "ScrollContainer", "FlowContainer",
    "TabContainer", "SplitContainer", "AspectRatioContainer",
    "ColorRect", "TextureRect", "NinePatchRect", "ReferenceRect",
    "HSeparator", "VSeparator", "TextureProgressBar",
    "Sprite2D", "AnimatedSprite2D", "Polygon2D", "Line2D", "Path2D",
    "Camera2D", "Camera3D", "MeshInstance3D", "Sprite3D",
    "AnimationPlayer", "AnimationTree", "Tween", "Timer",
    "AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D",
    "SubViewport", "SubViewportContainer", "Viewport",
    "Area2D", "CollisionShape2D", "CollisionShape3D",
}

RE_FUNC   = re.compile(r"^\s*(?:static\s+)?func\s+\w+\s*\([^)]*\)\s*(?:->\s*([\w\.]+))?\s*:")
RE_NEW    = re.compile(r"^\s*(?:var\s+)?([A-Za-z_]\w*)\s*(?::\s*[\w\[\], ]+\s*)?:?=\s*([A-Z]\w*)\.new\([^)]*\)")
RE_NAME   = re.compile(r"\b([A-Za-z_]\w*)\.name\s*=")
RE_ADD    = re.compile(r"\.?add_child\(\s*([A-Za-z_]\w*)\s*[\),]")
RE_INLINE = re.compile(r"\.?add_child\(\s*([A-Z]\w*)\.new\(")
RE_RETURN = re.compile(r"^\s*return\s+([A-Za-z_]\w*)\s*$")


def split_functions(lines):
    """[(start_index, return_type|None, body_lines)] — по func/static func с col 0/отступом."""
    funcs, start, ret = [], None, None
    for i, line in enumerate(lines):
        m = RE_FUNC.match(line)
        if m:
            if start is not None:
                funcs.append((start, ret, lines[start:i]))
            start, ret = i, m.group(1)
    if start is not None:
        funcs.append((start, ret, lines[start:]))
    return funcs


def lint_file(path):
    issues = []
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")

    for fstart, ret_type, body in split_functions(lines):
        created = {}        # ident -> (lineno, type)
        named = set()
        added = set()
        returned = set()

        for off, line in enumerate(body):
            ln = fstart + off + 1
            m = RE_NEW.match(line)
            if m and m.group(2) != "Object":
                created[m.group(1)] = (ln, m.group(2))
            for nm in RE_NAME.finditer(line):
                named.add(nm.group(1))
            for ad in RE_ADD.finditer(line):
                added.add(ad.group(1))
            for inl in RE_INLINE.finditer(line):
                issues.append((ln, "инлайн add_child(%s.new()) — всегда анонимная нода" % inl.group(1)))
            rm = RE_RETURN.match(line)
            if rm:
                returned.add(rm.group(1))

        for ident, (ln, typ) in created.items():
            if ident in named:
                continue
            if ident in added:
                issues.append((ln, "%s := %s.new() добавлен в дерево без .name" % (ident, typ)))
            elif ident in returned and (ret_type in NODE_TYPES):
                issues.append((ln, "%s := %s.new() возвращается (-> %s) без .name" % (ident, typ, ret_type)))

    return sorted(issues)


def iter_gd(paths):
    for p in paths:
        if os.path.isfile(p) and p.endswith(".gd"):
            yield p
        elif os.path.isdir(p):
            for root, _dirs, files in os.walk(p):
                if ".godot" in root:
                    continue
                for f in files:
                    if f.endswith(".gd"):
                        yield os.path.join(root, f)


def main(argv):
    paths = argv[1:] or ["scripts"]
    total = 0
    for path in sorted(iter_gd(paths)):
        issues = lint_file(path)
        if issues:
            rel = path.replace("\\", "/")
            for ln, msg in issues:
                print("%s:%d: %s" % (rel, ln, msg))
            total += len(issues)
    if total:
        print("\nБезымянных нод: %d (задай node.name после .new())" % total)
        return 1
    print("Все программные ноды именованы ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
