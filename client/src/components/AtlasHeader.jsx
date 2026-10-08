import { useEffect, useRef } from 'react';
import { liveUrl, previewUrl } from '../atlasLinks';
import config from '../config';
import { useFeedback } from '../feedback';
import { paths } from '../router';

/**
 * The per-atlas page header: name, draft/published status, the live link
 * (or the preview link for a draft), and the Edit / Imports / Jobs tabs.
 * People goes to the project's Users page in the FairData console, where
 * owners add curators (by email, with an invitation) and set their role:
 * owners manage the atlas; editors edit its content (SitePolicy).
 */
const AtlasHeader = ({ active, navigate, site }) => {
  const link = site?.published ? liveUrl(site) : previewUrl(site);
  const { setSite } = useFeedback();

  // Feedback sent from this atlas's pages is about this atlas.
  useEffect(() => { if (site) setSite?.(site); }, [setSite, site]);

  // On a phone the tabs scroll sideways; bring the current one into view
  // (the row only: scrollIntoView would move the page too).
  const nav = useRef(null);
  useEffect(() => {
    const row = nav.current;
    const current = row?.querySelector('[aria-current="page"]');
    if (!current) return;

    const r = row.getBoundingClientRect();
    const c = current.getBoundingClientRect();
    if (c.left < r.left || c.right > r.right) row.scrollLeft += (c.left + c.width / 2) - (r.left + r.width / 2);
  }, [active, site?.id]);

  // The atlas's pages: links (a nav), the current one marked as the page.
  const tab = (to, label, key) => (
    <a
      aria-current={active === key ? 'page' : undefined}
      className='tab'
      href={to}
      onClick={(e) => { e.preventDefault(); navigate(to); }}
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
        <nav aria-label='Atlas pages' className='tabs' ref={nav}>
          { tab(paths.atlas(site.id), 'Settings', 'settings') }
          { tab(paths.places(site.id), 'Places', 'places') }
          { tab(paths.imports(site.id), 'Imports', 'imports') }
          { tab(paths.jobs(site.id), 'Jobs', 'jobs') }
          { tab(paths.history(site.id), 'History', 'history') }
          { site.permissions?.manage !== false && (
          <a
            className='tab tab-external'
            href={`${config.consoleUrl}/projects/${site.project_id}/user_projects`}
            title='Who can work on this atlas: add curators and set their roles in the FairData console'
          >
            People →
          </a>
          )}
        </nav>
      )}
    </div>
  );
};

export default AtlasHeader;
