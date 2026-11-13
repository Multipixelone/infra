# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Finn, adopting a shared design system for web tools and internal developer interfaces. Each adopting app establishes its own end users and their tasks; this record does not assume that every app is private, single-user or developer-facing.

## Product Purpose

Provide a reusable design system, House Stock (`DESIGN.md`), for web apps deployed from this infrastructure repository and for other web apps Finn maintains that don't need a design language of their own. Finn owns the system and its changes.

This is a cross-app design system, not an app and not a redesign of any deployed service. It contains no interface implementation.

## Operating Context

Use `DESIGN.md` when starting or redesigning an eligible app. App-specific product records own workflows, users, terminology, capabilities, stack, deployment and access boundaries. Apps with an established independent design language are outside the default scope.

## Product Principles

1. Reuse the shared identity without requiring every app to have the same composition.
2. Let each app's real tasks and content determine its structure and density.
3. Separate cross-app commitments from app-specific decisions.

## Scope

Adoption is separate, per-app work. Publishing or revising this system does not change any existing app.

## Capabilities and Constraints

No framework, component library, deployment target, first adopting app or cross-app theme default is selected here. Those decisions belong to each adopting app. The deliverables are this product record and the design specification, not working components or a validated UI.
