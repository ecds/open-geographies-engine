import { useCallback, useEffect, useMemo, useState } from 'react';
import _ from 'underscore';
import {
  buildTiles,
  errorMessages,
  fetchSearchCollections,
  fetchSite,
  fetchSiteConfig,
  fetchSiteFacets,
  reindexSearchCollection,
  updateSite
} from '../api';
import AtlasHeader from '../components/AtlasHeader';
import { Button, Field, Message, MultiSelect, Select, Tag } from '../components/ui';

const TABS = [
  { key: 'general', label: 'General' },
  { key: 'branding', label: 'Branding' },
  { key: 'navigation', label: 'Navigation' },
  { key: 'layers', label: 'Map layers' },
  { key: 'search', label: 'Search' },
  { key: 'advanced', label: 'Advanced' },
  { key: 'preview', label: 'Config preview' }
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
const SEARCH_TYPES = ['map', 'list', 'grid', 'image'];

/**
 * The atlas editor: the site record's name/slug, branding, navigation, map
 * layers and search apps, plus the config sections without a dedicated
 * editor as JSON, and the emitted config.json for reference.
 *
 * Facet choices come from the engine's facet catalog (GET /sites/:id/facets),
 * which knows what the v1 index actually makes facetable for this project's
 * models — so the pick-list can't offer an attribute that would return an
 * empty facet.
 */
const AtlasEditor = ({ id, navigate }) => {
  const [site, setSite] = useState(null);
  const [collections, setCollections] = useState([]);
  const [facets, setFacets] = useState([]);
  const [tab, setTab] = useState('general');
  const [advancedText, setAdvancedText] = useState('');
  const [advancedError, setAdvancedError] = useState(false);
  const [preview, setPreview] = useState(null);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [notice, setNotice] = useState(null);
  const [errors, setErrors] = useState([]);

  useEffect(() => {
    fetchSite(id)
      .then((data) => {
        setSite(data.site);
        setAdvancedText(JSON.stringify(_.omit(data.site.config || {}, MANAGED_KEYS), null, 2));

        return Promise.all([
          fetchSearchCollections(data.site.project_id).then((d) => setCollections(d.search_collections || [])),
          fetchSiteFacets(id).then((d) => setFacets(d.facets || []))
        ]);
      })
      .catch((error) => setErrors(errorMessages(error)));
  }, [id]);

  const config = site?.config || {};
  const branding = site?.branding || {};
  const navItems = site?.navigation?.items || [];

  const update = (changes) => { setSite((prev) => ({ ...prev, ...changes })); setSaved(false); };
  const updateConfig = (changes) => update({ config: { ...config, ...changes } });
  const updateBranding = (changes) => update({ branding: { ...branding, ...changes } });
  const updateBrandingSection = (section, changes) => updateBranding({ [section]: { ...(branding[section] || {}), ...changes } });
  const updateNav = (items) => update({ navigation: { ...(site.navigation || {}), items } });

  const updateLayer = (index, changes) => {
    const layers = [...(config.layers || [])];
    layers[index] = { ...layers[index], ...changes };
    updateConfig({ layers });
  };

  const updateSearch = (index, changes) => {
    const search = [...(config.search || [])];
    search[index] = { ...search[index], ...changes };
    updateConfig({ search });
  };

  /**
   * The advanced JSON is merged beneath the managed sections when it parses.
   */
  const onAdvancedBlur = () => {
    try {
      const parsed = JSON.parse(advancedText || '{}');
      setAdvancedError(false);
      update({ config: { ...parsed, ..._.pick(config, MANAGED_KEYS) } });
    } catch (e) {
      setAdvancedError(true);
    }
  };

  const onSave = useCallback(() => {
    setSaving(true);
    setErrors([]);
    setSaved(false);

    updateSite(site.id, _.pick(site, 'name', 'slug', 'config', 'area', 'branding', 'navigation'))
      .then((data) => { setSite(data.site); setSaved(true); setPreview(null); })
      .catch((error) => setErrors(errorMessages(error)))
      .finally(() => setSaving(false));
  }, [site]);

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
      <Field label='Name' required>
        <input className='input' onChange={(e) => update({ name: e.target.value })} value={site.name || ''} />
      </Field>
      <Field hint='Lowercase letters, numbers, and hyphens. Used in the atlas URL (e.g. my-atlas.opengeographies.org).' label='Slug' required>
        <input className='input' onChange={(e) => update({ slug: e.target.value })} value={site.slug || ''} />
      </Field>
      <h3>Search index</h3>
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
      <h3>Map tiles</h3>
      <p className='muted'>Generates PMTiles from the project's place geometries — the full-dataset map layer for large collections. Runs as a job.</p>
      <Button onClick={onBuildTiles}>Build map tiles</Button>
    </>
  );

  const renderBranding = () => (
    <>
      <p className='muted'>Title, logo, fonts and colors, applied across the whole atlas.</p>
      <div className='grid-2'>
        <Field label='Site title' hint='Defaults to the atlas name.'>
          <input className='input' onChange={(e) => updateBranding({ title: e.target.value })} value={branding.title || ''} />
        </Field>
        <Field label='Logo path or URL'>
          <input className='input' onChange={(e) => updateBranding({ logo: e.target.value })} value={branding.logo || ''} />
        </Field>
        <Field label='Header font'>
          <Select onChange={(v) => updateBranding({ font_header: v })} options={_.map(FONTS, (f) => ({ value: f, text: f }))} placeholder='Inter (default)' value={branding.font_header || ''} />
        </Field>
        <Field label='Body font'>
          <Select onChange={(v) => updateBranding({ font_body: v })} options={_.map(FONTS, (f) => ({ value: f, text: f }))} placeholder='Inter (default)' value={branding.font_body || ''} />
        </Field>
      </div>
      <h3>Colors</h3>
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
      <label className='check'>
        <input checked={branding.header?.hide_title === true} onChange={(e) => updateBrandingSection('header', { hide_title: e.target.checked })} type='checkbox' />
        Hide the title text in the header (logo only)
      </label>
      <label className='check'>
        <input checked={branding.footer?.allow_login !== false} onChange={(e) => updateBrandingSection('footer', { allow_login: e.target.checked })} type='checkbox' />
        Show editor login links in the footer
      </label>
    </>
  );

  const renderNavigation = () => (
    <>
      <p className='muted'>The top navigation. Links can be internal (e.g. /en/search/places) or external (https://…).</p>
      { _.map(navItems, (item, index) => (
        <div className='card' key={index}>
          <div className='grid-2'>
            <Field label='Label'>
              <input className='input' onChange={(e) => updateNav(navItems.map((n, i) => (i === index ? { ...n, label: e.target.value } : n)))} value={item.label || ''} />
            </Field>
            <Field label='URL'>
              <input className='input' onChange={(e) => updateNav(navItems.map((n, i) => (i === index ? { ...n, href: e.target.value } : n)))} value={item.href || ''} />
            </Field>
          </div>
          <Button onClick={() => updateNav(_.reject(navItems, (n, i) => i === index))} subtle>Remove</Button>
        </div>
      ))}
      <Button onClick={() => updateNav([...navItems, { _template: 'URL', label: '', href: '' }])} subtle>+ Add navigation item</Button>
    </>
  );

  const renderLayers = () => (
    <>
      { _.map(config.layers || [], (layer, index) => (
        <div className='card' key={index}>
          <div className='grid-2'>
            <Field label='Name'>
              <input className='input' onChange={(e) => updateLayer(index, { name: e.target.value })} value={layer.name || ''} />
            </Field>
            <Field label='Type'>
              <Select onChange={(v) => updateLayer(index, { layer_type: v })} options={_.map(LAYER_TYPES, (t) => ({ value: t, text: t }))} placeholder='Select a type' value={layer.layer_type || ''} />
            </Field>
          </div>
          <Field label='URL'>
            <input className='input' onChange={(e) => updateLayer(index, { url: e.target.value })} value={layer.url || ''} />
          </Field>
          <div className='row'>
            <label className='check'>
              <input checked={layer.overlay === true} onChange={(e) => updateLayer(index, { overlay: e.target.checked })} type='checkbox' />
              Overlay
            </label>
            <label className='check'>
              <input checked={layer.default === true} onChange={(e) => updateLayer(index, { default: e.target.checked })} type='checkbox' />
              Visible by default
            </label>
            <Button onClick={() => updateConfig({ layers: _.reject(config.layers, (l, i) => i === index) })} subtle>Remove</Button>
          </div>
        </div>
      ))}
      <Button onClick={() => updateConfig({ layers: [...(config.layers || []), { layer_type: 'raster' }] })} subtle>+ Add layer</Button>
    </>
  );

  const renderSearch = () => (
    <>
      { _.map(config.search || [], (entry, index) => (
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
            <Field label='Type'>
              <Select onChange={(v) => updateSearch(index, { type: v || undefined })} options={_.map(SEARCH_TYPES, (t) => ({ value: t, text: t }))} placeholder='map (default)' value={entry.type || ''} />
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
          <Field label='Facets' hint='In display order. Only attributes the index can facet on are offered.'>
            <MultiSelect
              onChange={(names) => updateSearch(index, {
                facets: _.map(names, (name) => _.findWhere(entry.facets || [], { name }) || { name, type: 'list' })
              })}
              options={facetOptions}
              value={_.pluck(entry.facets || [], 'name')}
            />
          </Field>
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
          <Button onClick={() => updateConfig({ search: _.reject(config.search, (s, i) => i === index) })} subtle>Remove search app</Button>
        </div>
      ))}
      <Button onClick={() => updateConfig({ search: [...(config.search || []), { name: '', route: '', geosearch: true, result_card: { title: 'name' } }] })} subtle>+ Add search app</Button>
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

  const renderAdvanced = () => (
    <>
      <p className='muted'>Free-form JSON for config sections without a dedicated editor (detail_pages, result_filtering, content, i18n, core_data.url). Merged into the site config when you click away.</p>
      { advancedError && <Message tone='negative'>Invalid JSON — fix the syntax to apply changes.</Message> }
      <textarea className='input code' onBlur={onAdvancedBlur} onChange={(e) => setAdvancedText(e.target.value)} rows={24} spellCheck={false} value={advancedText} />
    </>
  );

  const renderPreview = () => (
    <>
      <p className='muted'>The emitted config.json — what the renderer receives for this atlas. Reflects the last saved state.</p>
      <Button onClick={onLoadPreview}>Load preview</Button>
      { preview && <pre className='code-block'>{ preview }</pre> }
    </>
  );

  const renderers = {
    general: renderGeneral,
    branding: renderBranding,
    navigation: renderNavigation,
    layers: renderLayers,
    search: renderSearch,
    advanced: renderAdvanced,
    preview: renderPreview
  };

  return (
    <main className='wizard'>
      <AtlasHeader active='settings' navigate={navigate} site={site} />
      { !_.isEmpty(errors) && <Message list={errors} tone='negative' /> }
      { notice && <Message tone='positive'>{ notice }</Message> }
      { site && (
        <section className='panel'>
          <div className='tabs' role='tablist'>
            { _.map(TABS, (t) => (
              <button aria-selected={tab === t.key} className='tab' key={t.key} onClick={() => setTab(t.key)} role='tab' type='button'>{ t.label }</button>
            ))}
          </div>
          { renderers[tab]() }
          <div className='actions'>
            <Button loading={saving} onClick={onSave} primary>Save</Button>
            { saved && <span className='muted'>Saved.</span> }
          </div>
        </section>
      )}
    </main>
  );
};

export default AtlasEditor;
