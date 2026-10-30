import type { Dictionary } from './en';

//   is a no-break space, used before “:” as French typography requires.
export const fr: Dictionary = {
	meta: {
		title: 'Arrow — Le web, bien rangé',
		description:
			'Arrow est un navigateur pour macOS respectueux de la vie privée, avec des espaces, une barre latérale d’onglets et une barre de commande. Bientôt open source.',
	},
	nav: {
		label: 'Principal',
		features: 'Fonctionnalités',
		privacy: 'Vie privée',
		openSource: 'Open source',
		github: 'Arrow sur GitHub',
		language: 'Langue',
		home: 'Arrow, accueil',
	},
	hero: {
		badge: 'Open source — bientôt',
		title: 'Le web, bien rangé.',
		lead: 'Arrow est un navigateur pour macOS qui réunit vos onglets dans une barre latérale, range votre vie en espaces et fait le ménage derrière vous — sans jamais regarder ce que vous faites.',
		primary: 'Suivre le projet',
		secondary: 'Découvrir les fonctionnalités',
		requirements: 'Pour macOS 15 ou ultérieur · Apple silicon',
		screenshotAlt:
			'La fenêtre d’Arrow : une barre latérale avec les favoris et les onglets du jour à gauche, le site swift.org à droite.',
	},
	spaces: {
		eyebrow: 'Espaces',
		title: 'Un espace pour chaque facette de votre vie.',
		body: 'Travail, maison, projet perso : chaque espace garde ses onglets épinglés, ses couleurs et, si vous le souhaitez, son propre profil avec des cookies et des connexions séparés. Passez de l’un à l’autre d’un balayage à deux doigts ou avec ⌃1–9.',
		pick: 'Essayez un espace',
		names: ['Perso', 'Week-end', 'Recettes', 'Idées', 'Jardin', 'Voyages', 'Travail', 'Focus'],
		newTab: 'Nouvel onglet',
	},
	features: {
		eyebrow: 'Fonctionnalités',
		title: 'Chaque chose à sa place.',
		lead: 'Arrow garde le web en ordre, pour que vous restiez concentré sur l’essentiel.',
		sidebar: {
			title: 'Vos onglets, dans une barre latérale',
			body: 'Les favoris en haut, les onglets épinglés ensuite, ceux du jour en dessous. Rangez-les dans des dossiers, imbriquez-les, glissez-les où vous voulez. Les titres longs ont enfin de la place.',
			folder: 'Projets',
		},
		commandBar: {
			title: 'Une barre pour tout',
			body: '⌘T pour chercher, ouvrir une adresse, retrouver un onglet ouvert ou lancer une commande. Tapez le nom d’un site puis Tab pour y chercher directement.',
			typed: 'swi',
			completion: 'ft.org',
			results: [
				{ icon: 'globe', text: 'swift.org', hint: 'Ouvrir' },
				{ icon: 'tab', text: 'Swift Programming Language', hint: 'Aller à l’onglet' },
				{ icon: 'search', text: 'swift concurrency', hint: 'Rechercher' },
			],
		},
		cards: {
			split: {
				title: 'Vue partagée',
				body: 'Jusqu’à quatre pages, côte à côte ou empilées. Déposez un onglet sur la page pour la partager.',
			},
			archive: {
				title: 'Des onglets qui se rangent seuls',
				body: 'Les onglets délaissés rejoignent l’archive après 12 heures, un jour, une semaine ou un mois. Rien n’est perdu.',
			},
			little: {
				title: 'Little Arrow',
				body: '⌥⌘N depuis n’importe quelle app ouvre une petite fenêtre pour une recherche rapide. Gardez-la, ou envoyez-la dans un espace.',
			},
			peek: {
				title: 'Peek',
				body: 'Les liens de vos onglets épinglés s’ouvrent dans une carte au-dessus de la page : vous ne perdez jamais le fil.',
			},
			boosts: {
				title: 'Boosts',
				body: 'Changez les couleurs et les polices d’un site, masquez ce qui vous distrait ou ajoutez votre propre CSS et JavaScript.',
			},
			notes: {
				title: 'Notes et tableaux',
				body: 'Prenez des notes en texte enrichi, ou rassemblez captures, images et croquis sur une toile libre.',
			},
		},
		import: {
			title: 'Emménagez en une minute',
			body: 'Importez vos marque-pages depuis Chrome, Brave, Edge, Vivaldi ou Safari — ou vos espaces, thèmes, onglets épinglés et favoris depuis Arc.',
			browsers: ['Chrome', 'Brave', 'Edge', 'Vivaldi', 'Safari', 'Arc'],
		},
		moreTitle: 'Et bien plus encore',
		more: [
			'Image dans l’image automatique',
			'Capture d’écran',
			'Extensions Chrome',
			'Raccourcis personnalisables',
			'Sélecteur d’onglets récents',
			'Traduction des pages',
			'Mots de passe dans le trousseau',
			'Outils de développement',
			'Contrôles multimédias',
			'AppleScript',
		],
	},
	privacy: {
		eyebrow: 'Vie privée',
		title: 'La vie privée d’abord, dès la conception.',
		lead: 'Nous construisons Arrow sur un principe simple : ce que vous faites en ligne ne regarde que vous. Pas nous, et encore moins les annonceurs.',
		points: {
			telemetry: {
				title: 'Ni statistiques, ni télémétrie, ni publicité',
				body: 'Arrow ne mesure pas la façon dont vous l’utilisez, et ne vous montre jamais de publicité.',
			},
			blocker: {
				title: 'Traqueurs bloqués par défaut',
				body: 'Un bloqueur intégré arrête publicités et traqueurs sur chaque site, avant même leur chargement. Désactivez-le pour un site quand vous en avez besoin.',
			},
			local: {
				title: 'Vos données restent sur votre Mac',
				body: 'Historique, onglets, notes et réglages sont stockés sur votre Mac. Les mots de passe vont dans votre trousseau, protégés par Touch ID.',
			},
			walls: {
				title: 'Des cloisons entre vos espaces',
				body: 'Attribuez un profil à un espace pour séparer cookies et connexions. Les fenêtres privées ne gardent rien une fois fermées.',
			},
		},
		footnote: 'Et comme Arrow sera open source, vous n’aurez pas à nous croire sur parole.',
	},
	openSource: {
		eyebrow: 'Open source',
		title: 'Bientôt open source.',
		body: 'Nous préparons le code pour le publier sous une licence open source. Vous pourrez en lire chaque ligne, vérifier nos engagements sur la vie privée, compiler Arrow vous-même et contribuer à la suite.',
		cta: 'Suivre sur GitHub',
	},
	footer: {
		tagline: 'Un navigateur pour macOS, respectueux de votre vie privée.',
		noTracking: 'Ce site n’utilise ni cookies, ni traqueurs, ni ressources tierces.',
		trademarks:
			'Les noms de produits cités sont des marques de leurs propriétaires respectifs. Arrow est un projet indépendant, sans affiliation avec eux.',
	},
};
