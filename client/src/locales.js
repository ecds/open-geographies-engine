/**
 * The languages an atlas can be in: the [lang] prefixes the renderer routes
 * (the engine's SiteContent::LOCALES), with the names the console shows.
 */
export const LOCALES = {
  en: 'English',
  es: 'Español',
  fr: 'Français',
  de: 'Deutsch',
  it: 'Italiano',
  pt: 'Português'
};

export const localeName = (code) => LOCALES[code] || code;

/**
 * The atlas's languages from its config.i18n, default first.
 */
export const atlasLocales = (i18n = {}) => {
  const defaultLocale = i18n.default_locale || 'en';
  const listed = Array.isArray(i18n.locales) ? i18n.locales : [];

  return [defaultLocale, ...listed.filter((code) => code !== defaultLocale && LOCALES[code])];
};
