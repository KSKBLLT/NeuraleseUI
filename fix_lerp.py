import re
import os

files = [
    "scripts/adraw.gd", "scripts/base_graph.gd", "scripts/block_component.gd", "scripts/bubble_unit_legacy.gd",
    "scripts/camera_2d.gd", "scripts/ccc.gd", "scripts/connection.gd", "scripts/conv_2d.gd",
    "scripts/detatch_menu.gd", "scripts/gview.gd", "scripts/hourglass.gd", "scripts/input_1d.gd",
    "scripts/io_graph.gd", "scripts/lesson_header.gd", "scripts/mist.gd", "scripts/quest.gd",
    "scripts/selector_box.gd", "scripts/splash_menu.gd", "scripts/submenu.gd", "scripts/train_input.gd",
    "scripts/train_rl.gd", "scripts/ui_manager.gd", "scripts/virtualt.gd"
]

def fix_line(line):
    if "lerp" in line and ("delta" in line or "get_process_delta_time" in line) and "minf" not in line and "clamp" not in line:
        new_line = re.sub(r'(,\s*)([^,\(\)]*(?:delta|get_process_delta_time\(\))[^,\(\)]*)(\))', r'\1minf(1.0, \2)\3', line)
        return new_line
    return line

for fpath in files:
    if not os.path.exists(fpath): continue
    with open(fpath, "r", encoding="utf-8") as f:
        lines = f.readlines()
        
    changed = False
    for i in range(len(lines)):
        orig = lines[i]
        fixed = fix_line(orig)
        if orig != fixed:
            print(f"File {fpath}:{i+1}\n- {orig.strip()}\n+ {fixed.strip()}\n")
            lines[i] = fixed
            changed = True
            
    if changed:
        with open(fpath, "w", encoding="utf-8") as f:
            f.writelines(lines)
