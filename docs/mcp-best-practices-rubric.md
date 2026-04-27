# MCP Ecosystem Best Practices Document — Evaluation Rubric

Consolidated from: RHAISTRAT-1101, RHAISTRAT-1149, RHAIENG-3831, RHAIENG-3832, plus additional requirements.

Use this rubric to evaluate any draft of the MCP Ecosystem best practices / knowledge base document. Each section lists required coverage areas. A draft meets the bar when every item is addressed substantively (not just mentioned in passing).

---

## How to Use This Rubric

For each item, score as:
- **Covered** — the draft addresses this topic with enough detail for the target audience to act on it
- **Partial** — mentioned but lacks actionable depth or clarity
- **Missing** — not addressed

A shipping-ready document should have zero "Missing" and minimal "Partial" items.

### Scoping Notes

- **Observability**: Full-spectrum observability (MLFlow, Prometheus dashboards, distributed tracing, Grafana integration) is out of scope for this effort. The document should mention what observability touchpoints exist (broker logs, AuthPolicy enforcement logs, MCPServerRegistration status) but is not expected to provide comprehensive monitoring/tracing guidance. A dedicated observability document may follow as a separate effort.

---

## 1. Value Proposition & Motivation

> *Why should a customer care about the MCP Ecosystem on OpenShift AI? What do they gain versus not using it?*

| # | Requirement | Source | Status |
|---|------------|--------|--------|
| 1.1 | What MCP is and why it matters for AI workflows | RHAISTRAT-1149 | |
| 1.2 | How MCP fits into agent-based and tool-enabled AI workflows (the "so what" for AI practitioners) | RHAISTRAT-1149 | |
| 1.3 | **Value of the ecosystem vs. doing it without** — concrete benefits of using the integrated MCP Ecosystem (catalog + gateway + Gen AI Studio) compared to ad-hoc / manual MCP server management | Additional req | |
| 1.4 | What problems the ecosystem solves: fragmentation, lack of discoverability, inconsistent access control, no unified consumption path | RHAISTRAT-1101 | |

---

## 2. MCP Ecosystem Architecture Overview

> *How do the components fit together end-to-end?*

| # | Requirement | Source | Status |
|---|------------|--------|--------|
| 2.1 | High-level architecture of the MCP Ecosystem and how its components interact | RHAISTRAT-1149, RHAIENG-3831, RHAIENG-3832 | |
| 2.2 | Role of each component: MCP Catalog, MCP Deployment, MCP Gateway, Gen AI Studio | RHAISTRAT-1149, RHAIENG-3831 | |
| 2.3 | End-to-end flow: Catalog → Deploy → Gateway → Consume | RHAISTRAT-1101 | |
| 2.4 | How MCP servers are modeled as standard OpenShift workloads (containers), not custom orchestration | RHAISTRAT-1101 | |

---

## 3. Personas & Responsibilities

> *Who does what? Clear separation of deployer vs. consumer roles.*

| # | Requirement | Source | Status |
|---|------------|--------|--------|
| 3.1 | Platform Engineer / AI Ops / AI Officer persona — responsibilities (deploy, register, configure gateway) | RHAISTRAT-1101, RHAISTRAT-1149, RHAIENG-3831 | |
| 3.2 | AI Engineer / Practitioner persona — consumption model (discover, use tools via Gen AI Studio) | RHAISTRAT-1149, RHAIENG-3831 | |
| 3.3 | Clear separation of "who deploys" vs. "who consumes" and the boundary between them | RHAIENG-3831, RHAIENG-3832 | |

---

## 4. Supported Workflows

> *Step-by-step guidance for each stage of the MCP lifecycle within the MVP.*

| # | Requirement | Source | Status |
|---|------------|--------|--------|
| 4.1 | **Discovering** MCP servers via the MCP Catalog (metadata: description, capabilities, transport type, deployment readiness) | RHAISTRAT-1101, RHAISTRAT-1149 | |
| 4.2 | **Deploying** MCP servers onto OpenShift from the catalog | RHAISTRAT-1101, RHAISTRAT-1149 | |
| 4.3 | **Registering** deployed MCP servers with the MCP Gateway (manual registration process) | RHAISTRAT-1101, RHAISTRAT-1149, RHAIENG-3832 | |
| 4.4 | **Creating and using virtual MCP servers** (tool aggregation and filtering) | RHAISTRAT-1149, RHAIENG-3831 | |
| 4.5 | **Consuming** MCP capabilities in Gen AI Studio / Playground (ConfigMap-backed endpoints pattern) | RHAISTRAT-1101, RHAISTRAT-1149 | |
| 4.6 | **Bringing your own MCP server** — how customers can deploy their own custom/third-party MCP servers onto the platform, register them with the gateway, and make them consumable | Additional req | |

---

## 5. MCP Gateway Integration

> *How the gateway provides centralized access, security, and policy enforcement.*

| # | Requirement | Source | Status |
|---|------------|--------|--------|
| 5.1 | Purpose of the MCP Gateway in the ecosystem (centralized access point) | RHAISTRAT-1149, RHAIENG-3831 | |
| 5.2 | Registration and exposure of MCP servers through the gateway | RHAISTRAT-1149, RHAIENG-3832 | |
| 5.3 | Virtual MCP server concepts and usage (tool aggregation, filtering) | RHAISTRAT-1149, RHAIENG-3831 | |
| 5.4 | Authentication and authorization via Authorino | RHAISTRAT-1101 | |
| 5.5 | Observability and cross-cutting controls — mention available touchpoints (broker logs, auth logs, registration status); full observability stack is out of scope (see Scoping Notes) | RHAISTRAT-1101, RHAIENG-3832 | |
| 5.6 | High-level policy and access control expectations | RHAISTRAT-1149, RHAIENG-3831 | |

---

## 6. Best Practices & Constraints

> *What is supported, what to avoid, and guardrails for enterprise use.*

| # | Requirement | Source | Status |
|---|------------|--------|--------|
| 6.1 | HTTP-based MCP servers only — why this is the supported transport | RHAISTRAT-1101, RHAISTRAT-1149, RHAIENG-3831 | |
| 6.2 | Explicit guidance against stdio-based MCP servers (why they are out of scope) | RHAISTRAT-1149 | |
| 6.3 | Security considerations and recommended patterns | RHAISTRAT-1149, RHAIENG-3831, RHAIENG-3832 | |
| 6.4 | Observability considerations — mention available log sources and status checks; full monitoring/tracing guidance is out of scope (see Scoping Notes) | RHAIENG-3832 | |
| 6.5 | Compliance considerations for enterprise and regulated environments | RHAISTRAT-1149, RHAIENG-3832 | |
| 6.6 | Constraints and gotchas — known limitations, common pitfalls | RHAIENG-3832 | |
| 6.7 | Guidance against unsupported or non-recommended patterns | RHAISTRAT-1149 | |

---

## 7. MVP Scope & Explicit Non-Goals

> *What is intentionally in and out of scope for the current release.*

| # | Requirement | Source | Status |
|---|------------|--------|--------|
| 7.1 | Clear statement of what the MVP delivers and its intended audience (Summit demos, experimentation, early enablement) | RHAISTRAT-1101 | |
| 7.2 | Explicit non-goals: full lifecycle management (upgrade, retirement, version governance) | RHAISTRAT-1101 | |
| 7.3 | Explicit non-goals: dedicated MCP Registry (beyond catalog metadata) | RHAISTRAT-1101 | |
| 7.4 | Explicit non-goals: stdio-based MCP server support | RHAISTRAT-1101 | |
| 7.5 | Explicit non-goals: advanced multi-gateway / per-namespace abstractions | RHAISTRAT-1101 | |
| 7.6 | Explicit non-goals: perfect persona separation or final UX polish | RHAISTRAT-1101 | |

---

## 8. Bring Your Own MCP Server

> *How customers deploy their own servers onto the platform.*

| # | Requirement | Source | Status |
|---|------------|--------|--------|
| 8.1 | How to package a custom MCP server as a container image suitable for OpenShift deployment | Additional req | |
| 8.2 | Requirements and conventions the server must follow (HTTP transport, health endpoints, metadata format) | Additional req | |
| 8.3 | Steps to deploy a custom server, register it with the gateway, and make it available for consumption | Additional req | |
| 8.4 | How a BYOS server integrates with the existing catalog / discovery experience (if applicable) | Additional req | |

---

## 9. Future Direction

> *Where the ecosystem is headed beyond the MVP — set expectations without over-promising.*

| # | Requirement | Source | Status |
|---|------------|--------|--------|
| 9.1 | What is intentionally deferred (registry, lifecycle management, advanced aggregation) | RHAISTRAT-1149 | |
| 9.2 | How the MVP fits into the longer-term MCP roadmap | RHAISTRAT-1149 | |
| 9.3 | Guidance for scaling beyond the Summit MVP | RHAISTRAT-1149 | |

---

## Summary Scorecard

| Section | Total Items | Covered | Partial | Missing |
|---------|------------|---------|---------|---------|
| 1. Value Proposition & Motivation | 4 | | | |
| 2. Architecture Overview | 4 | | | |
| 3. Personas & Responsibilities | 3 | | | |
| 4. Supported Workflows | 6 | | | |
| 5. Gateway Integration | 6 | | | |
| 6. Best Practices & Constraints | 7 | | | |
| 7. MVP Scope & Non-Goals | 6 | | | |
| 8. Bring Your Own MCP Server | 4 | | | |
| 9. Future Direction | 3 | | | |
| **TOTAL** | **43** | | | |
