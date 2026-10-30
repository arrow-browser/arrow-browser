// @ts-check
import { defineConfig } from 'astro/config';

// https://astro.build/config
export default defineConfig({
	// `site` (the public URL, for canonical, hreflang and Open Graph URLs) is
	// left unset until the domain is decided: those tags are then omitted.
	// `astro build --site https://…` sets it for a build.
	i18n: {
		locales: ['en', 'fr'],
		defaultLocale: 'en',
		routing: {
			prefixDefaultLocale: false,
		},
	},
});
