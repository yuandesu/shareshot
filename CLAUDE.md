# ShareShot — Claude context

## What this is

ShareShot is a browser-only screenshot annotation tool hosted on GitHub Pages. No server, no backend, no build step.

## Architecture

- Single HTML file: `public/index.html`
- Fabric.js loaded from CDN
- Canvas state saved to `localStorage` (key: `shareshot-canvas`)
- Project name saved to `localStorage` (key: `shareshot-name`)
- Images stored as data URLs inside the canvas JSON

## Design philosophy

See `design-philosophy.md`. TL;DR: minimal color palette (near-white + indigo `#6366f1`), Work Sans font, generous whitespace.

## Constraints

- No framework, no build tools, no npm
- Everything must work by opening `public/index.html` directly in a browser
- Do not add a server or backend

## Deploy

Push to `main` on the `yuandesu/shareshot` GitHub repo. GitHub Pages serves `public/index.html` automatically.
