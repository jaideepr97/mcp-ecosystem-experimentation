# Conference talk — consolidated talking points

Working list for a talk framed as **using AI to accelerate learning** (collaboration over delegation), with the **empty Kind → production-shaped MCP stack** as the vessel. Refine or cut to fit slot length and audience.

---

## Core narrative

- **Thesis:** AI as a **learning and integration accelerator**, not a substitute for judgment — collaboration over delegation.
- **Vessel:** Incremental experiment from empty Kind to catalog → operator → gateway → identity → policy → TLS → Vault → namespace isolation, VirtualMCPServers, credential injection.
- **Audience gets:** Mental model of **where MCP platforms break at integration seams**, plus a **repeatable interaction pattern** for deep dives on complex systems.
- **Balance:** Open with the human–AI frame and return at transitions; keep **concrete seams, friction, and one tight demo** so the talk is not only “soft” meta.

**One-liner option:** *I didn’t delegate the architecture to the model; I used it to run faster through the loop: hypothesize → deploy → fail → explain why.*

---

## Thread A — Technical story

1. **Hook:** Empty cluster → first meaningful `tools/call` through the gateway.
2. **Integration map (one slide):** catalog → launcher → MCPServer → operator (Deployment, Service, HTTPRoute, MCPServerRegistration) → broker/router → AuthPolicy layers → Vault.
3. **Layer complexity at each seam:** operator↔gateway registration; catalog→deploy gap (metadata vs OCI reality); auth evolution (pedagogical mini-oidc → production-shaped stack); filter chain order for per-tool auth.
4. **`team-a` beat:** Namespace isolation; VirtualMCPServer as **presentation** vs AuthPolicy as **enforcement**; Vault injection patterns.
5. **Close:** Friction register + alignment with upstream **Auth Phase 2** thinking + what transfers vs what changes on OpenShift AI (if applicable — Kind is the lab; OCP AI is escalation unless you have a live demo).

---

## Thread B — How AI was used

Draw from `docs/experimentation.md` — **Reflection: How AI Was Used** and **Author’s personal insights**.

- Broad question → minimal deploy → deep trace → clarifying questions → visualizations → scoped increments → push back on over-engineering.
- Later: adapt stale PR vs rewrite; **decompose** upstream `make` targets before applying; **durability filter** (temporary vs lasting changes); **architectural separation** (e.g. launcher not owning gateway resources); pivot (e.g. device flow vs Inspector rabbit hole); **exhaustive matrices**; **grep all occurrences** for shared constants; **three branches** as a complexity ladder.
- Personal insights: driver’s seat; skepticism; trust/control; collaborative vs delegatory posture; “thinking out loud.”

---

## Empirical / quotable numbers (from repo)

- `docs/experimentation.md`: on the order of **~2000+ lines**; **50** numbered key learnings (see doc).
- `docs/friction-points.md`: **23** friction entries + summary by category.
- **Verification:** e.g. **30/30** auth matrix (Phase 13, in changes-tracker); **14/14** team-a matrix + credential checks (README / progress).
- `scripts/test-pipeline.sh`: **10** high-level test phases; script is **~600+ lines** — evidence of systematic verification vs one-off manual checks.
- **Setup:** README **~10 minutes** full bring-up; `guided-setup.sh` exposes **6** user-facing phases (aggregated from larger infra).
- **Forks:** One custom operator image addressing **two** gaps (gateway wiring + `credentialRef` / spec overwrite).

---

## Git timeline / velocity (for slides — state caveats)

**Facts from `main` (as of documentation time):**

| Signal | Value |
|--------|--------|
| First commit | 2026-04-01 ~15:42 -0400 |
| Latest commit | 2026-04-05 ~18:35 -0400 |
| Wall clock (first → last commit) | **~4 days 3 hours** |
| Commits on `main` | **33** |
| Commits per day | Apr 1: 7 · Apr 2: 3 · Apr 3: **14** · Apr 4: 6 · Apr 5: 3 |

**Caveats when presenting:**

- Commits are **checkpoints**, not logged hours; heavy days don’t prove full-day focus.
- **First commit** already describes a reproducible experiment — repo may **not** be “day zero” of thinking or uncommitted iteration.
- A **full calendar week** of effort may still be fair if you include prep, reading, or work outside this repo.

**“Without AI” — use only as an honest range, not a measured ratio:**

- Same **depth** for an experienced platform engineer (strong K8s): often **~2×–4×** **focused** engineering time vs with AI assistance (scaffolding, YAML, cross-file edits, first-pass explanations) — **illustrative**, not measured.
- If also **learning** several stacks cold: **~4×–8×** is plausible for time-to-same confidence — **high variance**.
- **Do not** claim a controlled experiment; say clearly that **hours were not logged** and any multiplier is a **gut estimate**.

**Sample honest slide copy:** *From first to last commit on `main`, about **five calendar days** and **33** commits; one day had **14**. I didn’t log hours. My sense is reaching the same integration depth and docs without AI would have taken **several times longer** — mostly shorter iteration loops and less mechanical work, not “the model designed the system.”*

---

## Genuinely less common angles

- **Annotation-driven** operator extension + **reconciler replaces whole spec** as an integration failure mode.
- **Envoy filter order** (ext_proc before auth) as the key to per-tool authorization — wrong mental model corrected with `config_dump` / logs.
- **Three failed JWT extraction approaches** before the working CEL path — AI doesn’t eliminate API-surface trial and error.
- **VirtualMCPServer controller / namespace** paper cut for multi-tenant Kind setups.
- **Honest limitations:** `tools/list` vs `tools/call`, 500 vs 403, env-var-only MCP servers.
- **Independent reasoning** that lines up with upstream **Auth Phase 2** (VirtualMCPServer / CEL / client headers) — research-style beat.

---

## Personas / governance (optional segment)

- `docs/persona-flows.md`: Platform engineer vs AI engineer; bridge table; **six deployment patterns** — use for “where do we draw the boundary?” without only showing YAML.

---

## OpenShift AI / production escalation

- Kind = **fast integration lab**; OpenShift AI = **escalation** (HA, real ingress/DNS, tenancy, operations) tied to e.g. RHAISTRAT-1149 — only claim live OCP AI if you have it.

---

## Abstract — learning / collaboration framing (latest draft)

**Title (optional):** *Collaboration, Not Delegation: Using AI to Learn a Production-Shaped MCP Stack on Kubernetes*

Large language models are often framed as code generators. This talk describes a different use: **using AI to accelerate *learning*** while staying in the driver’s seat—treating the assistant as a collaborator for exploration, integration, and verification, not as the owner of architecture or tradeoffs. The story is grounded in a concrete experiment: starting from an **empty Kind cluster** and incrementally building a **production-adjacent MCP ecosystem**—catalog discovery, lifecycle-operator deployment, mcp-gateway routing, identity and policy (Keycloak and Kuadrant), TLS, Vault-backed credential patterns, and namespace-isolated multi-tenancy—until the pieces behave like a real platform integration problem rather than a toy demo.

Along the way, the focus is on **how** the work was done: minimal-first deployments, letting failures drive deep questions (“is this a bug or an intentional platform constraint?”), decomposing opaque upstream automation, adapting prior art instead of rewriting it, enforcing separation of concerns when shortcuts worked but mis-modeled the system, and replacing “it works once” with **exhaustive test matrices** and reproducible scripts. The technical outcomes matter—integration seams, a structured friction register, and honest limits of Phase‑1 patterns—but the through-line is **collaboration over delegation**: what the human had to supply (scope, skepticism, durability, judgment) and what the AI made cheaper (breadth, boilerplate, cross-component context).

Attendees will leave with a clearer mental model of **where MCP platforms break across project boundaries**, and a **repeatable interaction pattern** for using AI to learn complex distributed systems without outsourcing the thinking.

### Short variant (~100 words)

I used AI not to “ship code,” but to **learn faster**—as a collaborator for deploy–fail–explain loops, cross-component tracing, and systematic verification. This talk uses one experiment as the vessel: from an **empty Kind cluster** to a **production-shaped MCP stack** (catalog, operator, gateway, identity, policy, TLS, Vault, multi-tenant isolation). I emphasize **collaboration over delegation**: scope, skepticism, and architectural judgment stayed human; the model accelerated breadth, YAML mechanics, and integration debugging. You’ll get concrete integration lessons **and** a repeatable pattern for deep learning on messy platforms.

---

## Abstract — stack-centric (alternate for infra-heavy CFPs)

**Title (optional):** *From an Empty Kind Cluster to a Multi-Tenant MCP Stack: Lessons at the Boundaries of Catalogs, Operators, and Gateways*

This session follows a deliberate, incremental experiment: starting from an empty Kind cluster and ending with a production-shaped MCP ecosystem—model-registry catalog discovery, lifecycle-operator deployment, mcp-gateway routing, Keycloak identity, Kuadrant AuthPolicy for per-tool authorization, TLS, and Vault-backed credential injection—plus namespace-isolated multi-tenancy with VirtualMCPServers and layered policies. Along the way we treat integration seams as the main character: where catalog metadata ends and OCI reality begins, how the operator must bridge Kubernetes workloads to Gateway API routes and registrations, and where the broker’s behavior differs from what policy can enforce. We share a structured friction register (upstream gaps, documentation mismatches, and scaling limits of Phase‑1 patterns), independent findings that align with the gateway project’s Auth Phase 2 direction, and how AI assistance was used as an accelerator without replacing architectural judgment—including what worked (minimal-first deploys, PR adaptation, exhaustive test matrices, a three-branch complexity ladder) and what still required human direction, skepticism, and manual verification. We close with how this Kind-based lab maps to the next step: harder problems on OpenShift AI—high availability, stronger tenancy, and operational guardrails at scale.

---

## Demo ideas (pick 1–2)

- `mcp-client.sh`: login, `tools/list`, one **allow** + one **deny** tool call.
- Optional: `headers`-style tool to show **injected** credential headers (where safe for the room).
- Branch ladder: show README table — `basic` vs `intermediate` vs `main`.
