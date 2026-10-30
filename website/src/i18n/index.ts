import { en, type Dictionary } from './en';
import { fr } from './fr';

export const dictionaries = { en, fr } satisfies Record<string, Dictionary>;

export type Locale = keyof typeof dictionaries;

/** Language names, written in their own language. */
export const languages: Record<Locale, string> = {
	en: 'English',
	fr: 'Français',
};

export const GITHUB_URL = 'https://github.com/arrow-browser';
