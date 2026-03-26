# Photo Export Website

This directory contains the documentation website for Photo Export. It is built with Astro and Starlight and published with the `deploy-website.yml` workflow.

## Local Development

Run all commands from `website/`:

```bash
npm install
npm run dev
```

Useful commands:

| Command | Purpose |
| :------ | :------ |
| `npm run dev` | Start the local dev server |
| `npm run build` | Build the static site into `dist/` |
| `npm run preview` | Preview the production build locally |
| `npm run check` | Run `astro check` |

## Content Layout

- `src/content/docs/` contains the published documentation pages.
- `src/pages/index.astro` contains the landing page.
- `src/components/` contains the custom website components.
- `astro.config.mjs` defines the site metadata and Starlight sidebar.

## Documentation Boundaries

Keep content responsibilities clear:

- Update the root `README.md` for repository-level setup and contributor entry points.
- Update `src/content/docs/` for user-facing product documentation.
- Update `docs/` in the repo root for maintainer notes and planning material.

Avoid copying large chunks of text between the repo root and the website. Link when possible; duplicate only when the user experience requires it.
