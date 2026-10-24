from __future__ import annotations

import unittest

from tools.jasondocs.port_visual_labels import (
    accessible_text_color,
    color_family,
    contrast_with_white,
    describe_port_visual,
)


class PortVisualLabelTests(unittest.TestCase):
    def test_project_port_colors_have_expected_names(self) -> None:
        self.assertEqual(color_family("#ffb8f4"), "pink")
        self.assertEqual(color_family("#d1a3ff"), "lilac")
        self.assertEqual(color_family("#7673d9"), "violet")
        self.assertEqual(color_family("#4cabe6"), "blue")
        self.assertEqual(color_family("#fffc99"), "yellow")
        self.assertEqual(color_family("#a8a8a8"), "gray")

    def test_verbal_labels_are_real_unicode_text(self) -> None:
        self.assertEqual(describe_port_visual("#4cabe6", "bottom")["verbal_label"]["ru"], "\u0421\u0438\u043d\u0438\u0439 \u043f\u043e\u0440\u0442 \u0441\u043d\u0438\u0437\u0443")
        self.assertEqual(describe_port_visual("#ffb8f4", "left")["verbal_label"]["ru"], "\u0420\u043e\u0437\u043e\u0432\u044b\u0439 \u043f\u043e\u0440\u0442 \u0441\u043b\u0435\u0432\u0430")
        self.assertEqual(describe_port_visual("#d1a3ff", "left")["verbal_label"]["ru"], "\u0421\u0438\u0440\u0435\u043d\u0435\u0432\u044b\u0439 \u043f\u043e\u0440\u0442 \u0441\u043b\u0435\u0432\u0430")
        self.assertEqual(describe_port_visual("#7673d9", "right")["verbal_label"]["ru"], "\u0424\u0438\u043e\u043b\u0435\u0442\u043e\u0432\u044b\u0439 \u043f\u043e\u0440\u0442 \u0441\u043f\u0440\u0430\u0432\u0430")
        self.assertEqual(describe_port_visual("#4cabe6", "bottom")["verbal_label"]["en"], "Blue port at the bottom")

    def test_text_color_remains_readable_on_white(self) -> None:
        for color in ("#fffc99", "#a8a8a8", "#ffb8f4", "#d1a3ff"):
            text_color = accessible_text_color(color)
            self.assertGreaterEqual(contrast_with_white(text_color), 4.5)


if __name__ == "__main__":
    unittest.main()
