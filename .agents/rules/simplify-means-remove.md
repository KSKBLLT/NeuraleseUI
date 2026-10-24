---
name: simplify-means-remove
description: The user means "simplify" literally - fewer elements, fewer states, less code; hiding something behind a condition is not a simplification
metadata:
  type: feedback
---
When I called "show the battery tag only when low, the distance only when measured" a simplification of the robot cards, the user objected (2026-10-14): a visual that turns on conditionally adds a state and code; it is not simpler.

**Why:** the user asked for an interface anyone understands without learning it. Elements that sometimes appear and sometimes don't make the screen less predictable, and the condition is more code to maintain.

The user's definition: **simple = less text, and less information the person has to know outside their own model of the thing.** Conditional flags are not UI simplifications; when simplifying or smoothing something, optimise toward fewer words and fewer concepts, not toward more conditions.

**How to apply:** "simplify" = delete the element (and its code), or move its one useful job to the place it is needed (e.g. low battery as a warning when connecting, which already exists). Call conditional visibility what it is ("hide X unless Y") and justify it separately. What the user needs stays even if it is "extra" (the robot card keeps its distance tag: needed to pick the right robot). Related: [[robot-ui-rejected-2-of-10]].
