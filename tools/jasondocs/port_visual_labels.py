from __future__ import annotations

import colorsys
from typing import Any

LANGUAGES = ("en", "ru", "kz")

COLOR_WORDS = {
    "red": {"en": "Red", "ru": "\u041a\u0440\u0430\u0441\u043d\u044b\u0439", "kz": "\u049a\u044b\u0437\u044b\u043b"},
    "orange": {"en": "Orange", "ru": "\u041e\u0440\u0430\u043d\u0436\u0435\u0432\u044b\u0439", "kz": "\u049a\u044b\u0437\u0493\u044b\u043b\u0442 \u0441\u0430\u0440\u044b"},
    "yellow": {"en": "Yellow", "ru": "\u0416\u0451\u043b\u0442\u044b\u0439", "kz": "\u0421\u0430\u0440\u044b"},
    "green": {"en": "Green", "ru": "\u0417\u0435\u043b\u0451\u043d\u044b\u0439", "kz": "\u0416\u0430\u0441\u044b\u043b"},
    "turquoise": {"en": "Turquoise", "ru": "\u0411\u0438\u0440\u044e\u0437\u043e\u0432\u044b\u0439", "kz": "\u041a\u04e9\u0433\u0456\u043b\u0434\u0456\u0440"},
    "blue": {"en": "Blue", "ru": "\u0421\u0438\u043d\u0438\u0439", "kz": "\u041a\u04e9\u043a"},
    "violet": {"en": "Violet", "ru": "\u0424\u0438\u043e\u043b\u0435\u0442\u043e\u0432\u044b\u0439", "kz": "\u041a\u04af\u043b\u0433\u0456\u043d"},
    "lilac": {"en": "Lilac", "ru": "\u0421\u0438\u0440\u0435\u043d\u0435\u0432\u044b\u0439", "kz": "\u0410\u0448\u044b\u049b \u043a\u04af\u043b\u0433\u0456\u043d"},
    "pink": {"en": "Pink", "ru": "\u0420\u043e\u0437\u043e\u0432\u044b\u0439", "kz": "\u049a\u044b\u0437\u0493\u044b\u043b\u0442"},
    "gray": {"en": "Gray", "ru": "\u0421\u0435\u0440\u044b\u0439", "kz": "\u0421\u04b1\u0440"},
}

SIDE_WORDS = {
    "left": {"en": "on the left", "ru": "\u0441\u043b\u0435\u0432\u0430", "kz": "\u0441\u043e\u043b \u0436\u0430\u049b\u0442\u0430"},
    "right": {"en": "on the right", "ru": "\u0441\u043f\u0440\u0430\u0432\u0430", "kz": "\u043e\u04a3 \u0436\u0430\u049b\u0442\u0430"},
    "top": {"en": "at the top", "ru": "\u0441\u0432\u0435\u0440\u0445\u0443", "kz": "\u0436\u043e\u0493\u0430\u0440\u044b\u0434\u0430"},
    "bottom": {"en": "at the bottom", "ru": "\u0441\u043d\u0438\u0437\u0443", "kz": "\u0442\u04e9\u043c\u0435\u043d\u0434\u0435"},
    "inside": {"en": "inside", "ru": "\u0432\u043d\u0443\u0442\u0440\u0438", "kz": "\u0456\u0448\u0456\u043d\u0434\u0435"},
}


def _rgb(hex_color: str) -> tuple[float, float, float]:
    value = hex_color.lstrip("#")[:6]
    if len(value) != 6:
        raise ValueError(f"invalid port color: {hex_color}")
    return tuple(int(value[index:index + 2], 16) / 255.0 for index in (0, 2, 4))


def color_family(hex_color: str) -> str:
    red, green, blue = _rgb(hex_color)
    hue, lightness, saturation = colorsys.rgb_to_hls(red, green, blue)
    degrees = hue * 360.0
    if saturation < 0.16:
        return "gray"
    if degrees < 15 or degrees >= 345:
        return "red"
    if degrees < 48:
        return "orange"
    if degrees < 72:
        return "yellow"
    if degrees < 165:
        return "green"
    if degrees < 195:
        return "turquoise"
    if degrees < 225:
        return "blue"
    if degrees < 285:
        return "lilac" if lightness >= 0.74 else "violet"
    if degrees < 345:
        return "pink"
    return "red"


def _linear(channel: float) -> float:
    return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4


def contrast_with_white(hex_color: str) -> float:
    luminance = sum(weight * _linear(channel) for weight, channel in zip((0.2126, 0.7152, 0.0722), _rgb(hex_color)))
    return 1.05 / (luminance + 0.05)


def accessible_text_color(hex_color: str, minimum: float = 4.5) -> str:
    red, green, blue = _rgb(hex_color)
    hue, lightness, saturation = colorsys.rgb_to_hls(red, green, blue)
    while lightness > 0.0:
        candidate = colorsys.hls_to_rgb(hue, lightness, saturation)
        result = "#" + "".join(f"{round(channel * 255):02x}" for channel in candidate)
        if contrast_with_white(result) >= minimum:
            return result
        lightness -= 0.01
    return "#000000"


def describe_port_visual(hex_color: str, side: str) -> dict[str, Any]:
    family = color_family(hex_color)
    color_label = COLOR_WORDS[family]
    side_label = SIDE_WORDS[side]
    verbal_label = {
        "en": f"{color_label['en']} port {side_label['en']}",
        "ru": f"{color_label['ru']} \u043f\u043e\u0440\u0442 {side_label['ru']}",
        "kz": f"{color_label['kz']} \u043f\u043e\u0440\u0442 {side_label['kz']}",
    }
    return {
        "color_family": family,
        "color_label": dict(color_label),
        "side_label": dict(side_label),
        "verbal_label": verbal_label,
        "text_color": accessible_text_color(hex_color),
    }
