# Robot images

Placeholders for the robot cards. Replace the PNG files with the final artwork,
keeping the file names (320 x 260, transparent background).

| File | Source | Licence / notes |
|---|---|---|
| `ev3.png` | [Lego Mindstorms EV3 brick.jpg](https://commons.wikimedia.org/wiki/File:Lego_Mindstorms_EV3_brick.jpg), Wikimedia Commons, by Klaus-Dieter Keller; cropped and scaled | CC BY-SA 3.0. The brick shows the LEGO and EV3 marks, which are LEGO Group trademarks. |
| `spike_prime.png` | `hub-spike-inventor.png` from the [Pybricks documentation](https://docs.pybricks.com/en/stable/hubs/primehub.html) (left hub); cropped and scaled | The page states no licence. The hub shows the LEGO mark (trademark). |
| `microbit.png` | `microbit-drawing-blue.png` from [microbit-foundation/microbit-svg](https://github.com/microbit-foundation/microbit-svg); scaled | The README says CC BY-NC-SA 4.0 (note: non-commercial), credit the micro:bit Educational Foundation (microbit.org) and follow the [brand guidelines](https://microbit.org/brand-guidelines/). |

## Drawings in `art/`

Top views of the robots (facing right), sensor pictures and wheels, rendered in
one colour from the official 3D models of the
[LDraw parts library](https://library.ldraw.org/) (CC BY 4.0) with
`tools/robot_art/` (`ldraw_fetch.py` downloads the parts, `build_robot_art.py` renders them; the
renderer draws a straight orthographic view, shades by surface angle and draws
the visible edges). Colour is applied in the game.

| File | Parts (LDraw file, main author) |
|---|---|
| `ev3_base_top.png` | EV3 brick 95646c01, large motors 95658, wheels 56145c03 (Philippe Hurbain [Philo]; wheel by Takeshi Takahashi [RainbowDolphin]) |
| `spike_base_top.png` | SPIKE Prime hub 45601c01, medium angular motors 54696p01, wheels 39367p01 (Philippe Hurbain [Philo]) |
| `ev3_ultrasonic_top.png`, `ev3_ultrasonic_front.png` | EV3 ultrasonic sensor 95652 (Philippe Hurbain [Philo]) |
| `spike_distance_top.png`, `spike_distance_front.png` | Powered Up distance sensor 37316 (Philippe Hurbain [Philo]) |
| `ev3_large_motor_side.png`, `spike_motor_side.png` | 95658, 54696p01 (Philippe Hurbain [Philo]) |
| `wheel_ev3_56.png`, `wheel_spike_56.png` | 56145c03, 39367p01 |
| `microbit_base_top.png` | The micro:bit drawing above (CC BY-NC-SA 4.0, micro:bit Educational Foundation), made single-colour, with LDraw wheels 39367p01. Stylised: robots built around a micro:bit differ. |

`robots_art.json` holds, per base, the image's pixels per centimetre, the
robot's length and wheel track, the wheel size and where the wheels are drawn.
The robot window takes every conversion between the training world and the room
from these lengths.

Credit for the LDraw parts used (authors of the files the renders are built
from): Philippe Hurbain [Philo], Willy Tschager [Holly-Wood], James Jessiman,
Magnus Forsberg [MagFors], Alex Taylor [anathema], Steve Bliss [sbliss], Max
Martin Richter [MMR1988], Mark Kennedy [mkennedy], Paul Easter [pneaster], Marc
Klein [marckl], Niels Karsdorp [nielsk], Michael Heidemann [mikeheide], Franklin
W. Cain [fwcain], Steffen [Steffen], Max Murtazin [SwampKryakwa], Chris Dee
[cwdee], J.C. Tchang [tchang], Donald Sutter [technog], Orion Pobursky
[OrionP], Tim Gould [timgould], Santeri Piippo [arezey], Massimo Maso [Sirio],
Damien Roux [Darats], Travis Cobbs [tcobbs], Tore Eriksson [Tore_Eriksson],
Takeshi Takahashi [RainbowDolphin], Kevin Clague [kclague], Gerald Lasser
[GeraldLasser]. LDraw is a trademark of the Estate of James Jessiman. LEGO is a
trademark of the LEGO Group, which does not sponsor or endorse this use.
