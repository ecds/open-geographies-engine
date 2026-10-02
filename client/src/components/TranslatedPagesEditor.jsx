import { useState } from 'react';
import _ from 'underscore';
import { localeName } from '../locales';
import SectionsEditor from './SectionsEditor';
import { Button, Field, Message } from './ui';

const copy = (value) => JSON.parse(JSON.stringify(value));

/**
 * The atlas's pages and menu in one of its other languages. Pages are the
 * default language's (added, removed and ordered there); each can be
 * translated — title, description and sections, starting from a copy — or
 * left to show in the default language. Menu items get a label per language.
 */
const TranslatedPagesEditor = ({
  assets, defaultLocale, items = [], liveUrl, locale, onChange, onItemsChange, onUpload, pages = [], translated = []
}) => {
  const [open, setOpen] = useState(null);
  const bySlug = _.indexBy(translated, 'slug');
  const name = localeName(locale);
  const defaultName = localeName(defaultLocale);

  const translate = (page) => {
    onChange([...translated, copy(_.pick(page, 'slug', 'title', 'description', 'sections'))]);
    setOpen(page.slug);
  };

  const updatePage = (slug, changes) => onChange(translated.map((page) => (page.slug === slug ? { ...page, ...changes } : page)));

  const removePage = (slug) => {
    onChange(_.reject(translated, (page) => page.slug === slug));
    setOpen(null);
  };

  const pageTitle = (slug) => _.findWhere(pages, { slug })?.title || slug;

  const setLabel = (index, label) => onItemsChange(items.map((item, i) => {
    if (i !== index) return item;

    const labels = { ...(item.labels || {}) };
    if (label.trim()) labels[locale] = label; else delete labels[locale];

    return _.isEmpty(labels) ? _.omit(item, 'labels') : { ...item, labels };
  }));

  return (
    <>
      <p className='muted'>
        The pages in {name}. Add, remove and order pages in {defaultName}; a page not translated here shows in {defaultName}.
      </p>
      { _.isEmpty(pages) && <p className='muted'>The atlas has no pages yet.</p> }
      { _.map(pages, (page) => {
        const translation = bySlug[page.slug];

        return (
          <div className='card translated-page' key={page.slug}>
            <div className='row'>
              <strong>{ translation?.title || page.title }</strong>
              <span className={`status-pill ${translation ? 'status-published' : 'status-draft'}`}>{ translation ? 'Translated' : `Shows in ${defaultName}` }</span>
              { !translation && <Button onClick={() => translate(page)}>Translate (start from the {defaultName} version)</Button> }
              { translation && open !== page.slug && <Button onClick={() => setOpen(page.slug)}>Edit</Button> }
              { translation && liveUrl && <a href={`${liveUrl}/${locale}/pages/${page.slug}`} rel='noreferrer' target='_blank'>View ↗</a> }
            </div>
            { translation && open === page.slug && (
              <>
                <Field label={`Title (${name})`}>
                  <input className='input' onChange={(e) => updatePage(page.slug, { title: e.target.value })} value={translation.title || ''} />
                </Field>
                <Field hint='Shown by search engines and link previews.' label={`Description (${name})`}>
                  <input className='input' onChange={(e) => updatePage(page.slug, { description: e.target.value })} value={translation.description || ''} />
                </Field>
                <SectionsEditor
                  assets={assets}
                  fallbackTitle={translation.title}
                  onChange={(sections) => updatePage(page.slug, { sections })}
                  onUpload={onUpload}
                  sections={translation.sections}
                />
                <div className='row'>
                  <Button onClick={() => setOpen(null)} subtle>Close</Button>
                  <Button onClick={() => removePage(page.slug)} subtle>Remove the {name} version</Button>
                </div>
              </>
            )}
          </div>
        );
      })}

      <h3>Menu in {name}</h3>
      { _.isEmpty(items) ? (
        <Message>
          The menu follows the pages: each shows with its {name} title once translated, and “Explore” reads in {name}.
        </Message>
      ) : (
        <table className='table'>
          <thead>
            <tr><th>{ defaultName }</th><th>{ name }</th></tr>
          </thead>
          <tbody>
            { _.map(items, (item, index) => {
              const fallback = item.label || (item._template === 'Page' ? (bySlug[item.page]?.title || pageTitle(item.page)) : '');

              return (
                <tr key={index}>
                  <td>{ item.label || (item._template === 'Page' ? pageTitle(item.page) : item.href) }</td>
                  <td>
                    <input
                      aria-label={`Menu label in ${name}`}
                      className='input'
                      onChange={(e) => setLabel(index, e.target.value)}
                      placeholder={fallback}
                      value={item.labels?.[locale] || ''}
                    />
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </>
  );
};

export default TranslatedPagesEditor;
