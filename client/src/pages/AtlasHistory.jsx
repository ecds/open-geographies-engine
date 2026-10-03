import { useCallback, useEffect, useState } from 'react';
import _ from 'underscore';
import {
  errorMessages,
  fetchSite,
  fetchSiteVersion,
  fetchSiteVersions,
  restoreSiteVersion
} from '../api';
import AtlasHeader from '../components/AtlasHeader';
import { Button, Message, Tag } from '../components/ui';

const SOURCES = {
  created: 'Atlas created',
  baseline: 'As it was before history started',
  console: 'Saved',
  restore: 'Restored',
  import: 'Set up by an import',
  tiles: 'Map tiles built',
  system: 'Saved by the platform'
};

const when = (value) => new Date(value).toLocaleString(undefined, {
  year: 'numeric', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'
});

/**
 * Changes to what only owners decide, recorded with a save: published,
 * the atlas's address (slug) and its own domain.
 */
const eventLines = (events) => _.compact([
  events?.published && (events.published[1] ? 'Published' : 'Unpublished'),
  events?.slug && `Address changed: ${events.slug[0]} → ${events.slug[1]}`,
  events?.domain && (events.domain[1] ? `Domain set to ${events.domain[1]}` : `Domain ${events.domain[0]} removed`)
]);

/**
 * A part-by-part summary: { part key: [lines] } under the parts' names.
 */
const Summary = ({ labels, summary }) => (
  <ul className='history-summary'>
    { _.map(summary, (lines, key) => (
      <li key={key}>
        <strong>{ labels[key] || key }</strong>
        <ul>
          { _.map(lines, (line, index) => <li key={index}>{ line }</li>) }
        </ul>
      </li>
    ))}
  </ul>
);

/**
 * One version opened: what that save changed, what restoring it would change
 * now, and restoring the chosen parts (a new version; the current state stays
 * in the history).
 */
const VersionDetail = ({ canRestore, labels, onRestored, siteId, version }) => {
  const [detail, setDetail] = useState(null);
  const [chosen, setChosen] = useState([]);
  const [confirming, setConfirming] = useState(false);
  const [restoring, setRestoring] = useState(false);
  const [errors, setErrors] = useState([]);

  // Ticked to start with: the parts this save changed, where they differ
  // now — not everything that differs, which would also undo every later
  // save of the other parts.
  useEffect(() => {
    fetchSiteVersion(siteId, version.id)
      .then((data) => { setDetail(data); setChosen(_.intersection(version.changed_parts || [], _.keys(data.differences))); })
      .catch((error) => setErrors(errorMessages(error)));
  }, [siteId, version.id]);

  const toggle = (key) => setChosen(chosen.includes(key) ? _.without(chosen, key) : [...chosen, key]);

  const onRestore = () => {
    setRestoring(true);
    setErrors([]);
    restoreSiteVersion(siteId, version.id, chosen)
      .then(() => onRestored(_.map(chosen, (key) => labels[key] || key)))
      .catch((error) => setErrors(errorMessages(error)))
      .finally(() => { setRestoring(false); setConfirming(false); });
  };

  if (!detail) {
    return _.isEmpty(errors) ? <p className='muted'>Loading…</p> : <Message list={errors} tone='negative' />;
  }

  const differing = _.keys(detail.differences);

  return (
    <div className='history-detail'>
      { !_.isEmpty(detail.changes) && (
        <>
          <h2 className='h-sub'>
            { detail.changes_since?.gap
              ? `What changed since ${when(detail.changes_since.at)} (the saves in between are no longer kept)`
              : 'What this save changed' }
          </h2>
          <Summary labels={labels} summary={detail.changes} />
        </>
      )}
      <h2 className='h-sub'>Compared with the atlas now</h2>
      { _.isEmpty(differing) ? (
        <p className='muted'>The atlas is the same as this version.</p>
      ) : (
        <>
          <p className='muted'>Restoring this version would change:</p>
          <Summary labels={labels} summary={detail.differences} />
          { canRestore && (
            <>
              <fieldset className='history-parts'>
                <legend>Restore</legend>
                { _.map(differing, (key) => (
                  <label className='check' key={key}>
                    <input checked={chosen.includes(key)} onChange={() => toggle(key)} type='checkbox' />
                    { labels[key] || key }
                  </label>
                ))}
              </fieldset>
              { !_.isEmpty(errors) && <Message list={errors} tone='negative' /> }
              { confirming ? (
                <Message header='Restore these parts?' tone='warning'>
                  <p>
                    { _.map(chosen, (key) => labels[key] || key).join(', ') } { chosen.length === 1 ? 'goes' : 'go' } back to how { chosen.length === 1 ? 'it was' : 'they were' } on { when(version.created_at) }.
                    The atlas shows it within 30 seconds. How it is now stays in the history, so you can restore that too.
                  </p>
                  <div className='actions'>
                    <Button onClick={() => setConfirming(false)} subtle>Cancel</Button>
                    <Button loading={restoring} onClick={onRestore} primary>Restore</Button>
                  </div>
                </Message>
              ) : (
                <div className='actions'>
                  <Button disabled={_.isEmpty(chosen)} onClick={() => setConfirming(true)}>Restore the chosen parts…</Button>
                </div>
              )}
            </>
          )}
        </>
      )}
    </div>
  );
};

/**
 * Settings → History: every saved version of the atlas's content, branding,
 * menu and settings, newest first — when, who, how, which parts — and
 * restoring parts of one. Publishing, the address and the domain show as
 * events; a restore never changes them.
 */
const AtlasHistory = ({ id, navigate }) => {
  const [site, setSite] = useState(null);
  const [data, setData] = useState(null);
  const [page, setPage] = useState(1);
  const [open, setOpen] = useState(null);
  const [notice, setNotice] = useState(null);
  const [errors, setErrors] = useState([]);

  useEffect(() => {
    fetchSite(id).then((d) => setSite(d.site)).catch((error) => setErrors(errorMessages(error)));
  }, [id]);

  const load = useCallback(() => {
    fetchSiteVersions(id, page).then(setData).catch((error) => setErrors(errorMessages(error)));
  }, [id, page]);

  useEffect(load, [load]);

  const labels = _.object(_.map(data?.parts || [], (part) => [part.key, part.label]));
  const pages = data ? Math.max(1, Math.ceil(data.total / data.per_page)) : 1;
  const canRestore = site?.permissions?.edit !== false;

  // Back to the first page (the new version is at its top): one load, by
  // the page change, or now when already there.
  const onRestored = (parts) => {
    setNotice(`Restored: ${parts.join(', ')}. The atlas shows it within 30 seconds.`);
    setOpen(null);
    if (page === 1) {
      load();
    } else {
      setPage(1);
    }
  };

  return (
    <main className='wizard'>
      <AtlasHeader active='history' navigate={navigate} site={site} />
      <p className='muted'>
        Each save of the atlas’s pages, branding, menu and settings is kept here (the last 100, and the first). Open one to
        see what it changed and to put parts of it back.
      </p>
      { !_.isEmpty(errors) && <Message list={errors} tone='negative' /> }
      { notice && <Message tone='positive'>{ notice }</Message> }
      { data && _.isEmpty(data.versions) && <Message>No saves yet. The history starts with the next save.</Message> }
      <ol className='history-list'>
        { _.map(data?.versions || [], (version) => {
          const events = eventLines(version.events);
          const isOpen = open === version.id;

          return (
            <li className={`card history-version${isOpen ? ' is-open' : ''}`} key={version.id}>
              <button
                aria-expanded={isOpen}
                className='history-toggle'
                onClick={() => setOpen(isOpen ? null : version.id)}
                type='button'
              >
                <span className='history-when'>{ when(version.created_at) }</span>
                <span className='history-what'>
                  { SOURCES[version.source] || version.source }
                  { version.restored_from_at && ` from ${when(version.restored_from_at)}` }
                  { version.user && ` by ${version.user.name}` }
                </span>
                <span className='tags'>
                  { _.map(version.changed_parts, (key) => <Tag key={key}>{ labels[key] || key }</Tag>) }
                  { _.map(events, (line) => <Tag key={line} tone='warning'>{ line }</Tag>) }
                </span>
              </button>
              { isOpen && (
                <VersionDetail
                  canRestore={canRestore}
                  labels={labels}
                  onRestored={onRestored}
                  siteId={id}
                  version={version}
                />
              )}
            </li>
          );
        })}
      </ol>
      { pages > 1 && (
        <div className='actions'>
          <Button disabled={page <= 1} onClick={() => { setPage(page - 1); setOpen(null); }} subtle>← Newer</Button>
          <span className='muted'>Page { page } of { pages }</span>
          <Button disabled={page >= pages} onClick={() => { setPage(page + 1); setOpen(null); }} subtle>Older →</Button>
        </div>
      )}
    </main>
  );
};

export default AtlasHistory;
