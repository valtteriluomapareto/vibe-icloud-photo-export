// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
	site: 'https://valtteriluomapareto.github.io',
	base: '/vibe-icloud-photo-export',
	integrations: [
		starlight({
			title: 'Photo Export',
			description:
				'Free macOS app to export and back up your iCloud and Apple Photos library to any drive, organized by year and month.',
			logo: {
				light: './src/assets/photo-export-logo-light.svg',
				dark: './src/assets/photo-export-logo-dark.svg',
			},
			social: [
				{
					icon: 'github',
					label: 'GitHub',
					href: 'https://github.com/valtteriluomapareto/vibe-icloud-photo-export',
				},
			],
			editLink: {
				baseUrl:
					'https://github.com/valtteriluomapareto/vibe-icloud-photo-export/edit/main/website/src/content/docs/',
			},
			sidebar: [
				{ label: 'Getting Started', slug: 'getting-started' },
				{ label: 'Export iCloud Photos to External Drive', slug: 'export-icloud-photos' },
				{ label: 'Features', slug: 'features' },
				{ label: 'Architecture', slug: 'architecture' },
				{ label: 'Ideas', slug: 'roadmap' },
			],
		}),
	],
});
