# Public JasonDocs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a polished Russian documentation pilot for five Neuralese nodes at `neuralese.asia/docs`, generated from the existing JasonDocs source of truth.

**Architecture:** `neuralese-builder/JasonDocs` remains the only hand-edited source for node descriptions and icons. A deterministic landing build script selects five node IDs from the generated runtime catalog, validates their Russian content and icons, and writes a static browser-safe catalog consumed by a focused React documentation page; no runtime GitHub or backend request is introduced.

**Tech Stack:** Python 3 JasonDocs tooling and tests, JSON Schema, React 19, TypeScript 5.8, Vite 6, Node.js 22 built-in test runner, existing landing CSS and assets.

## Global Constraints

- Publish only `input_1d`, `layer`, `neuron`, `softmax`, and `classifier`.
- Russian is the only language edited in this task; existing English and Kazakh text remains unchanged.
- Edit only the `docs` section in `JasonDocs/*/node.json`; never hand-edit `generated`.
- Do not change node behavior, graph serialization, YAML DSL, training, API, Godot UI, or built-in tutorials.
- Do not add a router, runtime GitHub request, runtime Neuralese API request, analytics, search, accounts, comments, or translation.
- Keep `/` visually and behaviorally unchanged.
- Support both `/docs` and `/docs/`.
- Fail the documentation build when a selected node, required Russian field, generated port/setting description, or icon is missing.
- Use the existing Neuralese logo, node icons, typography, CSS variables, Navbar, and Footer.
- Keep the page light, work-focused, responsive, and free of horizontal document scrolling.
- Do not deploy or merge before the five texts are reviewed by the task owner and Arys.

---

## File Map

### `neuralese-builder`

- Modify `JasonDocs/input_1d/node.json`: child- and teacher-friendly Russian Input1D documentation.
- Modify `JasonDocs/layer/node.json`: child- and teacher-friendly Dense layer documentation.
- Modify `JasonDocs/neuron/node.json`: child- and teacher-friendly activation documentation.
- Modify `JasonDocs/softmax/node.json`: child- and teacher-friendly Softmax documentation.
- Modify `JasonDocs/classifier/node.json`: child- and teacher-friendly output-label documentation.
- Create `tests/jasondocs/test_public_docs_content.py`: strict content gate for the five public Russian documents.
- Regenerate `resources/node_info_catalog.json`: existing runtime catalog, produced only by `tools.jasondocs`.

### `neuralese-landing`

- Create `docs/published-node-ids.json`: presentation order containing node IDs only.
- Create `scripts/sync-jason-docs.mjs`: deterministic validator/exporter from Builder to browser assets.
- Create `tests/sync-jason-docs.test.mjs`: exporter tests using isolated fixtures.
- Create `public/docs-data/catalog.json`: generated public snapshot.
- Create `public/docs-data/icons/*.png`: copied JasonDocs icons for the five published nodes.
- Create `src/docs/types.ts`: browser catalog TypeScript types.
- Create `src/docs/catalog.ts`: fetch and runtime validation boundary.
- Create `src/pages/DocsPage.tsx`: documentation navigation and article rendering.
- Modify `src/App.tsx`: pathname switch that preserves the existing root page.
- Modify `src/components/Navbar.tsx`: optional link prefix with existing behavior as the default.
- Modify `src/index.css`: scoped `.docs-*` styles using existing landing tokens.
- Modify `package.json`: `docs:sync` and `test` scripts.
- Modify `.github/workflows/deploy.yml`: private Builder checkout, JasonDocs validation, deterministic export, tests, and build.
- Modify `.env.example`: document local Builder source path only; no secret values.
- Modify `README.md`: authoring and local verification commands.

---

### Task 1: Lock the Five Russian JasonDocs Documents

**Files:**
- Create: `tests/jasondocs/test_public_docs_content.py`
- Modify: `JasonDocs/input_1d/node.json`
- Modify: `JasonDocs/layer/node.json`
- Modify: `JasonDocs/neuron/node.json`
- Modify: `JasonDocs/softmax/node.json`
- Modify: `JasonDocs/classifier/node.json`
- Regenerate: `resources/node_info_catalog.json`

**Interfaces:**
- Consumes: existing JasonDocs `docs` and `generated` schema.
- Produces: five complete Russian documents available through `resources/node_info_catalog.json`.

- [ ] **Step 1: Write the failing public-content test**

Create a parametrized Python test with:

```python
PUBLIC_NODE_IDS = ("input_1d", "layer", "neuron", "softmax", "classifier")
FORBIDDEN_RUSSIAN_FRAGMENTS = (
    "данные типа ",
    "совместимым следующим узлам",
    "через вход ",
    "настроенные значения",
)

def test_public_node_has_complete_russian_copy(node_id: str) -> None:
    document = json.loads((ROOT / "JasonDocs" / node_id / "node.json").read_text())
    docs = document["docs"]
    required = (
        docs["title"]["ru"],
        docs["summary"]["ru"],
        docs["operation"]["ru"],
        docs["compact"]["body"]["ru"],
    )
    assert all(text.strip() for text in required)
    assert not any(fragment in " ".join(required).lower()
                   for fragment in FORBIDDEN_RUSSIAN_FRAGMENTS)
    for item in (*docs["ports"].values(), *docs["settings"].values()):
        assert item["label"]["ru"].strip()
        assert item["description"]["ru"].strip()
    assert docs["examples"]
    assert all(example["body"]["ru"].strip() for example in docs["examples"])
```

Add a second test that deep-copies `generated` before a `python -m tools.jasondocs sync --dry-run` subprocess and asserts the five generated sections remain byte-for-byte equal.

- [ ] **Step 2: Run the content test and verify the current generic copy fails**

Run:

```bash
python -m pytest tests/jasondocs/test_public_docs_content.py -q
```

Expected: failures for empty `examples` and generic Russian port wording.

- [ ] **Step 3: Write the five Russian documents**

Use these factual teaching goals:

```text
input_1d:
  Explain that each row becomes a one-dimensional feature vector.
  Explain RunModel as the model-context connection, not training data.
  Explain input_out as the feature vector passed into the first processing node.
  Explain feature names/types and the visible group title.
  Example chain: Input1D -> Dense layer.

layer:
  Explain that a Dense layer combines all incoming values into configured neurons.
  Distinguish its main data input/output from the activation-configuration connection.
  Explain neuron_count as capacity, with the overfitting/complexity caveat.
  Example chain: Input1D -> Dense layer -> output labels, with activation attached.

neuron:
  Explain that this node selects the activation function used by a layer.
  State that it is configuration, not a main left-to-right data-processing block.
  Explain ReLU/Tanh/Sigmoid choices without claiming a universal best option.
  Example: attach ReLU activation to a Dense layer.

softmax:
  Explain converting class scores into comparable probabilities that sum to about 1.
  State that it belongs near the classification output, not between every layer.
  Explain that shape is preserved and largest probability is the model's strongest guess.
  Example chain: final Dense layer -> Softmax -> output labels.

classifier:
  Explain mapping final output positions to readable class labels.
  Explain that label count/order must match the model output.
  Explain visible title and label_names settings.
  Example: three output values mapped to setosa, versicolor, virginica.
```

Only Russian values and `docs.examples` Russian bodies may change. Preserve the complete `generated` objects and existing English/Kazakh strings.

- [ ] **Step 4: Regenerate and validate the runtime catalog**

Run:

```bash
python -m tools.jasondocs sync --dry-run
python -m tools.jasondocs runtime
python -m tools.jasondocs validate
python -m pytest tests/jasondocs/test_public_docs_content.py tests/jasondocs/test_runtime_catalog.py -q
```

Expected: all commands exit `0`; runtime catalog includes the revised Russian fields.

- [ ] **Step 5: Run the existing Godot catalog test**

Run:

```bash
tests/godot/run_all.sh
```

Expected: the JasonDocs/Godot catalog suite exits `0`.

- [ ] **Step 6: Commit the source-of-truth content**

```bash
git add JasonDocs/input_1d/node.json JasonDocs/layer/node.json \
  JasonDocs/neuron/node.json JasonDocs/softmax/node.json \
  JasonDocs/classifier/node.json resources/node_info_catalog.json \
  tests/jasondocs/test_public_docs_content.py
git commit -m "docs: polish five public node guides"
```

---

### Task 2: Build a Deterministic JasonDocs Exporter

**Files:**
- Create: `docs/published-node-ids.json`
- Create: `scripts/sync-jason-docs.mjs`
- Create: `tests/sync-jason-docs.test.mjs`
- Modify: `package.json`
- Create: `public/docs-data/catalog.json`
- Create: `public/docs-data/icons/input_1d.png`
- Create: `public/docs-data/icons/layer.png`
- Create: `public/docs-data/icons/neuron.png`
- Create: `public/docs-data/icons/softmax.png`
- Create: `public/docs-data/icons/classifier.png`

**Interfaces:**
- Consumes: `JASONDOCS_SOURCE/resources/node_info_catalog.json`, `JASONDOCS_SOURCE/JasonDocs/<node_id>/icon.png`, and ordered node IDs.
- Produces: `syncJasonDocs({ sourceRoot, outputRoot, publishedIdsPath }): Promise<PublicCatalog>` and static `/docs-data/catalog.json`.

- [ ] **Step 1: Write exporter tests**

Use `node:test`, `node:assert/strict`, and temporary directories. Cover:

```javascript
test("exports only configured nodes in configured order", async () => {
  const result = await syncJasonDocs(fixtureOptions);
  assert.deepEqual(result.nodes.map((node) => node.id), [
    "input_1d", "layer", "neuron", "softmax", "classifier",
  ]);
});

test("fails when required Russian copy is empty", async () => {
  await assert.rejects(
    () => syncJasonDocs(invalidRussianFixture),
    /input_1d.*docs\.summary\.ru/,
  );
});

test("fails when a selected icon is missing", async () => {
  await assert.rejects(
    () => syncJasonDocs(missingIconFixture),
    /classifier.*icon\.png/,
  );
});

test("writes deterministic catalog bytes", async () => {
  await syncJasonDocs(fixtureOptions);
  const first = await readFile(catalogPath, "utf8");
  await syncJasonDocs(fixtureOptions);
  assert.equal(await readFile(catalogPath, "utf8"), first);
});
```

- [ ] **Step 2: Run the exporter test and verify it fails before implementation**

Run:

```bash
node --test tests/sync-jason-docs.test.mjs
```

Expected: module-not-found failure for `scripts/sync-jason-docs.mjs`.

- [ ] **Step 3: Implement the exporter**

Export only browser-required fields:

```typescript
type PublicNodeDoc = {
  id: string;
  iconUrl: string;
  title: string;
  summary: string;
  operation: string;
  compact: string;
  ports: Array<{
    id: string;
    direction: "input" | "output";
    label: string;
    description: string;
    datatypes: string[];
    configConnection: boolean;
  }>;
  settings: Array<{
    id: string;
    label: string;
    description: string;
    defaultValue: unknown;
    options: unknown[];
  }>;
  examples: string[];
};
```

Join authored docs to generated ports/settings by their existing IDs. Reject missing records and required Russian strings with a path-specific error. Copy each icon to `public/docs-data/icons/<node_id>.png`, write `catalog.json` with a final newline, and avoid timestamps or machine-specific paths.

- [ ] **Step 4: Add scripts and generate the real snapshot**

Add:

```json
"docs:sync": "node scripts/sync-jason-docs.mjs",
"test": "node --test tests/*.test.mjs"
```

Run:

```bash
JASONDOCS_SOURCE=/Users/alim/.codex/worktrees/neuralese-docs-page/builder npm run docs:sync
npm test
```

Expected: five nodes and five real icons are written; tests pass.

- [ ] **Step 5: Commit the exporter and generated snapshot**

```bash
git add docs/published-node-ids.json scripts/sync-jason-docs.mjs \
  tests/sync-jason-docs.test.mjs package.json package-lock.json \
  public/docs-data
git commit -m "feat: generate public docs from JasonDocs"
```

---

### Task 3: Add a Typed Browser Catalog Boundary

**Files:**
- Create: `src/docs/types.ts`
- Create: `src/docs/catalog.ts`
- Create: `tests/public-catalog.test.mjs`

**Interfaces:**
- Consumes: `/docs-data/catalog.json`.
- Produces: `loadPublicDocs(signal?: AbortSignal): Promise<PublicCatalog>` and `isPublicCatalog(value: unknown): value is PublicCatalog`.

- [ ] **Step 1: Write static catalog contract tests**

Load the committed JSON snapshot and assert:

```javascript
assert.equal(catalog.version, 1);
assert.equal(catalog.language, "ru");
assert.deepEqual(catalog.nodes.map(({ id }) => id), publishedIds);
for (const node of catalog.nodes) {
  assert.match(node.iconUrl, /^\/docs-data\/icons\/[a-z0-9_]+\.png$/);
  assert.ok(node.title && node.summary && node.operation);
  assert.ok(node.ports.every((port) => ["input", "output"].includes(port.direction)));
}
```

- [ ] **Step 2: Run the catalog test and verify it fails before the fixture helper is complete**

Run:

```bash
node --test tests/public-catalog.test.mjs
```

Expected: failure for the missing contract helper or invalid expected shape.

- [ ] **Step 3: Implement exact TypeScript types and runtime validation**

`catalog.ts` must:

```typescript
export async function loadPublicDocs(signal?: AbortSignal): Promise<PublicCatalog> {
  const response = await fetch("/docs-data/catalog.json", { signal });
  if (!response.ok) throw new Error(`Documentation request failed: ${response.status}`);
  const value: unknown = await response.json();
  if (!isPublicCatalog(value)) throw new Error("Documentation catalog has an invalid shape");
  return value;
}
```

Keep the runtime guard focused on fields actually rendered by the page. It must not silently coerce malformed content.

- [ ] **Step 4: Run tests and TypeScript**

Run:

```bash
npm test
npm run lint
```

Expected: all Node tests and `tsc --noEmit` pass.

- [ ] **Step 5: Commit the catalog boundary**

```bash
git add src/docs tests/public-catalog.test.mjs
git commit -m "feat: add typed public docs catalog"
```

---

### Task 4: Render `/docs` Without Changing `/`

**Files:**
- Create: `src/pages/DocsPage.tsx`
- Modify: `src/App.tsx`
- Modify: `src/components/Navbar.tsx`
- Modify: `src/index.css`

**Interfaces:**
- Consumes: `loadPublicDocs()` and existing `Navbar`/`Footer`.
- Produces: responsive `/docs` and `/docs/` views with five selectable articles.

- [ ] **Step 1: Add the pathname boundary with an unchanged root JSX subtree**

Normalize only trailing slashes:

```typescript
const pathname = window.location.pathname.replace(/\/+$/, "") || "/";
const isDocsPage = pathname === "/docs";
```

Move the existing root markup to a focused `LandingPage` component without editing its element order, classes, or content. Render `DocsPage` only for `isDocsPage`; unknown paths continue through the existing SPA behavior.

- [ ] **Step 2: Add optional Navbar link prefixing**

Use a default that preserves current URLs:

```typescript
type NavbarProps = { sectionBase?: string };
export function Navbar({ sectionBase = "" }: NavbarProps) {
  const sectionHref = (id: string) => `${sectionBase}#${id}`;
}
```

The landing passes no prop. The docs page passes `sectionBase="/"`.

- [ ] **Step 3: Implement the documentation page states**

Render:

- loading status with fixed dimensions;
- clear retryable error message;
- desktop node sidebar with real icons;
- mobile horizontal node picker;
- one selected article;
- title and summary;
- “Как проходит информация” with input, operation, and output;
- “Подключения” grouped into inputs and outputs;
- “Настройки” only when settings exist;
- “Примеры и важные замечания” only when examples exist;
- existing Footer.

Use semantic buttons, headings, `aria-current`, visible keyboard focus, and descriptive image alt text. Do not render raw internal IDs as primary labels.

- [ ] **Step 4: Add scoped responsive styles**

Add only `.docs-*` selectors using existing CSS variables. Required stable layout:

```css
.docs-shell { min-height: 100vh; background: var(--background); color: var(--foreground); }
.docs-layout { display: grid; grid-template-columns: minmax(220px, 268px) minmax(0, 760px); }
.docs-node-icon { width: 96px; height: 96px; object-fit: contain; }
@media (max-width: 760px) {
  .docs-layout { display: block; }
  .docs-node-nav { display: flex; overflow-x: auto; }
  .docs-flow { grid-template-columns: 1fr; }
}
```

Use the landing's light theme, blue accent, border color, `Instrument Sans`, and `Fraunces`. Cards stay at `8px` radius or less. No gradient, bokeh, decorative hero, or nested cards.

- [ ] **Step 5: Run static verification**

Run:

```bash
npm test
npm run lint
npm run build
```

Expected: all pass and `dist/docs-data` contains the catalog and five icons.

- [ ] **Step 6: Commit the route and UI**

```bash
git add src/App.tsx src/components/Navbar.tsx src/pages/DocsPage.tsx src/index.css
git commit -m "feat: add public Neuralese node docs page"
```

---

### Task 5: Guard CI Generation and Document the Workflow

**Files:**
- Modify: `.github/workflows/deploy.yml`
- Modify: `.env.example`
- Modify: `README.md`

**Interfaces:**
- Consumes: GitHub secret `NEURALESE_BUILDER_READ_TOKEN`.
- Produces: a deployment that cannot publish stale or incomplete selected docs.

- [ ] **Step 1: Add a read-only Builder checkout and validation**

Before installing/building the landing:

```yaml
- name: Checkout Neuralese Builder docs source
  uses: actions/checkout@v4
  with:
    repository: hex358/neuralese-builder
    ref: dev
    token: ${{ secrets.NEURALESE_BUILDER_READ_TOKEN }}
    path: .jasondocs-source

- name: Validate JasonDocs source
  run: |
    python -m tools.jasondocs validate
  working-directory: .jasondocs-source
```

The fine-grained token must have read-only Contents access to `hex358/neuralese-builder` and exist only in Actions Secrets.

- [ ] **Step 2: Regenerate before tests and production build**

Add:

```yaml
- name: Generate public documentation
  run: npm run docs:sync
  env:
    JASONDOCS_SOURCE: ${{ github.workspace }}/.jasondocs-source

- name: Test
  run: npm test

- name: Type check
  run: npm run lint
```

Keep deployment and live marker verification unchanged after the build.

- [ ] **Step 3: Document local authoring**

Document this exact flow:

```bash
cd /path/to/neuralese-builder
python -m tools.jasondocs runtime
python -m tools.jasondocs validate

cd /path/to/neuralese-landing
JASONDOCS_SOURCE=/path/to/neuralese-builder npm run docs:sync
npm test
npm run lint
npm run build
```

State that `public/docs-data` is generated, `JasonDocs/*/node.json` is authored, and CI requires the read-only token. `.env.example` may show `JASONDOCS_SOURCE=/absolute/path/to/neuralese-builder` but no credential.

- [ ] **Step 4: Validate workflow syntax and run the local equivalent**

Run:

```bash
JASONDOCS_SOURCE=/Users/alim/.codex/worktrees/neuralese-docs-page/builder npm run docs:sync
npm test
npm run lint
npm run build
git diff --check
```

Expected: all pass and a second sync produces no diff.

- [ ] **Step 5: Commit CI and authoring documentation**

```bash
git add .github/workflows/deploy.yml .env.example README.md
git commit -m "ci: validate JasonDocs before landing deploy"
```

---

### Task 6: Verify the Five-Node Pilot Visually and Semantically

**Files:**
- Review only: Builder and Landing changes from Tasks 1-5.

**Interfaces:**
- Consumes: production Vite build and the five JasonDocs records.
- Produces: review evidence without deployment.

- [ ] **Step 1: Run complete Builder verification**

```bash
python -m tools.jasondocs sync --dry-run
python -m tools.jasondocs runtime
python -m tools.jasondocs validate
python -m pytest tests/jasondocs -q
tests/godot/run_all.sh
git diff --check
```

Expected: all pass; no `generated` drift in the five `node.json` files.

- [ ] **Step 2: Run complete Landing verification**

```bash
JASONDOCS_SOURCE=/Users/alim/.codex/worktrees/neuralese-docs-page/builder npm run docs:sync
npm test
npm run lint
npm run build
git diff --check
```

Expected: all pass; five icons and five articles are in `dist/docs-data`.

- [ ] **Step 3: Start local preview**

```bash
npm run dev -- --host 127.0.0.1 --port 4173
```

Expected: Vite serves both `/` and `/docs`.

- [ ] **Step 4: Check desktop and mobile rendering**

Inspect `/` and `/docs` at:

- desktop `1440x900`;
- compact desktop `1024x768`;
- mobile `390x844`.

Verify:

- the root landing screenshot has no layout/content regression;
- all five icons render;
- each node button selects the matching article;
- focus states are visible;
- mobile node navigation scrolls horizontally;
- the document body has no horizontal overflow;
- direct `/docs` load and refresh work;
- console has no errors or failed requests.

- [ ] **Step 5: Perform the semantic review**

For each node, compare the article against its scene/script and generated port metadata. Confirm every sentence answers the practical role of the node without claiming behavior that is not present. Present the five articles to the task owner and Arys; apply accepted wording changes only in JasonDocs, regenerate, and rerun Steps 1-4.

- [ ] **Step 6: Stop before production publication**

Do not push, merge, or deploy until the task owner explicitly approves the five-node pilot. Record any remaining editorial disagreement as review feedback, not as duplicate text in the landing repository.
