import _ from 'underscore';
import { atlasLocales, LOCALES, localeName } from '../locales';
import { Field, Select } from './ui';

/**
 * The atlas's languages (config.i18n): its default language and the others
 * visitors can switch to from the header. Pages are translated on the Home
 * page and Pages & menu tabs; anything untranslated shows in the default
 * language.
 */
const LanguagesPanel = ({ i18n = {}, onChange }) => {
  const locales = atlasLocales(i18n);
  const defaultLocale = locales[0];

  const save = (nextDefault, nextLocales) => onChange({
    ...i18n,
    default_locale: nextDefault,
    locales: [nextDefault, ...nextLocales.filter((code) => code !== nextDefault)]
  });

  const toggle = (code, on) => save(defaultLocale, on ? [...locales, code] : _.without(locales, code));

  return (
    <section className='card languages-panel'>
      <Field label='Default language'>
        <Select
          onChange={(code) => code && save(code, _.union(locales, [code]))}
          options={_.map(LOCALES, (name, code) => ({ value: code, text: name }))}
          value={defaultLocale}
        />
      </Field>
      <span className='field-label'>Also in</span>
      <div className='row'>
        { _.map(_.without(_.keys(LOCALES), defaultLocale), (code) => (
          <label className='check' key={code}>
            <input checked={_.contains(locales, code)} onChange={(e) => toggle(code, e.target.checked)} type='checkbox' />
            { localeName(code) }
          </label>
        ))}
      </div>
      <p className='muted'>
        { locales.length > 1
          ? `Visitors switch languages from the header. Translate the home page, pages and menu on the Home page and Pages & menu tabs; anything not translated shows in ${localeName(defaultLocale)}. The atlas's buttons and labels stay in English for now.`
          : 'Add a language to translate the home page, pages and menu into it.' }
      </p>
    </section>
  );
};

export default LanguagesPanel;
