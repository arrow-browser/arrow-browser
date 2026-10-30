export const en = {
	meta: {
		title: 'Arrow — The web, neatly arranged',
		description:
			'Arrow is a privacy-first browser for macOS, with spaces, a tab sidebar and a command bar. Open source soon.',
	},
	nav: {
		label: 'Main',
		features: 'Features',
		privacy: 'Privacy',
		openSource: 'Open source',
		github: 'Arrow on GitHub',
		language: 'Language',
		home: 'Arrow, home',
	},
	hero: {
		badge: 'Open source — coming soon',
		title: 'The web, neatly arranged.',
		lead: 'Arrow is a browser for macOS that gathers your tabs in a sidebar, sorts your life into spaces and tidies up after you — without ever watching what you do.',
		primary: 'Follow the project',
		secondary: 'Explore the features',
		requirements: 'For macOS 15 or later · Apple silicon',
		screenshotAlt:
			'The Arrow window: a sidebar with favorites and today’s tabs on the left, the swift.org website on the right.',
	},
	spaces: {
		eyebrow: 'Spaces',
		title: 'A space for every part of your life.',
		body: 'Work, home, that side project: each space keeps its own pinned tabs, its own colors and, if you like, its own profile with separate cookies and logins. Switch with a two-finger swipe or ⌃1–9.',
		pick: 'Try a space',
		names: ['Personal', 'Weekend', 'Recipes', 'Ideas', 'Garden', 'Travel', 'Work', 'Focus'],
		newTab: 'New Tab',
	},
	features: {
		eyebrow: 'Features',
		title: 'Everything in its place.',
		lead: 'Arrow keeps the web organized, so you can focus on what you came to do.',
		sidebar: {
			title: 'Your tabs, in a sidebar',
			body: 'Favorites up top, pinned tabs below, today’s tabs underneath. Group them in folders, nest them, drag them anywhere. Long titles finally have room to breathe.',
			folder: 'Projects',
		},
		commandBar: {
			title: 'One bar for everything',
			body: 'Press ⌘T to search, open an address, jump to an open tab or run a command. Type a site’s name, then Tab, to search it directly.',
			typed: 'swi',
			completion: 'ft.org',
			results: [
				{ icon: 'globe', text: 'swift.org', hint: 'Open' },
				{ icon: 'tab', text: 'Swift Programming Language', hint: 'Switch to Tab' },
				{ icon: 'search', text: 'swift concurrency', hint: 'Search' },
			],
		},
		cards: {
			split: {
				title: 'Split View',
				body: 'Up to four pages, side by side or stacked. Drop a tab onto the page to split it.',
			},
			archive: {
				title: 'Tabs that tidy themselves',
				body: 'Tabs you haven’t touched slip into the archive after 12 hours, a day, a week or a month. Nothing is lost.',
			},
			little: {
				title: 'Little Arrow',
				body: 'Press ⌥⌘N from any app for a small window and a quick lookup. Keep it, or send it to a space.',
			},
			peek: {
				title: 'Peek',
				body: 'Links from your pinned tabs open in a card above the page, so you never lose your place.',
			},
			boosts: {
				title: 'Boosts',
				body: 'Change a site’s colors and fonts, hide what distracts you, or add your own CSS and JavaScript.',
			},
			notes: {
				title: 'Notes and Easels',
				body: 'Write rich-text notes, or gather captures, images and sketches on a free-form canvas.',
			},
		},
		import: {
			title: 'Move in within a minute',
			body: 'Bring your bookmarks from Chrome, Brave, Edge, Vivaldi or Safari — or your spaces, themes, pinned tabs and favorites from Arc.',
			browsers: ['Chrome', 'Brave', 'Edge', 'Vivaldi', 'Safari', 'Arc'],
		},
		moreTitle: 'And much more',
		more: [
			'Automatic Picture in Picture',
			'Screen capture',
			'Chrome extensions',
			'Custom shortcuts',
			'Recent-tabs switcher',
			'Page translation',
			'Passwords in your Keychain',
			'Developer tools',
			'Media controls',
			'AppleScript',
		],
	},
	privacy: {
		eyebrow: 'Privacy',
		title: 'Privacy first. By design.',
		lead: 'We’re building Arrow on a simple principle: what you do online is your business. Not ours, and certainly not advertisers’.',
		points: {
			telemetry: {
				title: 'No analytics, no telemetry, no ads',
				body: 'Arrow doesn’t measure how you use it, and never shows you ads.',
			},
			blocker: {
				title: 'Trackers blocked by default',
				body: 'A built-in blocker stops ads and trackers on every site before they load. Turn it off for a site whenever you need to.',
			},
			local: {
				title: 'Your data stays on your Mac',
				body: 'History, tabs, notes and settings live on your Mac. Passwords go in your Keychain, behind Touch ID.',
			},
			walls: {
				title: 'Walls between your spaces',
				body: 'Give a space its own profile to keep cookies and logins apart. Private windows keep nothing once closed.',
			},
		},
		footnote: 'And because Arrow will be open source, you won’t have to take our word for it.',
	},
	openSource: {
		eyebrow: 'Open source',
		title: 'Open source. Soon.',
		body: 'We’re getting the code ready to be published under an open-source license. You’ll be able to read every line, check our privacy promises, build Arrow yourself and help shape what comes next.',
		cta: 'Follow on GitHub',
	},
	footer: {
		tagline: 'A privacy-first browser for macOS.',
		noTracking: 'This site uses no cookies, no trackers and nothing from third parties.',
		trademarks:
			'Product names mentioned here are trademarks of their respective owners. Arrow is an independent project and is not affiliated with them.',
	},
};

export type Dictionary = typeof en;
