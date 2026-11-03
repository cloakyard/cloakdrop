# Air compact notices and scrolling — 2026-11-03

Website-only adoption of Air 1.6.0. The canonical contract and pinned CSS,
notice presentation and component gallery are synchronized from Cloakyard.
This site has no service worker or application dialog; no fabricated notification
is added. Native application code and release behavior are unchanged.

The shared contract specifies a compact bottom-right update popup, one quiet
44×44px dismiss target, internal body scrolling, fixed dialog titles/actions,
and thin neutral scrollbar indicators with native keyboard/touch/wheel support.

Validation: canonical design/provenance and standalone portability pass; the
six-site public matrix passes 648 home / 288 secondary layouts with no deviations
or browser errors. The site was visually compared in light/dark at phone, tablet
and desktop widths; the matrix includes all eleven Air sizes and enlarged text.
Product check/build and applicable worker validation are recorded in the family
audit. Physical Windows, iPhone and spoken-assistive acceptance remain separate.

Family evidence: `cloakyard/docs/air/compact-popups-2026-11-03.md` and its committed
contact sheets. Complete local run: `/tmp/air-popups-2026-11-03`.

Release status: locally verified; promotion pending.
