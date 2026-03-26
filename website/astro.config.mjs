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
				'Back up your Apple Photos library to local or external storage, organized by year and month.',
			social: [
				{
					icon: 'github',
					label: 'GitHub',
					href: 'https://github.com/valtteriluomapareto/vibe-icloud-photo-export',
				},
			],
			sidebar: [
				{ label: 'Getting Started', slug: 'getting-started' },
				{ label: 'Features', slug: 'features' },
				{ label: 'Architecture', slug: 'architecture' },
				{ label: 'Ideas', slug: 'roadmap' },
			],
		}),
	],
});
