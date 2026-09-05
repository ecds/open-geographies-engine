import config from '../config';
import { paths } from '../router';

/**
 * The per-atlas page header: name, live link, and the Edit / Imports / Jobs tabs.
 */
const AtlasHeader = ({ active, navigate, site }) => {
  const liveUrl = site && config.atlasUrlTemplate && config.atlasUrlTemplate.replace('{slug}', site.slug);

  const tab = (to, label, key) => (
    <a
      aria-selected={active === key}
      className='tab'
      href={to}
      onClick={(e) => { e.preventDefault(); navigate(to); }}
      role='tab'
    >
      { label }
    </a>
  );

  return (
    <div className='atlas-head'>
      <p className='crumbs'>
        <a href={paths.atlases()} onClick={(e) => { e.preventDefault(); navigate(paths.atlases()); }}>Atlases</a>
        { ' / ' }
        { site?.name || '…' }
      </p>
      <div className='page-head'>
        <h1>{ site?.name || '…' }</h1>
        { liveUrl && <a className='button' href={liveUrl} rel='noreferrer' target='_blank'>View atlas ↗</a> }
      </div>
      { site && (
        <div className='tabs' role='tablist'>
          { tab(paths.atlas(site.id), 'Settings', 'settings') }
          { tab(paths.imports(site.id), 'Place imports', 'imports') }
          { tab(paths.jobs(site.id), 'Jobs', 'jobs') }
        </div>
      )}
    </div>
  );
};

export default AtlasHeader;
