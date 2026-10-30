# Arrow website

The landing page of Arrow, a static site built with [Astro](https://astro.build).
English is the default language (`/`), French is under `/fr/`.

## Develop

Requires Node 22.23.4 or later.

```sh
npm install
npm run dev       # http://localhost:4321
npm run check     # type-check, including that every translation has all the keys
npm run build     # static site in dist/
npm run preview   # serve dist/
```

`site` (the public URL) is not set in `astro.config.mjs` until the domain is
decided. Without it, the pages have no canonical, `hreflang` or Open Graph
URLs. Pass it at build time: `npx astro build --site https://example.com`.

## Layout

| Path | Contents |
|---|---|
| `src/i18n/en.ts` | English texts; their shape is the `Dictionary` type every language follows |
| `src/i18n/fr.ts` | French texts |
| `src/i18n/index.ts` | Languages, dictionaries and the GitHub link |
| `src/components/` | Page sections (`Hero`, `Spaces`, `Features`, `Privacy`, `OpenSource`), header and footer |
| `src/layouts/Base.astro` | `<head>`: meta tags, alternate languages |
| `src/styles/global.css` | Colors (light and dark), type and shared styles |
| `src/assets/screenshot.webp` | Copy of `docs/screenshot.webp`, resized at build time |

## Add a language

1. Copy `src/i18n/fr.ts` to `src/i18n/<code>.ts` and translate it.
2. Add it to `dictionaries` and `languages` in `src/i18n/index.ts`, and to
   `i18n.locales` in `astro.config.mjs`.
3. Add `src/pages/<code>/index.astro`, like `src/pages/fr/index.astro`.

## Content rules

- The site loads nothing from third parties (no web fonts, analytics or
  embeds) and sets no cookies: it says so in its footer.
- No comparison with other browsers. They are named only where Arrow imports
  from them; Chromium and Chrome extensions only as the engine and what it runs.
- Nothing about accounts, sync or the server until that is decided.
