import { liveUrl, previewUrl } from '../atlasLinks';
import { paths } from '../router';

/**
 * The per-atlas page header: name, draft/published status, the live link
 * (or the preview link for a draft), and the Edit / Imports / Jobs tabs.
 */
const AtlasHeader = ({ active, navigate, site }) => {
  const link = site?.published ? liveUrl(site) : previewUrl(site);

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
        <h1>
          { site?.name || '…' }
          { site && (
            <span className={`status-pill ${site.published ? 'status-published' : 'status-draft'}`}>
              { site.published ? 'Published' : 'Draft' }
            </span>
          )}
        </h1>
        { link && <a className='button' href={link} rel='noreferrer' target='_blank'>{ site.published ? 'View atlas ↗' : 'Preview ↗' }</a> }
      </div>
      { site && (
        <div className='tabs' role='tablist'>
          { tab(paths.atlas(site.id), 'Settings', 'settings') }
          { tab(paths.imports(site.id), 'Imports', 'imports') }
          { tab(paths.jobs(site.id), 'Jobs', 'jobs') }
        </div>
      )}
    </div>
  );
};

export default AtlasHeader;
