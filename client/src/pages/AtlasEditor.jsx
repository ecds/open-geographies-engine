import { useCallback, useEffect, useMemo, useState } from 'react';
import _ from 'underscore';
import {
  buildTiles,
  errorMessages,
  fetchSearchCollections,
  fetchSite,
  fetchSiteAssets,
  fetchSiteConfig,
  fetchSiteFacets,
  fetchSiteFields,
  fetchSiteSearchFields,
  reindexSearchCollection,
  updateSite,
  cropSiteAsset,
  uploadSiteAsset
} from '../api';
import { liveUrl as atlasLiveUrl } from '../atlasLinks';
import AtlasHeader from '../components/AtlasHeader';
import DeleteAtlasPanel from '../components/DeleteAtlasPanel';
import DomainPanel from '../components/DomainPanel';
import HistoricMapPanel from '../components/HistoricMapPanel';
import LanguagesPanel from '../components/LanguagesPanel';
import TranslatedPagesEditor from '../components/TranslatedPagesEditor';
import { atlasLocales as atlasLocalesOf, localeName } from '../locales';
import ImageLibrary from '../components/ImageLibrary';
import PublishPanel from '../components/PublishPanel';
import ImageField from '../components/ImageField';
import { CROP_SHAPES, ImageCropContext } from '../components/ImageCropper';
import PagesEditor from '../components/PagesEditor';
import SectionsEditor from '../components/SectionsEditor';
import { Button, Field, Message, MultiSelect, onTabListKeyDown, Select, Tag } from '../components/ui';
import { paths } from '../router';

const TABS = [
  { key: 'general', label: 'General' },
  { key: 'branding', label: 'Branding' },
  { key: 'home', label: 'Home page' },
  { key: 'pages', label: 'Pages & menu' },
  { key: 'images', label: 'Images' },
  { key: 'layers', label: 'Map layers' },
  { key: 'search', label: 'Search' },
  { key: 'detail', label: 'Detail pages' },
  { key: 'advanced', label: 'Advanced' }
];

// Config sections with a dedicated editor; everything else is "advanced" JSON.
const MANAGED_KEYS = ['layers', 'search'];

const FONTS = ['Afacad', 'Baskervville', 'Crimson Text SemiBold', 'DM Sans', 'DM Serif Display', 'Inter', 'Libre Bodoni', 'Open Sans'];

const COLORS = [
  ['primary_color', 'Primary'],
  ['secondary_color', 'Secondary'],
  ['tertiary_color', 'Tertiary'],
  ['background_color', 'Background'],
  ['background_alternate', 'Background (alternate)'],
  ['content_color', 'Text'],
  ['content_alternate', 'Text (alternate)'],
  ['content_inverse', 'Text on dark'],
  ['content_inverse_alternate', 'Text on dark (alternate)']
];

const LAYER_TYPES = ['vector', 'raster', 'pmtiles', 'geojson', 'georeference'];

// What each layer type is, and what its address points at.
const LAYER_TYPE_LABELS = {
  vector: 'Vector tiles (a style)',
  raster: 'Raster tiles',
  pmtiles: 'PMTiles archive',
  geojson: 'GeoJSON',
  georeference: 'Historic map (Allmaps)'
};
const LAYER_URL_LABELS = {
  vector: 'Style address',
  raster: 'Tile address ({z}/{x}/{y})',
  pmtiles: 'Archive address (.pmtiles)',
  geojson: 'GeoJSON address',
  georeference: 'Allmaps annotation address'
};
// How a search shows its results (the renderer's search `type`); no type
// is the map, offered as the select's empty choice.
const SEARCH_TYPES = [
  { value: 'list', text: 'List of results (no map)' },
  { value: 'grid', text: 'Grid of cards (no map)' },
  { value: 'image', text: 'Image gallery (no map)' }
];

// A year typed into a layer's Year box: digits (and a leading minus) only;
// null for anything else, undefined for an empty box.
const toYear = (text) => {
  const trimmed = String(text ?? '').trim();

  if (!trimmed) {
    return undefined;
  }

  const match = trimmed.match(/^-?\d{1,4}$/);
  return match ? Number(match[0]) : null;
};

/**
 * A year box. What's typed stays as typed ("-", a fifth digit, a stray letter)
 * so nothing vanishes under the cursor; the layer takes the year only once the
 * box holds one, and an empty box clears it.
 */
const YearInput = ({ error, hint, label, onChange, placeholder, value }) => {
  const [text, setText] = useState(value ?? '');

  // Follow changes made elsewhere (a historic map's title year), not our own.
  useEffect(() => {
    if (toYear(text) !== value) {
      setText(value ?? '');
    }
  }, [value]);

  const parsed = toYear(text);

  return (
    <Field
      error={parsed === null ? 'A year in digits, e.g. 1878.' : error}
      hint={hint}
      label={label}
    >
      <input
        className='input'
        inputMode='numeric'
        onChange={(e) => {
          setText(e.target.value);
          const year = toYear(e.target.value);

          if (year !== null) {
            onChange(year);
          }
        }}
        placeholder={placeholder}
        value={text}
      />
    </Field>
  );
};

/**
 * The atlas editor: the site record's name/slug, branding, the home page and
 * standalone pages with the menu, map layers and search apps, plus the config
 * sections without a dedicated editor as JSON, and the emitted config.json
 * for reference.
 *
 * Facet choices come from the engine's facet catalog (GET /sites/:id/facets),
 * which knows what the v1 index actually makes facetable for this project's
 * models — so the pick-list can't offer an attribute that would return an
 * empty facet.
 */
const AtlasEditor = ({ id, navigate }) => {
  const [site, setSite] = useState(null);
  // The atlas as last saved (what the live atlas shows), beside the edited copy.
  const [savedSite, setSavedSite] = useState(null);
  const [assets, setAssets] = useState([]);
  const [savedSlugs, setSavedSlugs] = useState([]);
  const [collections, setCollections] = useState([]);
  const [facets, setFacets] = useState([]);
  const [fieldModels, setFieldModels] = useState([]);
  const [searchFields, setSearchFields] = useState([]);
  const [dateFields, setDateFields] = useState([]);
  const [tab, setTab] = useState('general');
  // The language the Home page and Pages & menu tabs are editing.
  const [contentLocale, setContentLocale] = useState(null);
  const [advancedText, setAdvancedText] = useState('');
  const [advancedError, setAdvancedError] = useState(false);
  const [preview, setPreview] = useState(null);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [notice, setNotice] = useState(null);
  const [errors, setErrors] = useState([]);
  // Someone else's save since this copy was loaded (a refused save's 409).
  const [conflict, setConflict] = useState(null);
  const [reloads, setReloads] = useState(0);

  useEffect(() => {
    fetchSite(id)
      .then((data) => {
        setSite(data.site);
        setSavedSite(data.site);
        setSavedSlugs(_.pluck(data.site.content?.pages || [], 'slug'));
        setAdvancedText(JSON.stringify(_.omit(data.site.config || {}, MANAGED_KEYS), null, 2));

        return Promise.all([
          fetchSiteAssets(id).then((d) => setAssets(d.assets || [])),
          fetchSearchCollections(data.site.project_id).then((d) => setCollections(d.search_collections || [])),
          fetchSiteFacets(id).then((d) => setFacets(d.facets || [])),
          fetchSiteFields(id).then((d) => setFieldModels(d.models || [])),
          fetchSiteSearchFields(id).then((d) => {
            setSearchFields(d.search_fields || []);
            setDateFields(d.date_fields || []);
          })
        ]);
      })
      .catch((error) => setErrors(errorMessages(error)));
  }, [id, reloads]);

  const siteConfig = site?.config || {};
  const branding = site?.branding || {};
  const navItems = site?.navigation?.items || [];
  const content = site?.content || {};
  const home = content.home || { sections: [] };

  const locale = siteConfig.i18n?.default_locale || 'en';
  const atlasLocales = atlasLocalesOf(siteConfig.i18n);
  const editingLocale = _.contains(atlasLocales, contentLocale) ? contentLocale : locale;
  const translations = content.translations || {};
  const searchName = siteConfig.search?.[0]?.name;
  const searchHref = searchName ? `/${locale}/search/${searchName}` : undefined;
  const liveUrl = atlasLiveUrl(site);

  const update = (changes) => { setSite((prev) => ({ ...prev, ...changes })); setSaved(false); };
  const updateConfig = (changes) => update({ config: { ...siteConfig, ...changes } });
  const updateBranding = (changes) => update({ branding: { ...branding, ...changes } });
  const updateBrandingSection = (section, changes) => updateBranding({ [section]: { ...(branding[section] || {}), ...changes } });
  const updateHome = (changes) => update({ content: { ...content, home: { ...home, ...changes } } });

  // Page edits can change the menu (renamed or removed pages), so both land
  // in one update.
  const updatePages = ({ pages, items }) => setSite((prev) => {
    setSaved(false);

    return {
      ...prev,
      content: pages ? { ...(prev.content || {}), pages } : prev.content,
      navigation: items ? { ...(prev.navigation || {}), items } : prev.navigation
    };
  });

  const onUpload = (file) => uploadSiteAsset(site.id, file).then((data) => {
    setAssets((prev) => [data.asset, ...prev]);
    return data.asset;
  });

  // A cropped copy joins the library like an upload (ImageField's Crop…).
  const onCrop = useCallback((key, rect) => cropSiteAsset(site.id, key, rect).then((data) => {
    setAssets((prev) => [data.asset, ...prev]);
    return data.asset;
  }), [site?.id]);

  const footerLogos = branding.footer?.logos || [];
  const updateFooterLogo = (index, changes) => updateBrandingSection('footer', {
    logos: footerLogos.map((logo, i) => (i === index ? { ...logo, ...changes } : logo))
  });

  const updateLayer = (index, changes) => {
    const layers = [...(siteConfig.layers || [])];
    layers[index] = { ...layers[index], ...changes };
    updateConfig({ layers });
  };

  const updateSearch = (index, changes) => {
    const search = [...(siteConfig.search || [])];
    search[index] = { ...search[index], ...changes };
    updateConfig({ search });
  };

  /**
   * Hidden fields live under detail_pages.models.<model>.exclude. detail_pages
   * is otherwise advanced JSON, so the advanced text is refreshed to match.
   */
  const updateExclude = (model, exclude) => {
    const models = { ...(siteConfig.detail_pages?.models || {}) };
    models[model] = { ...(models[model] || {}), exclude };

    const next = { ...siteConfig, detail_pages: { ...(siteConfig.detail_pages || {}), models } };
    update({ config: next });
    setAdvancedText(JSON.stringify(_.omit(next, MANAGED_KEYS), null, 2));
  };

  /**
   * A relationship section's heading on detail pages and panels, per
   * language: config.i18n.strings[<locale>][<key>] (the renderer's
   * translation key for the relationship). Blank goes back to the FairData
   * name. i18n is otherwise advanced JSON, so the advanced text is refreshed.
   */
  const updateSectionName = (key, loc, value) => {
    const strings = { ...(siteConfig.i18n?.strings || {}) };
    const forLocale = { ...(strings[loc] || {}) };

    if (value.trim()) {
      forLocale[key] = value;
    } else {
      delete forLocale[key];
    }

    strings[loc] = forLocale;

    const next = { ...siteConfig, i18n: { ...(siteConfig.i18n || {}), strings } };
    update({ config: next });
    setAdvancedText(JSON.stringify(_.omit(next, MANAGED_KEYS), null, 2));
  };

  /**
   * The atlas's languages (config.i18n, otherwise advanced JSON).
   */
  const updateI18n = (i18n) => {
    const next = { ...siteConfig, i18n };
    update({ config: next });
    setAdvancedText(JSON.stringify(_.omit(next, MANAGED_KEYS), null, 2));
  };

  /**
   * One language's translations (content.translations[<locale>]).
   */
  const updateTranslation = (loc, changes) => update({
    content: { ...content, translations: { ...translations, [loc]: { ...(translations[loc] || {}), ...changes } } }
  });

  /**
   * The advanced JSON is merged beneath the managed sections when it parses.
   */
  const onAdvancedBlur = () => {
    try {
      const parsed = JSON.parse(advancedText || '{}');
      setAdvancedError(false);
      update({ config: { ...parsed, ..._.pick(siteConfig, MANAGED_KEYS) } });
    } catch (e) {
      setAdvancedError(true);
    }
  };

  // Sent with the version this copy was loaded at: a save over someone
  // else's (pages or settings saved since) is refused with who and what,
  // and the curator chooses — reload, or save anyway (`force`).
  const onSave = useCallback((force = false) => {
    setSaving(true);
    setErrors([]);
    setSaved(false);
    setConflict(null);

    const options = { base_version_id: site.version_id ?? null, ...(force ? { force: true } : {}) };

    updateSite(site.id, _.pick(site, 'name', 'slug', 'config', 'area', 'branding', 'navigation', 'content'), options)
      .then((data) => {
        setSite(data.site);
        setSavedSite(data.site);
        setSavedSlugs(_.pluck(data.site.content?.pages || [], 'slug'));
        setSaved(true);
        setPreview(null);
      })
      .catch((error) => {
        if (error.status === 409 && error.data?.conflict) {
          setConflict(error.data.conflict);
        } else {
          setErrors(errorMessages(error));
        }
      })
      .finally(() => setSaving(false));
  }, [site]);

  // Their version, in place of this copy (the unsaved changes here go).
  const onReload = () => {
    setConflict(null);
    setSaved(false);
    setReloads((n) => n + 1);
  };

  const onBuildTiles = () => buildTiles(site.id)
    .then(() => setNotice('Tile generation queued — watch the Jobs tab.'))
    .catch((error) => setErrors(errorMessages(error)));

  const onReindex = (collection) => reindexSearchCollection(collection.id)
    .then(() => setNotice(`Reindex of "${collection.name}" queued — watch the Jobs tab.`))
    .catch((error) => setErrors(errorMessages(error)));

  const onLoadPreview = () => fetchSiteConfig(site.id)
    .then((data) => setPreview(JSON.stringify(data, null, 2)))
    .catch((error) => setErrors(errorMessages(error)));

  const facetOptions = useMemo(() => _.map(_.where(facets, { facetable: true }), (f) => ({ value: f.attribute, text: `${f.label} (${f.attribute})` })), [facets]);
  const unfacetable = useMemo(() => _.filter(facets, (f) => !f.facetable), [facets]);
  const relationshipOptions = useMemo(() => _.map(_.filter(facets, (f) => f.facetable && /\.name(\.keyword)?$/.test(f.attribute)), (f) => ({
    value: f.attribute.replace(/\.name(\.keyword)?$/, ''),
    text: f.label
  })), [facets]);
  const collectionOptions = useMemo(() => _.map(collections, (c) => ({ value: String(c.id), text: c.name })), [collections]);

  const renderGeneral = () => (
    <>
      <h2 className='h-section'>Visibility</h2>
      <PublishPanel onChange={(changes) => setSite((prev) => ({ ...prev, ...changes }))} site={site} />
      <h2 className='h-section'>Address</h2>
      <DomainPanel onChange={(changes) => setSite((prev) => ({ ...prev, ...changes }))} site={site} />
      <h2 className='h-section'>Languages</h2>
      <LanguagesPanel i18n={siteConfig.i18n} onChange={updateI18n} />
      <Field label='Name' required>
        <input className='input' onChange={(e) => update({ name: e.target.value })} value={site.name || ''} />
      </Field>
      <Field hint={site.permissions?.manage === false ? 'The atlas’s platform address is built from it. Only the atlas’s owners can change it.' : 'Lowercase letters, numbers, and hyphens. The atlas’s platform address is built from it; changing it changes that address, and a connected domain has to be checked again.'} label='Slug' required>
        <input className='input' onChange={(e) => update({ slug: e.target.value })} readOnly={site.permissions?.manage === false} value={site.slug || ''} />
      </Field>
      <h2 className='h-section'>Search index</h2>
      { _.isEmpty(collections) && <p className='muted'>No search collections.</p> }
      { _.map(collections, (collection) => (
        <div className='card row' key={collection.id}>
          <div>
            <strong>{ collection.name }</strong>
            <p className='muted'>
              Models { JSON.stringify(collection.project_model_ids) }
              { collection.last_indexed_at && ` · last reindexed ${new Date(collection.last_indexed_at).toLocaleString()}` }
            </p>
          </div>
          <Button onClick={() => onReindex(collection)}>Reindex</Button>
        </div>
      ))}
      <h2 className='h-section'>Map tiles</h2>
      <p className='muted'>Generates PMTiles from the project's place geometries — the full-dataset map layer for large collections. Runs as a job.</p>
      <Button onClick={onBuildTiles}>Build map tiles</Button>
      { site.permissions?.delete && (
        <>
          <h2 className='h-section'>Delete</h2>
          <DeleteAtlasPanel onDeleted={() => navigate(paths.atlases())} site={site} />
        </>
      )}
    </>
  );

  const renderBranding = () => (
    <>
      <p className='muted'>Title, logo, fonts and colors, applied across the whole atlas.</p>
      <Field label='Site title' hint='Defaults to the atlas name.'>
        <input className='input' onChange={(e) => updateBranding({ title: e.target.value })} placeholder={site.name} value={branding.title || ''} />
      </Field>
      <Field label='Site description' hint='Shown by search engines and link previews when a page has no description of its own.'>
        <textarea className='input' onChange={(e) => updateBranding({ description: e.target.value })} rows={2} value={branding.description || ''} />
      </Field>
      <div className='grid-2'>
        <ImageField
          assets={assets}
          background={branding.primary_color || '#0a3a4d'}
          hint='Shown in the header beside the title, on the primary color. A transparent PNG or SVG works best.'
          label='Logo'
          onChange={(path) => updateBranding({ logo: path, header: _.omit(branding.header || {}, 'logo') })}
          onUpload={onUpload}
          value={branding.logo || branding.header?.logo}
        />
        <ImageField
          assets={assets}
          hint='The icon in the browser tab: a square PNG, SVG or ICO.'
          crop={CROP_SHAPES.favicon}
          label='Favicon'
          onChange={(path) => updateBranding({ favicon: path })}
          onUpload={onUpload}
          value={branding.favicon}
        />
      </div>
      <ImageField
        assets={assets}
        hint={'Used in link previews (e.g. when the atlas is shared) for pages without a banner image. About 1200×630.'}
        crop={CROP_SHAPES.linkPreview}
        label='Share image'
        onChange={(path) => updateBranding({ share_image: path })}
        onUpload={onUpload}
        value={branding.share_image}
      />
      <label className='check'>
        <input checked={branding.header?.hide_title === true} onChange={(e) => updateBrandingSection('header', { hide_title: e.target.checked })} type='checkbox' />
        Hide the title text in the header (logo only)
      </label>
      <h2 className='h-section'>Fonts</h2>
      <div className='grid-2'>
        <Field label='Header font'>
          <Select onChange={(v) => updateBranding({ font_header: v })} options={_.map(FONTS, (f) => ({ value: f, text: f }))} placeholder='Inter (default)' value={branding.font_header || ''} />
        </Field>
        <Field label='Body font'>
          <Select onChange={(v) => updateBranding({ font_body: v })} options={_.map(FONTS, (f) => ({ value: f, text: f }))} placeholder='Inter (default)' value={branding.font_body || ''} />
        </Field>
      </div>
      <h2 className='h-section'>Colors</h2>
      <div className='grid-3'>
        { _.map(COLORS, ([key, label]) => (
          <Field key={key} label={label}>
            <span className='color-field'>
              <input onChange={(e) => updateBranding({ [key]: e.target.value })} type='color' value={branding[key] || '#000000'} />
              <input className='input' onChange={(e) => updateBranding({ [key]: e.target.value })} placeholder='default' value={branding[key] || ''} />
            </span>
          </Field>
        ))}
      </div>
      <h2 className='h-section'>Footer</h2>
      <Field label='Credit line' hint='A line under the title, e.g. "A project of the Center for Digital Scholarship".'>
        <input className='input' onChange={(e) => updateBrandingSection('footer', { credit: e.target.value })} value={branding.footer?.credit || ''} />
      </Field>
      <div className='grid-3'>
        <Field label='Terms page'>
          <input className='input' onChange={(e) => updateBrandingSection('footer', { terms_url: e.target.value })} placeholder='https://…' value={branding.footer?.terms_url || ''} />
        </Field>
        <Field label='Privacy page'>
          <input className='input' onChange={(e) => updateBrandingSection('footer', { privacy_url: e.target.value })} placeholder='https://…' value={branding.footer?.privacy_url || ''} />
        </Field>
        <Field label='Accessibility page'>
          <input className='input' onChange={(e) => updateBrandingSection('footer', { accessibility_url: e.target.value })} placeholder='https://…' value={branding.footer?.accessibility_url || ''} />
        </Field>
      </div>
      <p className='muted'>Each footer link appears only when it has an address. Use /{ locale }/pages/… for a page on this atlas.</p>
      <Field
        label='Copyright or rights line'
        hint='The last line of every page. Leave it empty for none. {year} becomes the current year: “© {year} Emory University”, or “Photographs from the Library of Congress are in the public domain.”'
      >
        <input className='input' maxLength={300} onChange={(e) => updateBrandingSection('footer', { copyright: e.target.value })} value={branding.footer?.copyright || ''} />
      </Field>
      <h3 className='h-sub'>Partner logos</h3>
      { _.map(footerLogos, (logo, index) => (
        <div className='card' key={index}>
          <ImageField
            assets={assets}
            label={`Logo ${index + 1}`}
            onChange={(path) => updateFooterLogo(index, { image: path })}
            onUpload={onUpload}
            value={logo.image}
          />
          <div className='grid-2'>
            <Field label='Name' hint='Read out by screen readers.'>
              <input className='input' onChange={(e) => updateFooterLogo(index, { alt: e.target.value })} value={logo.alt || ''} />
            </Field>
            <Field label='Link'>
              <input className='input' onChange={(e) => updateFooterLogo(index, { url: e.target.value })} placeholder='https://…' value={logo.url || ''} />
            </Field>
          </div>
          <Button onClick={() => updateBrandingSection('footer', { logos: _.reject(footerLogos, (l, i) => i === index) })} subtle>Remove</Button>
        </div>
      ))}
      <Button onClick={() => updateBrandingSection('footer', { logos: [...footerLogos, {}] })} subtle>+ Add a partner logo</Button>
      <label className='check'>
        <input checked={branding.footer?.allow_login === true} onChange={(e) => updateBrandingSection('footer', { allow_login: e.target.checked })} type='checkbox' />
        Show an editor login button in the footer
      </label>
    </>
  );

  /**
   * Which language the content tabs edit, when the atlas has more than one.
   */
  const renderLanguageSwitch = () => atlasLocales.length > 1 && (
    <div className='language-switch' role='group' aria-label='Language'>
      <span className='muted'>Language:</span>
      { _.map(atlasLocales, (code) => (
        <Button key={code} onClick={() => setContentLocale(code)} primary={code === editingLocale} subtle={code !== editingLocale}>
          { localeName(code) }{ code === locale ? ' (default)' : '' }
        </Button>
      ))}
    </div>
  );

  const renderTranslatedHome = () => {
    const translatedHome = translations[editingLocale]?.home;
    const name = localeName(editingLocale);

    return (
      <>
        { renderLanguageSwitch() }
        { !translatedHome && (
          <Message>
            <p>The {name} home page isn’t written yet: visitors to the atlas in {name} see the {localeName(locale)} one.</p>
            <Button onClick={() => updateTranslation(editingLocale, { home: JSON.parse(JSON.stringify(home)) })} primary>
              Start from the {localeName(locale)} version
            </Button>
          </Message>
        )}
        { translatedHome && (
          <>
            <p className='muted'>
              The home page in {name}.
              { liveUrl && <> <a href={`${liveUrl}/${editingLocale}`} rel='noreferrer' target='_blank'>View it ↗</a></> }
            </p>
            <Field hint='Shown by search engines and link previews.' label={`Description (${name})`}>
              <input className='input' onChange={(e) => updateTranslation(editingLocale, { home: { ...translatedHome, description: e.target.value } })} value={translatedHome.description || ''} />
            </Field>
            <h2 className='h-sub'>Sections</h2>
            <SectionsEditor
              assets={assets}
              fallbackTitle={branding.title || site.name}
              onChange={(sections) => updateTranslation(editingLocale, { home: { ...translatedHome, sections } })}
              onUpload={onUpload}
              sections={translatedHome.sections}
            />
            <Button onClick={() => updateTranslation(editingLocale, { home: null })} subtle>Remove the {name} home page</Button>
          </>
        )}
      </>
    );
  };

  const renderHome = () => (editingLocale !== locale ? renderTranslatedHome() : (
    <>
      { renderLanguageSwitch() }
      <p className='muted'>
        The atlas's front page, top to bottom.
        { liveUrl && <> <a href={`${liveUrl}/${locale}`} rel='noreferrer' target='_blank'>View the home page ↗</a></> }
      </p>
      <Field hint='Shown by search engines and link previews.' label='Description'>
        <input className='input' onChange={(e) => updateHome({ description: e.target.value })} value={home.description || ''} />
      </Field>
      <h2 className='h-sub'>Sections</h2>
      <SectionsEditor
        assets={assets}
        fallbackTitle={branding.title || site.name}
        onChange={(sections) => updateHome({ sections })}
        onUpload={onUpload}
        sections={home.sections}
      />
    </>
  ));

  const renderPages = () => (editingLocale !== locale ? (
    <>
      { renderLanguageSwitch() }
      <TranslatedPagesEditor
        assets={assets}
        defaultLocale={locale}
        items={navItems}
        liveUrl={liveUrl}
        locale={editingLocale}
        onChange={(pages) => updateTranslation(editingLocale, { pages })}
        onItemsChange={(items) => update({ navigation: { ...(site.navigation || {}), items } })}
        onUpload={onUpload}
        pages={content.pages || []}
        translated={translations[editingLocale]?.pages || []}
      />
    </>
  ) : (
    <>
    { renderLanguageSwitch() }
    <PagesEditor
      assets={assets}
      items={navItems}
      liveUrl={liveUrl}
      locale={locale}
      onChange={updatePages}
      onUpload={onUpload}
      pages={content.pages || []}
      savedSlugs={savedSlugs}
      searchHref={searchHref}
    />
    </>
  ));

  const renderLayers = () => (
    <>
      <HistoricMapPanel onAdd={(layer) => updateConfig({ layers: [...(siteConfig.layers || []), layer] })} />
      <h2 className='h-section'>Layers</h2>
      <p className='muted'>The base maps visitors choose from, and overlays they can switch on. Changes apply when you save.</p>
      { _.map(siteConfig.layers || [], (layer, index) => (
        <div className='card' key={index}>
          <div className='grid-2'>
            <Field label='Name'>
              <input className='input' onChange={(e) => updateLayer(index, { name: e.target.value })} value={layer.name || ''} />
            </Field>
            <Field label='Type'>
              <Select onChange={(v) => updateLayer(index, { layer_type: v })} options={_.map(LAYER_TYPES, (t) => ({ value: t, text: LAYER_TYPE_LABELS[t] }))} placeholder='Select a type' value={layer.layer_type || ''} />
            </Field>
          </div>
          <Field label={LAYER_URL_LABELS[layer.layer_type] || 'Address'}>
            <input className='input' onChange={(e) => updateLayer(index, { url: e.target.value })} value={layer.url || ''} />
          </Field>
          { layer.overlay === true && (
            <div className='grid-2'>
              <YearInput
                hint='The year the map shows. With maps from two or more different years, visitors get a slider to move between them.'
                label='Year'
                onChange={(year) => updateLayer(index, { start_year: year })}
                placeholder='e.g. 1878'
                value={layer.start_year}
              />
              <YearInput
                error={_.isNumber(layer.end_year) && _.isNumber(layer.start_year) && layer.end_year < layer.start_year
                  ? 'Until is before Year; it will be ignored.'
                  : undefined}
                hint='For a map that stands for several years, the last one.'
                label='Until (optional)'
                onChange={(year) => updateLayer(index, { end_year: year })}
                placeholder={layer.start_year ? String(layer.start_year) : ''}
                value={layer.end_year}
              />
            </div>
          )}
          { layer.layer_type === 'georeference' && (
            <Field label={`Opacity: ${Math.round((layer.opacity ?? 1) * 100)}%`}>
              <input max='1' min='0.2' onChange={(e) => updateLayer(index, { opacity: Number(e.target.value) })} step='0.05' type='range' value={layer.opacity ?? 1} />
            </Field>
          )}
          <div className='row'>
            <label className='check'>
              <input checked={layer.overlay === true} onChange={(e) => updateLayer(index, { overlay: e.target.checked })} type='checkbox' />
              Overlay
            </label>
            <label className='check'>
              <input checked={layer.default === true} onChange={(e) => updateLayer(index, { default: e.target.checked })} type='checkbox' />
              Visible by default
            </label>
            <Button onClick={() => updateConfig({ layers: _.reject(siteConfig.layers, (l, i) => i === index) })} subtle>Remove</Button>
          </div>
        </div>
      ))}
      <Button onClick={() => updateConfig({ layers: [...(siteConfig.layers || []), { layer_type: 'raster' }] })} subtle>+ Add layer</Button>
    </>
  );

  const renderSearch = () => (
    <>
      { _.map(siteConfig.search || [], (entry, index) => (
        <div className='card' key={index}>
          <Field label='Search collection'>
            <Select onChange={(v) => updateSearch(index, { search_collection_id: v ? Number(v) : undefined })} options={collectionOptions} placeholder='Select a search collection' value={entry.search_collection_id ? String(entry.search_collection_id) : ''} />
          </Field>
          <div className='grid-3'>
            <Field label='Name'>
              <input className='input' onChange={(e) => updateSearch(index, { name: e.target.value })} placeholder='places' value={entry.name || ''} />
            </Field>
            <Field label='Route'>
              <input className='input' onChange={(e) => updateSearch(index, { route: e.target.value })} placeholder='/places' value={entry.route || ''} />
            </Field>
            <Field label='Shows results as'>
              <Select onChange={(v) => updateSearch(index, { type: v || undefined })} options={SEARCH_TYPES} placeholder='Map, with the results beside it' value={entry.type === 'map' ? '' : (entry.type || '')} />
            </Field>
          </div>
          <div className='row'>
            <label className='check'>
              <input checked={entry.geosearch === true} onChange={(e) => updateSearch(index, { geosearch: e.target.checked })} type='checkbox' />
              Filter by map bounds
            </label>
            <Field label='Result limit'>
              <input className='input' onChange={(e) => updateSearch(index, { result_limit: e.target.value ? parseInt(e.target.value, 10) : undefined })} type='number' value={entry.result_limit || ''} />
            </Field>
          </div>
          <Field label='Also search in' hint='The search box always looks at names and descriptions; choose other text fields it should look in, such as an address.'>
            <MultiSelect
              onChange={(paths) => updateSearch(index, { search_fields: paths })}
              options={_.map(searchFields, (f) => ({ value: f.path, text: f.label }))}
              value={entry.search_fields || []}
            />
          </Field>
          <fieldset className='field'>
            <legend className='field-label'>Time</legend>
            <Field label='Dates from' hint='The field that places these records in time. Visitors get a date filter (a range of years); a list or grid of results can also be sorted oldest or newest first.'>
              <Select
                onChange={(v) => updateSearch(index, {
                  dates: v ? { ...(entry.dates || {}), field: v } : undefined
                })}
                options={_.map(dateFields, (f) => ({ value: f.field, text: f.label }))}
                placeholder={_.isEmpty(dateFields) ? 'No date fields in this atlas' : 'No dates'}
                value={entry.dates?.field || ''}
              />
            </Field>
            { entry.dates?.field && (
              <div className='grid-2'>
                <Field label='Filter name' hint='What visitors see above the date filter.'>
                  <input
                    className='input'
                    maxLength={80}
                    onChange={(e) => updateSearch(index, { dates: _.omit({ ...entry.dates, label: e.target.value }, (v) => v === '') })}
                    placeholder={_.findWhere(dateFields, { field: entry.dates.field })?.label || 'Date'}
                    value={entry.dates.label || ''}
                  />
                </Field>
                <label className='check'>
                  <input
                    checked={entry.dates.timeline === true}
                    onChange={(e) => updateSearch(index, { dates: { ...entry.dates, timeline: e.target.checked } })}
                    type='checkbox'
                  />
                  Show a timeline (a Timeline button above the map)
                </label>
              </div>
            )}
          </fieldset>
          <Field label='Facets' hint='In display order. Only attributes the index can facet on are offered.'>
            <MultiSelect
              onChange={(names) => updateSearch(index, {
                facets: _.map(names, (name) => _.findWhere(entry.facets || [], { name }) || { name, type: 'list' })
              })}
              options={facetOptions}
              value={_.pluck(entry.facets || [], 'name')}
            />
          </Field>
          { !_.isEmpty(entry.facets) && (
            <fieldset className='field'>
              <legend className='field-label'>Filter names</legend>
              { _.map(entry.facets, (facet, facetIndex) => {
                const fallback = _.findWhere(facets, { attribute: facet.name })?.label || facet.name;

                return (
                  <div className='facet-label-row' key={facet.name}>
                    <span className='muted'>{ fallback }</span>
                    <input
                      aria-label={`Name shown for ${fallback}`}
                      className='input'
                      maxLength={80}
                      onChange={(e) => updateSearch(index, {
                        facets: _.map(entry.facets, (f, i) => (i === facetIndex ? _.omit({ ...f, label: e.target.value }, (v) => v === '') : f))
                      })}
                      placeholder={fallback}
                      value={facet.label || ''}
                    />
                  </div>
                );
              })}
              <span className='field-hint'>What visitors see above each filter, e.g. “Building types” for Types. Leave a name empty to keep the default.</span>
            </fieldset>
          )}
          <div className='grid-2'>
            <Field label='Result card title' hint='A document field, e.g. name.'>
              <input className='input' onChange={(e) => updateSearch(index, { result_card: { ...(entry.result_card || {}), title: e.target.value } })} placeholder='name' value={entry.result_card?.title || ''} />
            </Field>
            <Field label='Result card attributes' hint='Comma-separated document paths, e.g. contained_in_place.name, types.'>
              <input
                className='input'
                onChange={(e) => updateSearch(index, {
                  result_card: {
                    ...(entry.result_card || {}),
                    attributes: _.map(_.compact(e.target.value.split(',').map((s) => s.trim())), (name) => ({ name }))
                  }
                })}
                value={_.pluck(entry.result_card?.attributes || [], 'name').join(', ')}
              />
            </Field>
          </div>
          <Field label='Result card relationships' hint='Related records to count on each result.'>
            <MultiSelect
              onChange={(relationships) => updateSearch(index, { result_card: { ...(entry.result_card || {}), relationships } })}
              options={relationshipOptions}
              value={entry.result_card?.relationships || []}
            />
          </Field>
          <Button onClick={() => updateConfig({ search: _.reject(siteConfig.search, (s, i) => i === index) })} subtle>Remove search app</Button>
        </div>
      ))}
      <Button onClick={() => updateConfig({ search: [...(siteConfig.search || []), { name: '', route: '', geosearch: true, result_card: { title: 'name' } }] })} subtle>+ Add search app</Button>
      { !_.isEmpty(unfacetable) && (
        <details className='details'>
          <summary>Fields that can't be facets ({ unfacetable.length })</summary>
          <ul>
            { _.map(unfacetable, (f) => <li key={f.attribute}><strong>{ f.label }</strong> — { f.reason }</li>) }
          </ul>
        </details>
      )}
    </>
  );

  const renderDetail = () => (
    <>
      <p className='muted'>What each record's detail page and search panel show: fields to hide — internal bookkeeping such as legacy ids, CMS links or slugs — and the names of the sections of related records.</p>
      { _.isEmpty(fieldModels) && <p className='muted'>No models with a detail page in this project.</p> }
      { _.map(fieldModels, (entry) => (
        <div className='card' key={entry.model}>
          <Field label={`${entry.name} (${entry.model})`} hint='Type a field name or uuid to hide one not listed.'>
            <MultiSelect
              allowAdditions
              onChange={(exclude) => updateExclude(entry.model, exclude)}
              options={_.map(entry.fields, (f) => ({ value: f.key, text: f.kind === 'user_defined' ? `${f.label} (${f.key})` : f.label }))}
              value={siteConfig.detail_pages?.models?.[entry.model]?.exclude || []}
            />
          </Field>
          { !_.isEmpty(entry.relationships) && (
            <div className='section-names'>
              <span className='field-label'>Section names</span>
              <p className='muted'>
                How each group of related records is headed on a record’s page and in the map’s panel. Leave a name empty
                to use the FairData name.
              </p>
              <div className='table-scroll'>
                <table className='table'>
                  <thead>
                    <tr>
                      <th>In FairData</th>
                      { _.map(atlasLocales, (loc) => <th key={loc}>{ atlasLocales.length > 1 ? `On the atlas (${loc})` : 'On the atlas' }</th>) }
                    </tr>
                  </thead>
                  <tbody>
                    { _.map(entry.relationships, (relationship) => (
                      <tr key={relationship.key}>
                        <td>
                          { relationship.name }
                          { relationship.related && <span className='muted'> · { relationship.inverse ? 'from' : 'to' } { relationship.related }</span> }
                        </td>
                        { _.map(atlasLocales, (loc) => (
                          <td key={loc}>
                            <input
                              aria-label={`${relationship.name} (${loc})`}
                              className='input'
                              onChange={(e) => updateSectionName(relationship.key, loc, e.target.value)}
                              placeholder={relationship.name}
                              value={siteConfig.i18n?.strings?.[loc]?.[relationship.key] || ''}
                            />
                          </td>
                        ))}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </div>
      ))}
    </>
  );

  const renderAdvanced = () => (
    <>
      <p className='muted'>Free-form JSON for config sections without a dedicated editor (the rest of detail_pages, result_filtering, i18n, wordpress, core_data.url). Merged into the site config when you click away.</p>
      { advancedError && <Message tone='negative'>Invalid JSON — fix the syntax to apply changes.</Message> }
      <textarea aria-label='Settings as JSON' className='input code' onBlur={onAdvancedBlur} onChange={(e) => setAdvancedText(e.target.value)} rows={24} spellCheck={false} value={advancedText} />
      <h2 className='h-section'>Config preview</h2>
      <p className='muted'>The emitted config.json — what the renderer receives for this atlas. Reflects the last saved state.</p>
      <Button onClick={onLoadPreview}>Load preview</Button>
      { preview && <pre className='code-block'>{ preview }</pre> }
    </>
  );

  const renderImages = () => (
    <ImageLibrary assets={assets} onChange={setAssets} onUpload={onUpload} savedSite={savedSite} site={site} />
  );

  const renderers = {
    general: renderGeneral,
    branding: renderBranding,
    home: renderHome,
    pages: renderPages,
    images: renderImages,
    layers: renderLayers,
    search: renderSearch,
    detail: renderDetail,
    advanced: renderAdvanced
  };

  return (
    <ImageCropContext.Provider value={site ? onCrop : null}>
    <main className='wizard'>
      <AtlasHeader active='settings' navigate={navigate} site={site} />
      { !_.isEmpty(errors) && <Message list={errors} tone='negative' /> }
      { notice && <Message tone='positive'>{ notice }</Message> }
      { site && (
        <section className='panel'>
          <div aria-label='Settings' className='tabs' onKeyDown={onTabListKeyDown} role='tablist'>
            { _.map(TABS, (t) => (
              <button aria-selected={tab === t.key} className='tab' key={t.key} onClick={() => setTab(t.key)} role='tab' tabIndex={tab === t.key ? 0 : -1} type='button'>{ t.label }</button>
            ))}
          </div>
          { renderers[tab]() }
          { conflict && (
            <Message header='Someone else saved this atlas while you were editing' tone='warning'>
              <p>
                { conflict.source === 'import' ? 'An import set it up' : (conflict.source === 'tiles' ? 'A map tile build changed it' : `${conflict.by || 'Someone'} saved it`) }
                { ' ' }
                at { new Date(conflict.at).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }) }
                { conflict.parts?.length ? ` (${conflict.parts.join(', ')})` : '' }.
                { ' ' }
                <strong>Reload</strong> shows that version (your unsaved changes here are lost);
                { ' ' }
                <strong>Save anyway</strong> replaces it with yours, and History keeps theirs to restore.
              </p>
              <div className='actions'>
                <Button onClick={onReload}>Reload</Button>
                <Button loading={saving} onClick={() => onSave(true)}>Save anyway</Button>
              </div>
            </Message>
          )}
          <div className='actions'>
            <Button loading={saving} onClick={() => onSave()} primary>Save</Button>
            { saved && <span className='muted'>Saved. The atlas shows the changes within 30 seconds.</span> }
          </div>
        </section>
      )}
    </main>
    </ImageCropContext.Provider>
  );
};

export default AtlasEditor;
