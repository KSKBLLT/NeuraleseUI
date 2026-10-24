---
name: ux-review
description: Deep UX audit of UI screenshots, views, and interaction flows based on UX laws (Fitts's Law, Hick's Law, Jakob's Law, Miller's Law) and the Nielsen Norman 10 Usability Heuristics. Evaluates cognitive load, choice overload, affordances, and outputs a structured findings report with a cognitive load score and a prioritized improvements matrix. Use when the user asks for a UX review, usability audit, heuristic evaluation, or UX critique of screenshots or interfaces.
---

# ux-review (Eagle-Skills)

A rigorous, psychology-grounded UX audit for interfaces, screens, and interaction flows. Evaluates interfaces against foundational UX laws, the Nielsen Norman 10 Usability Heuristics, and cognitive load theory.

---

## 1. Input Acquisition

1. **Screenshots / Images**:
   - Inspect single screens, comparison views, or complete user flows (e.g., onboarding, canvas interaction, settings, modals).
   - If multiple states exist (idle, hover, pressed, error, empty, filled), evaluate each state in the sequence.
2. **Interactive / Code Context**:
   - When inspecting UI code or scene definitions (`.tscn`, `.vue`, `.jsx`, `.xml`), verify sizes, paddings, tap targets, and accessibility hooks against the visual render.
3. **User Tasks & Mental Models**:
   - Identify the user's primary goal on this screen (e.g. "Run autoregression step", "Connect nodes", "Configure parameters").

---

## 2. Evaluation Rubric

### A. Core UX Laws

* **Fitts's Law (Reachability & Target Sizing)**:
  - $$T = a + b \log_2\left(\frac{2D}{W}\right)$$
  - Are primary action buttons large enough to hit without aiming strain? (Minimum $44 \times 44\text{ pt}$ for mobile, $32 \times 32\text{ px}$ for desktop with mouse).
  - Are destructive or secondary actions sufficiently separated from primary triggers?
  - Are frequent targets pinned to reachable edges, corners, or adjacent to the focal point?

* **Hick's Law (Decision Latency & Choice Overload)**:
  - $$T = b \log_2(n + 1)$$
  - Is the screen presenting too many choices simultaneously?
  - Does the interface apply progressive disclosure (hiding advanced/niche controls until needed)?
  - Are choices categorized, clustered, or pre-selected with sensible defaults?

* **Jakob's Law (Mental Models & Familiar Patterns)**:
  - Do controls behave like users expect from their operating system and industry standards?
  - Are icons unambiguous (e.g., ▶ for play/step, ⏸ for pause, ✕ for close, ↶ for undo)?
  - Are interaction conventions respected (e.g. sliders drag horizontally, modals have clear dismissals, primary actions are on the right/bottom)?

* **Miller's Law & Cognitive Chunking**:
  - Is information chunked into digestible groups ($7 \pm 2$ chunks max per functional area)?
  - Does visual grouping (Gestalt laws of proximity, common region, and similarity) guide user attention?

---

### B. Nielsen Norman 10 Usability Heuristics

1. **Visibility of system status**:
   - Immediate feedback for actions (button press states, spinners, progress indicators, active mode highlights).
2. **Match between system and real world**:
   - Natural language, metaphors, and units familiar to the domain (no leaking raw internal IDs or stack traces).
3. **User control and freedom**:
   - Clear "emergency exits" (Undo, Redo, Cancel, Reset, Close). Users must never feel trapped in a state or modal.
4. **Consistency and standards**:
   - Uniform terminology, colors, button styles, corner radii, and iconography across all screens.
5. **Error prevention**:
   - Guard rails against slips and mistakes (confirmations for destructive actions, disablement of invalid inputs, format validation).
6. **Recognition rather than recall**:
   - Visible options, contextual tips, and visible current values rather than requiring users to remember past steps.
7. **Flexibility and efficiency of use**:
   - Accelerators and shortcuts for experienced users, while remaining intuitive for novices.
8. **Aesthetic and minimalist design**:
   - High signal-to-noise ratio. Every element on screen must serve a distinct purpose. No decorative clutter.
9. **Help users recognize, diagnose, and recover from errors**:
   - Error messages in plain language, indicating precisely what happened and offering a constructive next step.
10. **Help and documentation**:
    - Contextual tooltips, inline hints, and accessible documentation for complex features.

---

## 3. Cognitive Load Scoring

Score the interface from **1 to 10** across three dimensions:

* **Intrinsic Cognitive Load**: Effort required to understand the core domain concept (e.g., machine learning tensors vs. simple text).
* **Germane Cognitive Load**: Helpful cognitive effort that builds user understanding (e.g., visual graphs, meaningful badges, live previews).
* **Extraneous Cognitive Load**: Harmful effort caused by poor UI, confusing navigation, visual noise, or missing feedback.

**Overall Cognitive Friction Score**:
- **1–3 (Low / Effortless)**: Clean, transparent interface; clear path to action; zero friction.
- **4–6 (Moderate / Manageable)**: Understandable with minor distractions or minor affordance ambiguities.
- **7–8 (High / Straining)**: Noticeable friction, cluttered choices, unclear button roles, or missing feedback.
- **9–10 (Critical / Cognitive Overload)**: Confusing, overwhelming, high error rate, user feels lost or intimidated.

---

## 4. Output Report Format

Always structure the UX audit as follows:

```markdown
# UX Review Report: [Screen / Feature Name]

## 1. Executive Summary & Cognitive Load
- **Cognitive Load Score**: [X / 10] ([Low / Moderate / High / Critical])
- **Overall Verdict**: [Summary evaluation in 2–3 sentences highlighting primary usability strengths and key pain points]

## 2. Heuristic & UX Law Findings

### 🔴 Critical / High Friction
- **[Finding Title]**
  - **Heuristic / Law**: [e.g., Fitts's Law / H1: Visibility of System Status]
  - **Observed Issue**: [Exact description of what happens on screen]
  - **User Impact**: [Why this causes error, hesitation, or fatigue]
  - **Recommendation**: [Concrete, actionable fix]

### 🟠 Moderate Friction
- **[Finding Title]**
  - ...

### 🟡 Minor Usability Polish
- **[Finding Title]**
  - ...

## 3. Improvements Matrix

| Impact | Effort | Recommendation | Affected Area |
| :--- | :--- | :--- | :--- |
| **High** | **Low** (Quick Win) | [Action] | [Component] |
| **High** | **High** (Major Fix) | [Action] | [Component] |
| **Low** | **Low** (Polish) | [Action] | [Component] |
| **Low** | **High** (Reconsider) | [Action] | [Component] |

## 4. Usability Strengths
- [2–4 specific things the design executes well and should preserve]
```
