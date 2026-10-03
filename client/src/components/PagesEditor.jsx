import { useState } from 'react';
import _ from 'underscore';
import SectionsEditor, { newSectionId } from './SectionsEditor';
import { Button, Field, Message, Select } from './ui';

const SLUG_FORMAT = /^[a-z0-9][a-z0-9-]*$/;

export const slugify = (text) => (text || '')
  .toLowerCase()
  .normalize('NFKD')
  .replace(/[̀-ͯ]/g, '')
  .replace(/[^a-z0-9]+/g, '-')
  .replace(/^-+|-+$/g, '')
  .slice(0, 63);

const uniqueSlug = (base, taken) => {
  const root = base || 'page';
  let slug = root;
  let n = 2;

  while (_.contains(taken, slug)) {
    slug = `${root}-${n}`;
    n += 1;
  }

  return slug;
};

/**
 * The atlas's standalone pages (About, Credits, …) and its menu.
 *
 * Pages: add, reorder, remove, and edit one at a time (title, address,
 * description, sections). A page that hasn't been saved yet takes its address
 * from its title as you type; a saved page keeps its address unless you
 * change it, so links to it don't break.
 *
 * Menu: with nothing saved the atlas shows Explore and every page. Customizing
 * turns that into an editable list of page items (labelled with the page's
 * title unless given a label) and links. Renaming a page's address or
 * removing a page updates the menu with it; a new page is added to a
 * customized menu.
 *
 * Changes are reported together — onChange({ pages, items }) — because page
 * edits can change the menu.
 */
const PagesEditor = ({ assets, items = [], liveUrl, locale, onChange, onUpload, pages = [], savedSlugs = [], searchHref }) => {
  const [selected, setSelected] = useState(null);

  const pageItem = (slug) => ({ _template: 'Page', page: slug });
  const menuCustomized = !_.isEmpty(items);

  const updatePage = (index, changes) => {
    const page = pages[index];
    const next = { ...page, ...changes };
    const others = _.without(_.pluck(pages, 'slug'), page.slug);

    // Unsaved pages follow their title until the address is edited.
    const following = !page.slug || page.slug === uniqueSlug(slugify(page.title), others);

    if ('title' in changes && !_.contains(savedSlugs, page.slug) && following) {
      next.slug = uniqueSlug(slugify(changes.title), others);
    }

    const nextPages = pages.map((p, i) => (i === index ? next : p));
    const nextItems = next.slug !== page.slug
      ? items.map((item) => (item._template === 'Page' && item.page === page.slug ? { ...item, page: next.slug } : item))
      : items;

    onChange({ pages: nextPages, items: nextItems });
  };

  const addPage = () => {
    const slug = uniqueSlug('new-page', _.pluck(pages, 'slug'));
    const page = { title: 'New page', slug, sections: [{ id: newSectionId(), type: 'text' }] };

    onChange({
      pages: [...pages, page],
      items: menuCustomized ? [...items, pageItem(slug)] : items
    });
    setSelected(pages.length);
  };

  const removePage = (index) => {
    const { slug } = pages[index];

    onChange({
      pages: _.reject(pages, (p, i) => i === index),
      items: _.reject(items, (item) => item._template === 'Page' && item.page === slug)
    });
    setSelected(null);
  };

  const movePage = (index, offset) => {
    const target = index + offset;

    if (target < 0 || target >= pages.length) {
      return;
    }

    const next = [...pages];
    [next[index], next[target]] = [next[target], next[index]];
    onChange({ pages: next });

    if (selected === index) {
      setSelected(target);
    }
  };

  // --- Menu ------------------------------------------------------------------

  const setItems = (next) => onChange({ items: next });
  const updateItem = (index, changes) => setItems(items.map((item, i) => (i === index ? { ...item, ...changes } : item)));

  const moveItem = (index, offset) => {
    const target = index + offset;

    if (target < 0 || target >= items.length) {
      return;
    }

    const next = [...items];
    [next[index], next[target]] = [next[target], next[index]];
    setItems(next);
  };

  const customize = () => setItems([
    ...(searchHref ? [{ _template: 'URL', label: 'Explore', href: searchHref }] : []),
    ..._.map(pages, (page) => pageItem(page.slug))
  ]);

  const pageOptions = _.map(pages, (page) => ({ value: page.slug, text: page.title || page.slug }));
  const page = selected === null ? null : pages[selected];
  const duplicate = page && _.filter(pages, (p) => p.slug === page.slug).length > 1;
  const badSlug = page && page.slug && !SLUG_FORMAT.test(page.slug);

  return (
    <>
      <h2 className='h-section'>Pages</h2>
      <p className='muted'>Standalone pages such as About, Credits or How to cite, each at /{ locale }/pages/&lt;address&gt;.</p>
      { _.isEmpty(pages) && <p className='muted'>No pages yet.</p> }
      { _.map(pages, (p, index) => (
        <div className={['card', 'row', 'page-row', selected === index && 'is-selected'].filter(Boolean).join(' ')} key={index}>
          <div>
            <strong>{ p.title || 'Untitled page' }</strong>
            <p className='muted'>/{ locale }/pages/{ p.slug }</p>
          </div>
          <div className='section-controls'>
            <Button aria-label='Move up' disabled={index === 0} onClick={() => movePage(index, -1)} subtle>↑</Button>
            <Button aria-label='Move down' disabled={index === pages.length - 1} onClick={() => movePage(index, 1)} subtle>↓</Button>
            { liveUrl && _.contains(savedSlugs, p.slug) && (
              <a className='button' href={`${liveUrl}/${locale}/pages/${p.slug}`} rel='noreferrer' target='_blank'>View ↗</a>
            )}
            <Button onClick={() => setSelected(selected === index ? null : index)} primary={selected !== index}>{ selected === index ? 'Close' : 'Edit' }</Button>
          </div>
        </div>
      ))}
      <Button onClick={addPage} subtle>+ Add page</Button>

      { page && (
        <div className='page-editor'>
          <h2 className='h-section'>Editing “{ page.title || 'Untitled page' }”</h2>
          <div className='grid-2'>
            <Field label='Title' required>
              <input className='input' onChange={(e) => updatePage(selected, { title: e.target.value })} value={page.title || ''} />
            </Field>
            <Field hint='Lowercase letters, numbers and hyphens.' label='Address' required>
              <span className='prefixed-input'>
                <span className='muted'>/{ locale }/pages/</span>
                <input className='input' onChange={(e) => updatePage(selected, { slug: e.target.value.toLowerCase() })} value={page.slug || ''} />
              </span>
            </Field>
          </div>
          { duplicate && <Message tone='negative'>Another page already uses this address.</Message> }
          { badSlug && <Message tone='negative'>The address can only use lowercase letters, numbers and hyphens.</Message> }
          <Field hint='Shown by search engines and link previews.' label='Description'>
            <input className='input' onChange={(e) => updatePage(selected, { description: e.target.value })} value={page.description || ''} />
          </Field>
          <h3 className='h-sub'>Sections</h3>
          <SectionsEditor
            level={4}
            assets={assets}
            fallbackTitle={page.title}
            onChange={(sections) => updatePage(selected, { sections })}
            onUpload={onUpload}
            sections={page.sections}
          />
          <div className='actions'>
            <Button onClick={() => removePage(selected)} subtle>Delete this page</Button>
          </div>
        </div>
      )}

      <h2 className='h-section'>Menu</h2>
      { !menuCustomized && (
        <div className='card row'>
          <p className='muted'>The menu shows Explore, then every page in the order above. The site title always links to the home page.</p>
          <Button onClick={customize}>Customize the menu</Button>
        </div>
      )}
      { menuCustomized && (
        <>
          <p className='muted'>In menu order. The site title always links to the home page.</p>
          { _.map(items, (item, index) => (
            <div className='card' key={index}>
              { item._template === 'Page' ? (
                <div className='grid-2'>
                  <Field label='Page'>
                    <Select onChange={(slug) => updateItem(index, { page: slug })} options={pageOptions} placeholder='Choose a page' value={item.page || ''} />
                  </Field>
                  <Field hint='Leave blank to use the page title.' label='Label'>
                    <input className='input' onChange={(e) => updateItem(index, { label: e.target.value })} value={item.label || ''} />
                  </Field>
                </div>
              ) : (
                <div className='grid-2'>
                  <Field label='Label'>
                    <input className='input' onChange={(e) => updateItem(index, { label: e.target.value })} value={item.label || ''} />
                  </Field>
                  <Field hint='A page on this atlas (/en/search/places) or a full address (https://…).' label='Link'>
                    <input className='input' onChange={(e) => updateItem(index, { href: e.target.value })} value={item.href || ''} />
                  </Field>
                </div>
              )}
              <div className='section-controls'>
                <Button aria-label='Move up' disabled={index === 0} onClick={() => moveItem(index, -1)} subtle>↑</Button>
                <Button aria-label='Move down' disabled={index === items.length - 1} onClick={() => moveItem(index, 1)} subtle>↓</Button>
                <Button onClick={() => setItems(_.reject(items, (x, i) => i === index))} subtle>Remove</Button>
              </div>
            </div>
          ))}
          <div className='row'>
            <Button disabled={_.isEmpty(pages)} onClick={() => setItems([...items, pageItem(pages[0]?.slug)])} subtle>+ Add a page</Button>
            <Button onClick={() => setItems([...items, { _template: 'URL', label: '', href: '' }])} subtle>+ Add a link</Button>
            <Button onClick={() => setItems([])} subtle>Use the default menu</Button>
          </div>
        </>
      )}
    </>
  );
};

export default PagesEditor;
