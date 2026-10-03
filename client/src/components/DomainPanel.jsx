import { useState } from 'react';
import { checkSiteDomain, errorMessages, updateSiteDomain } from '../api';
import { Button, Message } from './ui';

/**
 * The atlas's address, and a domain of its own. A domain is used once its
 * DNS points at this atlas (the server checks: a CNAME to the platform
 * address, or a TXT record naming the atlas); from then on the platform
 * address sends visitors there. Takes effect at once, separately from Save.
 * Only the atlas's owners change it; editors see it.
 */
const DomainPanel = ({ onChange, site }) => {
  const canManage = site.permissions?.manage !== false;
  const [value, setValue] = useState('');
  const [saving, setSaving] = useState(false);
  const [errors, setErrors] = useState([]);
  const [check, setCheck] = useState(null);
  const [confirmRemove, setConfirmRemove] = useState(false);

  const connected = site.domain_status === 'connected';
  const dns = site.domain_dns;

  const run = (promise) => {
    setSaving(true);
    setErrors([]);

    return promise
      .then((data) => {
        onChange(data.site);
        setCheck(data.check);
        setValue('');
      })
      .catch((error) => setErrors(errorMessages(error, { domain: '' })))
      .finally(() => {
        setSaving(false);
        setConfirmRemove(false);
      });
  };

  const onAdd = (event) => {
    event.preventDefault();
    run(updateSiteDomain(site.id, value));
  };

  const onRemove = () => run(updateSiteDomain(site.id, ''));

  const platform = site.platform_url && (
    <a href={site.platform_url} rel='noreferrer' target='_blank'>{ site.platform_url.replace(/^https?:\/\//, '') }</a>
  );

  return (
    <section className='card publish-panel domain-panel'>
      { errors.length > 0 && <Message list={errors} tone='negative' /> }
      { site.platform_url && (
        <p>
          Platform address: { platform }
          { connected && ' — sends visitors to the domain below.' }
        </p>
      )}

      { !canManage && (
        <p className='muted'>
          { site.domain ? <>Its own domain: <strong>{ site.domain }</strong> ({ connected ? 'connected' : 'waiting for DNS' }). </> : 'No domain of its own. ' }
          Only the atlas’s owners can change its address.
        </p>
      )}

      { canManage && !site.domain && (
        <form onSubmit={onAdd}>
          <label className='field-label' htmlFor='atlas-domain'>Your own domain</label>
          <div className='preview-link'>
            <input
              className='input'
              id='atlas-domain'
              onChange={(e) => setValue(e.target.value)}
              placeholder='atlas.example.org'
              spellCheck={false}
              value={value}
            />
            <Button disabled={!value.trim()} loading={saving} primary type='submit'>Add domain</Button>
          </div>
          <p className='muted'>
            Optional. A domain or subdomain you control. The atlas moves there once the domain’s DNS points at it.
          </p>
        </form>
      )}

      { canManage && site.domain && (
        <>
          <p>
            <span className={`status-pill ${connected ? 'status-published' : 'status-draft'}`}>
              { connected ? 'Connected' : 'Waiting for DNS' }
            </span>
            { ' ' }<strong>{ site.domain }</strong>
            { connected && site.public_url && <> · <a href={site.public_url} rel='noreferrer' target='_blank'>Open ↗</a></> }
          </p>
          { check && !check.connected && <Message tone='warning'>{ check.message }</Message> }
          { !connected && dns && !dns.local && (
            <div className='dns-records'>
              <p>Ask whoever manages <strong>{ site.domain }</strong>’s DNS to add one of these records, then check again.</p>
              <div className='table-scroll'>
                <table className='table'>
                  <thead>
                    <tr><th>For</th><th>Type</th><th>Name</th><th>Value</th></tr>
                  </thead>
                  <tbody>
                    { dns.cname && (
                      <tr>
                        <td>A subdomain (atlas.example.org)</td>
                        <td>CNAME</td>
                        <td><code>{ site.domain }</code></td>
                        <td><code>{ dns.cname }</code></td>
                      </tr>
                    )}
                    <tr>
                      <td>A root domain (example.org)</td>
                      <td>TXT</td>
                      <td><code>{ dns.txt_name }</code></td>
                      <td><code>{ dns.txt_value }</code></td>
                    </tr>
                  </tbody>
                </table>
              </div>
              <p className='muted'>
                A root domain can’t have a CNAME: it also needs A or ALIAS records pointing at the platform
                { dns.cname && <> (the same place as <code>{ dns.cname }</code>)</> }.
              </p>
            </div>
          )}
          { connected && !dns?.local && <p className='muted'>Keep the DNS record in place: the atlas is served at { site.domain } only while it points here.</p> }
          { dns?.www && !dns?.local && (
            <p className='muted'>
              Optional: point <code>{ dns.www }</code> here too{ dns.cname && <> (a CNAME to <code>{ dns.cname }</code>)</> }, and
              visitors who type it are sent to { site.domain }.
            </p>
          )}
          { dns?.local && <p className='muted'>A .localhost name: it works on this development server only, with no DNS.</p> }
          <div className='row'>
            <Button loading={saving && !confirmRemove} onClick={() => run(checkSiteDomain(site.id))}>Check DNS</Button>
            { !confirmRemove && <Button disabled={saving} onClick={() => setConfirmRemove(true)} subtle>Remove domain…</Button> }
            { confirmRemove && (
              <>
                <span>
                  The atlas goes back to its platform address{ connected && <>; links to { site.domain } stop working</> }.
                </span>
                <Button loading={saving} onClick={onRemove}>Remove it</Button>
                <Button disabled={saving} onClick={() => setConfirmRemove(false)} subtle>Cancel</Button>
              </>
            )}
          </div>
        </>
      )}
    </section>
  );
};

export default DomainPanel;
